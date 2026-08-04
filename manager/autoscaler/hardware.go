package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"runtime"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	hostHardwareInventoryInterval = 5 * time.Minute
	hostHardwareTextMaximumLength = 256
	hostArchitectureMaximumLength = 64
)

type hostHardwareValues struct {
	ProcessorModel          *string `json:"processorModel"`
	Architecture            *string `json:"architecture"`
	PhysicalCoreCount       *int64  `json:"physicalCoreCount"`
	LogicalProcessorCount   *int64  `json:"logicalProcessorCount"`
	PerformanceCoreCount    *int64  `json:"performanceCoreCount"`
	EfficiencyCoreCount     *int64  `json:"efficiencyCoreCount"`
	MemoryBytes             *int64  `json:"memoryBytes"`
	OperatingSystem         *string `json:"operatingSystem"`
	KernelVersion           *string `json:"kernelVersion"`
	DockerServerVersion     *string `json:"dockerServerVersion"`
	DockerStorageDriver     *string `json:"dockerStorageDriver"`
	DockerBackingFilesystem *string `json:"dockerBackingFilesystem"`
}

type hostHardwareInventory struct {
	Status        string  `json:"status"`
	CollectedAt   *string `json:"collectedAt"`
	AttemptedAt   string  `json:"attemptedAt"`
	InventoryHash *string `json:"inventoryHash"`
	hostHardwareValues
}

type hostHardwareSample struct {
	values    hostHardwareValues
	succeeded bool
}

type observedHost struct {
	Hardware hostHardwareInventory `json:"hardware"`
}

func unavailableHostHardwareInventory(attemptedAt time.Time) hostHardwareInventory {
	return hostHardwareInventory{
		Status:      "unavailable",
		AttemptedAt: attemptedAt.UTC().Format(time.RFC3339),
	}
}

func (d *dockerCLI) sampleHardware(
	ctx context.Context,
	attemptedAt time.Time,
) hostHardwareSample {
	values := collectLocalHardwareValues(
		runtime.GOARCH,
		readOptionalHardwareFile("/proc/cpuinfo"),
		readOptionalHardwareFile("/proc/sys/kernel/osrelease"),
	)
	output, err := d.runTelemetryCommand(
		ctx,
		"info",
		"--format",
		`{"logicalProcessorCount":{{.NCPU}},"memoryBytes":{{.MemTotal}},"operatingSystem":{{json .OperatingSystem}},"dockerServerVersion":{{json .ServerVersion}},"dockerStorageDriver":{{json .Driver}}}`,
	)
	if err == nil {
		if dockerValues, parseErr := parseDockerHardwareInfo(output); parseErr == nil {
			values.LogicalProcessorCount = dockerValues.LogicalProcessorCount
			values.MemoryBytes = dockerValues.MemoryBytes
			values.OperatingSystem = dockerValues.OperatingSystem
			values.DockerServerVersion = dockerValues.DockerServerVersion
			values.DockerStorageDriver = dockerValues.DockerStorageDriver
			backingOutput, backingErr := d.runTelemetryCommand(
				ctx,
				"info",
				"--format",
				`{{range .DriverStatus}}{{if eq (index . 0) "Backing Filesystem"}}{{index . 1}}{{end}}{{end}}`,
			)
			if backingErr == nil {
				values.DockerBackingFilesystem = hardwareTextPointer(
					string(backingOutput),
					hostHardwareTextMaximumLength,
				)
			}
			return hostHardwareSample{values: values, succeeded: true}
		}
	}
	return hostHardwareSample{values: values}
}

func readOptionalHardwareFile(path string) []byte {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	return data
}

