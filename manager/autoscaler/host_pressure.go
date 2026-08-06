package main

import (
	"bufio"
	"bytes"
	"errors"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const defaultHostProcPath = "/host/proc"

type hostPressureTelemetry struct {
	Status                  string   `json:"status"`
	Source                  string   `json:"source"`
	CPUUtilizationPercent   *float64 `json:"cpuUtilizationPercent"`
	Load1                   *float64 `json:"load1"`
	Load5                   *float64 `json:"load5"`
	Load15                  *float64 `json:"load15"`
	MemoryTotalBytes        *int64   `json:"memoryTotalBytes"`
	MemoryAvailableBytes    *int64   `json:"memoryAvailableBytes"`
	SwapUsedBytes           *int64   `json:"swapUsedBytes"`
	CPUPressureSomeAvg10    *float64 `json:"cpuPressureSomeAvg10"`
	CPUPressureFullAvg10    *float64 `json:"cpuPressureFullAvg10"`
	MemoryPressureSomeAvg10 *float64 `json:"memoryPressureSomeAvg10"`
	MemoryPressureFullAvg10 *float64 `json:"memoryPressureFullAvg10"`
	IOPressureSomeAvg10     *float64 `json:"ioPressureSomeAvg10"`
	IOPressureFullAvg10     *float64 `json:"ioPressureFullAvg10"`
}

type hostCPUCounters struct {
	total uint64
	idle  uint64
}

func unavailableHostPressure() hostPressureTelemetry {
	return hostPressureTelemetry{
		Status: "unavailable",
		Source: "docker-host",
	}
}

func (d *dockerCLI) sampleHostPressure() hostPressureTelemetry {
	d.hostPressureMu.Lock()
	defer d.hostPressureMu.Unlock()

	procPath := d.hostProcPath
	if procPath == "" {
		procPath = defaultHostProcPath
	}
	readFile := d.readHostFile
	if readFile == nil {
		readFile = os.ReadFile
	}
	pressure := unavailableHostPressure()

	if data, err := readFile(filepath.Join(procPath, "stat")); err == nil {
		if current, parseErr := parseHostCPUCounters(data); parseErr == nil {
			pressure.CPUUtilizationPercent = calculateCPUUtilization(
				d.previousHostCPU,
				current,
			)
			d.previousHostCPU = &current
		}
	}
	if data, err := readFile(filepath.Join(procPath, "loadavg")); err == nil {
		pressure.Load1, pressure.Load5, pressure.Load15 = parseLoadAverages(data)
	}
	if data, err := readFile(filepath.Join(procPath, "meminfo")); err == nil {
		pressure.MemoryTotalBytes,
			pressure.MemoryAvailableBytes,
			pressure.SwapUsedBytes = parseHostMemory(data)
	}
	if data, err := readFile(filepath.Join(procPath, "pressure", "cpu")); err == nil {
		pressure.CPUPressureSomeAvg10,
			pressure.CPUPressureFullAvg10 = parsePSIAvg10(data)
	}
	if data, err := readFile(filepath.Join(procPath, "pressure", "memory")); err == nil {
		pressure.MemoryPressureSomeAvg10,
			pressure.MemoryPressureFullAvg10 = parsePSIAvg10(data)
	}
	if data, err := readFile(filepath.Join(procPath, "pressure", "io")); err == nil {
		pressure.IOPressureSomeAvg10,
			pressure.IOPressureFullAvg10 = parsePSIAvg10(data)
	}

	coreAvailable := pressure.CPUUtilizationPercent != nil &&
		pressure.Load1 != nil &&
		pressure.Load5 != nil &&
		pressure.Load15 != nil &&
		pressure.MemoryTotalBytes != nil &&
		pressure.MemoryAvailableBytes != nil &&
		pressure.SwapUsedBytes != nil
	switch {
	case coreAvailable:
		pressure.Status = "available"
	case hostPressureHasMeasurement(pressure):
		pressure.Status = "partial"
	default:
		pressure.Status = "unavailable"
	}
	return pressure
}

func parseHostCPUCounters(data []byte) (hostCPUCounters, error) {
	scanner := bufio.NewScanner(bytes.NewReader(data))
	if !scanner.Scan() {
		return hostCPUCounters{}, errors.New("host CPU stat is empty")
	}
	fields := strings.Fields(scanner.Text())
	if len(fields) < 5 || fields[0] != "cpu" {
		return hostCPUCounters{}, errors.New("host CPU stat has no aggregate row")
	}
	limit := min(len(fields), 9)
	var total uint64
	values := make([]uint64, 0, limit-1)
	for _, field := range fields[1:limit] {
		value, err := strconv.ParseUint(field, 10, 64)
		if err != nil {
			return hostCPUCounters{}, errors.New("host CPU stat has an invalid counter")
		}
		values = append(values, value)
		total += value
	}
	idle := values[3]
	if len(values) > 4 {
		idle += values[4]
	}
	return hostCPUCounters{total: total, idle: idle}, nil
}

func calculateCPUUtilization(
	previous *hostCPUCounters,
	current hostCPUCounters,
) *float64 {
	if previous == nil ||
		current.total <= previous.total ||
		current.idle < previous.idle {
		return nil
	}
	totalDelta := current.total - previous.total
	idleDelta := current.idle - previous.idle
	if idleDelta > totalDelta {
		return nil
	}
	value := float64(totalDelta-idleDelta) / float64(totalDelta) * 100
	return &value
}

func parseLoadAverages(data []byte) (*float64, *float64, *float64) {
	fields := strings.Fields(string(data))
	if len(fields) < 3 {
		return nil, nil, nil
	}
	values := make([]*float64, 3)
	for index := range values {
		values[index] = parseNonnegativeFloat(fields[index])
	}
	return values[0], values[1], values[2]
}

func parseHostMemory(data []byte) (*int64, *int64, *int64) {
	values := make(map[string]int64)
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 3 {
			continue
		}
		name := strings.TrimSuffix(fields[0], ":")
		if name != "MemTotal" &&
			name != "MemAvailable" &&
			name != "SwapTotal" &&
			name != "SwapFree" {
			continue
		}
		kibibytes, err := strconv.ParseInt(fields[1], 10, 64)
		if err != nil || kibibytes < 0 {
			continue
		}
		if fields[2] != "kB" {
			continue
		}
		if kibibytes > math.MaxInt64/1024 {
			continue
		}
		values[name] = kibibytes * 1024
	}
	if scanner.Err() != nil {
		return nil, nil, nil
	}
	total, totalExists := values["MemTotal"]
	available, availableExists := values["MemAvailable"]
	swapTotal, swapTotalExists := values["SwapTotal"]
	swapFree, swapFreeExists := values["SwapFree"]
	if !totalExists || total <= 0 || !availableExists || available > total {
		return nil, nil, nil
	}
	if !swapTotalExists || !swapFreeExists || swapFree > swapTotal {
		return &total, &available, nil
	}
	swapUsed := swapTotal - swapFree
	return &total, &available, &swapUsed
}

