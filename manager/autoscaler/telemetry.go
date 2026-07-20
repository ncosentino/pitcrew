package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"math/big"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
)

const resourceTelemetryCommandTimeout = 3 * time.Second

type resourceUsage struct {
	CPUCores              float64 `json:"cpuCores"`
	MemoryWorkingSetBytes int64   `json:"memoryWorkingSetBytes"`
	PIDs                  int64   `json:"pids"`
}

type hostResourceCapacity struct {
	LogicalProcessorCount int64 `json:"logicalProcessorCount"`
	MemoryBytes           int64 `json:"memoryBytes"`
}

type resourceContainer struct {
	containerID   string
	containerName string
	slotKey       string
}

type resourceSample struct {
	telemetry resourceTelemetry
	slots     map[string]resourceUsage
}

func unavailableResourceSample(sampledAt time.Time) resourceSample {
	return resourceSample{
		telemetry: resourceTelemetry{
			SampledAt: sampledAt.UTC().Format(time.RFC3339),
			Status:    "unavailable",
			Host:      nil,
			Manager:   nil,
		},
		slots: make(map[string]resourceUsage),
	}
}

func (d *dockerCLI) sampleResources(
	ctx context.Context,
	profileID string,
	runners []resourceContainer,
	sampledAt time.Time,
) resourceSample {
	sample := unavailableResourceSample(sampledAt)

	hostOutput, hostErr := d.runTelemetryCommand(
		ctx,
		"info",
		"--format",
		`{"logicalProcessorCount":{{.NCPU}},"memoryBytes":{{.MemTotal}}}`,
	)
	if hostErr == nil {
		if host, err := parseHostResourceCapacity(hostOutput); err == nil {
			sample.telemetry.Host = &host
		}
	}

	managerID := ""
	if d.hostname != nil {
		if value, err := d.hostname(); err == nil {
			managerID = strings.TrimSpace(value)
		}
	}
	if managerID == "" {
		output, err := d.runTelemetryCommand(
			ctx,
			"ps",
			"--quiet",
			"--no-trunc",
			"--filter",
			"label="+managerProfileLabelKey+"="+profileID,
		)
		if err == nil {
			ids := strings.Fields(string(output))
			if len(ids) > 0 {
				managerID = ids[0]
			}
		}
	}

	runners = append([]resourceContainer(nil), runners...)
	sort.Slice(runners, func(i, j int) bool {
		if runners[i].containerID == runners[j].containerID {
			return runners[i].slotKey < runners[j].slotKey
		}
		return runners[i].containerID < runners[j].containerID
	})
	arguments := []string{"stats", "--no-stream", "--format", "{{json .}}"}
	if managerID != "" {
		arguments = append(arguments, managerID)
	}
	for _, runner := range runners {
		if runner.containerID != "" {
			arguments = append(arguments, runner.containerID)
		}
	}

	statsSucceeded := false
	if len(arguments) > 4 {
		output, err := d.runTelemetryCommand(ctx, arguments...)
		statsSucceeded = err == nil
		manager, slots, parseErr := parseDockerResourceStats(
			output,
			managerID,
			runners,
		)
		if parseErr != nil {
			statsSucceeded = false
		}
		sample.telemetry.Manager = manager
		sample.slots = slots
	}

	allRunnersObserved := len(sample.slots) == len(runners)
	switch {
	case sample.telemetry.Host != nil &&
		sample.telemetry.Manager != nil &&
		statsSucceeded &&
		allRunnersObserved:
		sample.telemetry.Status = "available"
	case sample.telemetry.Host != nil ||
		sample.telemetry.Manager != nil ||
		len(sample.slots) > 0:
		sample.telemetry.Status = "partial"
	default:
		sample.telemetry.Status = "unavailable"
		sample.telemetry.Host = nil
		sample.telemetry.Manager = nil
		clear(sample.slots)
	}
	return sample
}

func (d *dockerCLI) runTelemetryCommand(
	parent context.Context,
	arguments ...string,
) ([]byte, error) {
	timeout := d.resourceCommandTimeout
	if timeout <= 0 {
		timeout = resourceTelemetryCommandTimeout
	}
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	return d.executor.run(ctx, arguments...)
}