func collectLocalHardwareValues(
	architecture string,
	cpuInfo []byte,
	kernelVersion []byte,
) hostHardwareValues {
	values := hostHardwareValues{
		Architecture: hardwareTextPointer(
			normalizeHardwareArchitecture(architecture),
			hostArchitectureMaximumLength,
		),
		KernelVersion: hardwareTextPointer(
			string(kernelVersion),
			hostHardwareTextMaximumLength,
		),
	}
	model, physicalCores := parseCPUInfo(cpuInfo)
	values.ProcessorModel = hardwareTextPointer(
		model,
		hostHardwareTextMaximumLength,
	)
	values.PhysicalCoreCount = physicalCores
	return values
}

func normalizeHardwareArchitecture(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "amd64", "x86_64", "x64":
		return "amd64"
	case "arm64", "aarch64":
		return "arm64"
	case "arm", "armv6", "armv7", "armv7l":
		return "arm"
	case "386", "i386", "i486", "i586", "i686":
		return "386"
	default:
		return strings.ToLower(strings.TrimSpace(value))
	}
}

func parseCPUInfo(data []byte) (string, *int64) {
	records := bytes.Split(bytes.ReplaceAll(data, []byte("\r\n"), []byte("\n")), []byte("\n\n"))
	model := ""
	processorRecords := int64(0)
	completeTopologyRecords := int64(0)
	physicalCores := make(map[string]struct{})
	for _, record := range records {
		fields := make(map[string]string)
		for _, line := range bytes.Split(record, []byte("\n")) {
			key, value, found := bytes.Cut(line, []byte(":"))
			if !found {
				continue
			}
			fields[strings.TrimSpace(string(key))] = strings.TrimSpace(string(value))
		}
		if _, exists := fields["processor"]; exists {
			processorRecords++
			physicalID := fields["physical id"]
			coreID := fields["core id"]
			if physicalID != "" && coreID != "" {
				completeTopologyRecords++
				physicalCores[physicalID+":"+coreID] = struct{}{}
			}
		}
		if model == "" {
			for _, key := range []string{"model name", "Processor", "Hardware"} {
				if value := fields[key]; value != "" {
					model = value
					break
				}
			}
		}
	}
	if processorRecords == 0 ||
		completeTopologyRecords != processorRecords ||
		len(physicalCores) == 0 {
		return model, nil
	}
	count := int64(len(physicalCores))
	return model, &count
}

func parseDockerHardwareInfo(data []byte) (hostHardwareValues, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var record struct {
		LogicalProcessorCount json.Number `json:"logicalProcessorCount"`
		MemoryBytes           json.Number `json:"memoryBytes"`
		OperatingSystem       string      `json:"operatingSystem"`
		DockerServerVersion   string      `json:"dockerServerVersion"`
		DockerStorageDriver   string      `json:"dockerStorageDriver"`
	}
	if err := decoder.Decode(&record); err != nil {
		return hostHardwareValues{}, fmt.Errorf("decode Docker hardware info: %w", err)
	}
	if err := requireJSONEnd(decoder); err != nil {
		return hostHardwareValues{}, err
	}
	logicalProcessors, err := parsePositiveJSONInteger(record.LogicalProcessorCount)
	if err != nil {
		return hostHardwareValues{}, fmt.Errorf("parse logical processor count: %w", err)
	}
	memoryBytes, err := parsePositiveJSONInteger(record.MemoryBytes)
	if err != nil {
		return hostHardwareValues{}, fmt.Errorf("parse host memory: %w", err)
	}
	return hostHardwareValues{
		LogicalProcessorCount: &logicalProcessors,
		MemoryBytes:           &memoryBytes,
		OperatingSystem: hardwareTextPointer(
			record.OperatingSystem,
			hostHardwareTextMaximumLength,
		),
		DockerServerVersion: hardwareTextPointer(
			record.DockerServerVersion,
			hostHardwareTextMaximumLength,
		),
		DockerStorageDriver: hardwareTextPointer(
			record.DockerStorageDriver,
			hostHardwareTextMaximumLength,
		),
	}, nil
}

func hardwareTextPointer(value string, maximumLength int) *string {
	normalized := strings.Join(strings.Fields(value), " ")
	if normalized == "" || utf8.RuneCountInString(normalized) > maximumLength ||
		strings.IndexFunc(normalized, unicode.IsControl) >= 0 {
		return nil
	}
	return &normalized
}