func parsePSIAvg10(data []byte) (*float64, *float64) {
	var some *float64
	var full *float64
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 2 {
			continue
		}
		value := psiField(fields[1:], "avg10")
		switch fields[0] {
		case "some":
			some = value
		case "full":
			full = value
		}
	}
	return some, full
}

func psiField(fields []string, name string) *float64 {
	for _, field := range fields {
		key, value, found := strings.Cut(field, "=")
		if found && key == name {
			parsed := parseNonnegativeFloat(value)
			if parsed != nil && *parsed <= 100 {
				return parsed
			}
			return nil
		}
	}
	return nil
}

func parseNonnegativeFloat(value string) *float64 {
	parsed, err := strconv.ParseFloat(value, 64)
	if err != nil || math.IsNaN(parsed) || math.IsInf(parsed, 0) || parsed < 0 {
		return nil
	}
	return &parsed
}

func hostPressureHasMeasurement(pressure hostPressureTelemetry) bool {
	return pressure.CPUUtilizationPercent != nil ||
		pressure.Load1 != nil ||
		pressure.Load5 != nil ||
		pressure.Load15 != nil ||
		pressure.MemoryTotalBytes != nil ||
		pressure.MemoryAvailableBytes != nil ||
		pressure.SwapUsedBytes != nil ||
		pressure.CPUPressureSomeAvg10 != nil ||
		pressure.CPUPressureFullAvg10 != nil ||
		pressure.MemoryPressureSomeAvg10 != nil ||
		pressure.MemoryPressureFullAvg10 != nil ||
		pressure.IOPressureSomeAvg10 != nil ||
		pressure.IOPressureFullAvg10 != nil
}