func parseHostResourceCapacity(data []byte) (hostResourceCapacity, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var record struct {
		LogicalProcessorCount json.Number `json:"logicalProcessorCount"`
		MemoryBytes           json.Number `json:"memoryBytes"`
	}
	if err := decoder.Decode(&record); err != nil {
		return hostResourceCapacity{}, fmt.Errorf("decode Docker host capacity: %w", err)
	}
	if err := requireJSONEnd(decoder); err != nil {
		return hostResourceCapacity{}, err
	}
	processors, err := parsePositiveJSONInteger(record.LogicalProcessorCount)
	if err != nil {
		return hostResourceCapacity{}, fmt.Errorf("parse logical processor count: %w", err)
	}
	memory, err := parsePositiveJSONInteger(record.MemoryBytes)
	if err != nil {
		return hostResourceCapacity{}, fmt.Errorf("parse host memory: %w", err)
	}
	return hostResourceCapacity{
		LogicalProcessorCount: processors,
		MemoryBytes:           memory,
	}, nil
}

func parseDockerResourceStats(
	data []byte,
	managerID string,
	runners []resourceContainer,
) (*resourceUsage, map[string]resourceUsage, error) {
	var manager *resourceUsage
	slots := make(map[string]resourceUsage)
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var record struct {
			ID        string          `json:"ID"`
			Container string          `json:"Container"`
			Name      string          `json:"Name"`
			CPUPerc   string          `json:"CPUPerc"`
			MemUsage  string          `json:"MemUsage"`
			PIDs      json.RawMessage `json:"PIDs"`
		}
		if err := json.Unmarshal(line, &record); err != nil {
			continue
		}
		usage, err := parseContainerResourceUsage(
			record.CPUPerc,
			record.MemUsage,
			record.PIDs,
		)
		if err != nil {
			continue
		}
		identifier := strings.TrimSpace(record.ID)
		if identifier == "" {
			identifier = strings.TrimSpace(record.Container)
		}
		if managerID != "" && identifiersMatch(identifier, managerID) {
			value := usage
			manager = &value
			continue
		}
		if runner, ok := matchResourceContainer(identifier, record.Name, runners); ok {
			slots[runner.slotKey] = usage
		}
	}
	if err := scanner.Err(); err != nil {
		return manager, slots, fmt.Errorf("scan Docker stats output: %w", err)
	}
	return manager, slots, nil
}

func parseContainerResourceUsage(
	cpuPercent string,
	memoryUsage string,
	rawPIDs json.RawMessage,
) (resourceUsage, error) {
	cpuCores, err := parseCPUCores(cpuPercent)
	if err != nil {
		return resourceUsage{}, err
	}
	memoryWorkingSet := strings.SplitN(memoryUsage, "/", 2)[0]
	memoryBytes, err := parseSizeBytes(memoryWorkingSet)
	if err != nil {
		return resourceUsage{}, err
	}
	pids, err := parsePIDs(rawPIDs)
	if err != nil {
		return resourceUsage{}, err
	}
	return resourceUsage{
		CPUCores:              cpuCores,
		MemoryWorkingSetBytes: memoryBytes,
		PIDs:                  pids,
	}, nil
}

func parseCPUCores(value string) (float64, error) {
	value = strings.TrimSpace(value)
	if !strings.HasSuffix(value, "%") {
		return 0, fmt.Errorf("CPU percentage %q has no percent suffix", value)
	}
	number := strings.TrimSpace(strings.TrimSuffix(value, "%"))
	percent, err := strconv.ParseFloat(number, 64)
	if err != nil || math.IsInf(percent, 0) || math.IsNaN(percent) || percent < 0 {
		return 0, fmt.Errorf("CPU percentage %q is invalid", value)
	}
	return percent / 100, nil
}

func parseSizeBytes(value string) (int64, error) {
	compact := strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) {
			return -1
		}
		return r
	}, value)
	numberEnd := 0
	digits := 0
	decimalPoints := 0
	for numberEnd < len(compact) {
		character := compact[numberEnd]
		switch {
		case character >= '0' && character <= '9':
			digits++
			numberEnd++
		case character == '.':
			decimalPoints++
			numberEnd++
		default:
			goto numberComplete
		}
	}