func (v hostHardwareValues) available() bool {
	return v.ProcessorModel != nil ||
		v.Architecture != nil ||
		v.PhysicalCoreCount != nil ||
		v.LogicalProcessorCount != nil ||
		v.PerformanceCoreCount != nil ||
		v.EfficiencyCoreCount != nil ||
		v.MemoryBytes != nil ||
		v.OperatingSystem != nil ||
		v.KernelVersion != nil ||
		v.DockerServerVersion != nil ||
		v.DockerStorageDriver != nil ||
		v.DockerBackingFilesystem != nil
}

func hostHardwareValuesHash(values hostHardwareValues) (string, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(values); err != nil {
		return "", fmt.Errorf("marshal host hardware values: %w", err)
	}
	data := bytes.TrimSuffix(buffer.Bytes(), []byte("\n"))
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:]), nil
}

func reconcileHostHardwareInventory(
	previous hostHardwareInventory,
	sample hostHardwareSample,
	attemptedAt time.Time,
) (hostHardwareInventory, error) {
	attempted := attemptedAt.UTC().Format(time.RFC3339)
	if !sample.succeeded || !sample.values.available() {
		if previous.validRetainedInventory() {
			previous.Status = "stale"
			previous.AttemptedAt = attempted
			return previous, nil
		}
		return unavailableHostHardwareInventory(attemptedAt), nil
	}
	hash, err := hostHardwareValuesHash(sample.values)
	if err != nil {
		return hostHardwareInventory{}, err
	}
	collected := attempted
	if previous.InventoryHash != nil &&
		*previous.InventoryHash == hash &&
		previous.CollectedAt != nil {
		collected = *previous.CollectedAt
	}
	return hostHardwareInventory{
		Status:             "current",
		CollectedAt:        &collected,
		AttemptedAt:        attempted,
		InventoryHash:      &hash,
		hostHardwareValues: sample.values,
	}, nil
}

func (i hostHardwareInventory) validRetainedInventory() bool {
	if i.Status != "current" && i.Status != "stale" {
		return false
	}
	if i.CollectedAt == nil || i.InventoryHash == nil ||
		len(*i.InventoryHash) != sha256.Size*2 ||
		!i.hostHardwareValues.available() {
		return false
	}
	if _, err := time.Parse(time.RFC3339, *i.CollectedAt); err != nil {
		return false
	}
	if _, err := time.Parse(time.RFC3339, i.AttemptedAt); err != nil {
		return false
	}
	for _, character := range *i.InventoryHash {
		if !strings.ContainsRune("0123456789abcdef", character) {
			return false
		}
	}
	expected, err := hostHardwareValuesHash(i.hostHardwareValues)
	return err == nil && expected == *i.InventoryHash
}

func readHostHardwareInventory(path string) (hostHardwareInventory, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return hostHardwareInventory{}, nil
		}
		return hostHardwareInventory{}, fmt.Errorf("read host hardware inventory: %w", err)
	}
	var inventory hostHardwareInventory
	if err := json.Unmarshal(data, &inventory); err != nil {
		return hostHardwareInventory{}, fmt.Errorf("decode host hardware inventory: %w", err)
	}
	if inventory.Status == "unavailable" {
		if inventory.CollectedAt != nil || inventory.InventoryHash != nil ||
			inventory.hostHardwareValues.available() {
			return hostHardwareInventory{}, errors.New("unavailable host hardware inventory contains retained values")
		}
		if _, err := time.Parse(time.RFC3339, inventory.AttemptedAt); err != nil {
			return hostHardwareInventory{}, errors.New("unavailable host hardware inventory has invalid attempt timestamp")
		}
		return inventory, nil
	}
	if !inventory.validRetainedInventory() {
		return hostHardwareInventory{}, errors.New("host hardware inventory is invalid")
	}
	return inventory, nil
}