numberComplete:
	if digits == 0 || decimalPoints > 1 {
		return 0, fmt.Errorf("size %q has an invalid number", value)
	}
	numberText := compact[:numberEnd]
	unit := compact[numberEnd:]
	multipliers := map[string]int64{
		"":    1,
		"B":   1,
		"kB":  1000,
		"KB":  1000,
		"MB":  1000 * 1000,
		"GB":  1000 * 1000 * 1000,
		"TB":  1000 * 1000 * 1000 * 1000,
		"KiB": 1024,
		"MiB": 1024 * 1024,
		"GiB": 1024 * 1024 * 1024,
		"TiB": 1024 * 1024 * 1024 * 1024,
	}
	multiplier, ok := multipliers[unit]
	if !ok {
		return 0, fmt.Errorf("size %q has unsupported unit %q", value, unit)
	}
	number, ok := new(big.Rat).SetString(numberText)
	if !ok || number.Sign() < 0 {
		return 0, fmt.Errorf("size %q has an invalid number", value)
	}
	scaled := new(big.Rat).Mul(number, new(big.Rat).SetInt64(multiplier))
	quotient := new(big.Int)
	remainder := new(big.Int)
	quotient.QuoRem(scaled.Num(), scaled.Denom(), remainder)
	twiceRemainder := new(big.Int).Lsh(remainder, 1)
	if twiceRemainder.Cmp(scaled.Denom()) >= 0 {
		quotient.Add(quotient, big.NewInt(1))
	}
	if !quotient.IsInt64() {
		return 0, fmt.Errorf("size %q exceeds supported range", value)
	}
	return quotient.Int64(), nil
}

func parsePIDs(raw json.RawMessage) (int64, error) {
	if len(raw) == 0 {
		return 0, errors.New("PID count is missing")
	}
	var value any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(&value); err != nil {
		return 0, fmt.Errorf("decode PID count: %w", err)
	}
	var text string
	switch typed := value.(type) {
	case string:
		text = typed
	case json.Number:
		rational, ok := new(big.Rat).SetString(typed.String())
		if !ok || !rational.IsInt() || rational.Sign() < 0 ||
			!rational.Num().IsInt64() {
			return 0, fmt.Errorf("PID count %q is not a nonnegative integer", typed)
		}
		return rational.Num().Int64(), nil
	default:
		return 0, errors.New("PID count must be a string or number")
	}
	return parseNonnegativeDecimalInteger("PID count", strings.TrimSpace(text))
}

func parsePositiveJSONInteger(value json.Number) (int64, error) {
	rational, ok := new(big.Rat).SetString(value.String())
	if !ok || !rational.IsInt() || rational.Sign() <= 0 ||
		!rational.Num().IsInt64() {
		return 0, fmt.Errorf("%q is not a positive integer", value)
	}
	return rational.Num().Int64(), nil
}

func parseNonnegativeDecimalInteger(name, value string) (int64, error) {
	if value == "" || strings.IndexFunc(value, func(r rune) bool {
		return r < '0' || r > '9'
	}) >= 0 {
		return 0, fmt.Errorf("%s %q is not a nonnegative integer", name, value)
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("%s %q exceeds supported range", name, value)
	}
	return parsed, nil
}

func requireJSONEnd(decoder *json.Decoder) error {
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("Docker host capacity contains trailing JSON")
		}
		return fmt.Errorf("decode trailing Docker host capacity: %w", err)
	}
	return nil
}

func identifiersMatch(observed, expected string) bool {
	observed = strings.TrimSpace(observed)
	expected = strings.TrimSpace(expected)
	if observed == "" || expected == "" {
		return false
	}
	if observed == expected {
		return true
	}
	shorterLength := min(len(observed), len(expected))
	if shorterLength < 12 {
		return false
	}
	return strings.HasPrefix(observed, expected) ||
		strings.HasPrefix(expected, observed)
}

func matchResourceContainer(
	identifier string,
	name string,
	runners []resourceContainer,
) (resourceContainer, bool) {
	matches := make([]resourceContainer, 0, 1)
	for _, runner := range runners {
		if identifiersMatch(identifier, runner.containerID) ||
			(name != "" && name == runner.containerName) {
			matches = append(matches, runner)
		}
	}
	if len(matches) != 1 {
		return resourceContainer{}, false
	}
	return matches[0], true
}
