package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestParseCPUInfoReportsModelAndPhysicalCoresOnlyWithCompleteTopology(
	t *testing.T,
) {
	data := []byte(`
processor : 0
physical id : 0
core id : 0
model name : Example Processor 9000

processor : 1
physical id : 0
core id : 0
model name : Example Processor 9000

processor : 2
physical id : 0
core id : 1
model name : Example Processor 9000
`)
	model, cores := parseCPUInfo(data)
	if model != "Example Processor 9000" {
		t.Fatalf("unexpected processor model %q", model)
	}
	if cores == nil || *cores != 2 {
		t.Fatalf("unexpected physical core count %#v", cores)
	}

	_, incomplete := parseCPUInfo([]byte(`
processor : 0
model name : Example Processor 9000
`))
	if incomplete != nil {
		t.Fatalf("incomplete topology produced a physical core count: %d", *incomplete)
	}
}

func TestParseDockerHardwareInfoKeepsOnlyBoundedSelectedFields(t *testing.T) {
	values, err := parseDockerHardwareInfo([]byte(
		`{"logicalProcessorCount":20,"memoryBytes":34359738368,` +
			`"operatingSystem":" Docker Desktop  ","dockerServerVersion":"28.3.3",` +
			`"dockerStorageDriver":"overlayfs"}`,
	))
	if err != nil {
		t.Fatal(err)
	}
	if values.LogicalProcessorCount == nil ||
		*values.LogicalProcessorCount != 20 ||
		values.MemoryBytes == nil ||
		*values.MemoryBytes != 34359738368 {
		t.Fatalf("unexpected Docker capacity values: %+v", values)
	}
	if values.OperatingSystem == nil || *values.OperatingSystem != "Docker Desktop" {
		t.Fatalf("operating system was not normalized: %+v", values.OperatingSystem)
	}
	if values.DockerStorageDriver == nil ||
		*values.DockerStorageDriver != "overlayfs" {
		t.Fatalf("storage driver was not retained: %+v", values.DockerStorageDriver)
	}
}

func TestHostHardwareHashMatchesFixedManagerCanonicalOrder(t *testing.T) {
	processorModel := "Example Processor 9000"
	architecture := "amd64"
	physicalCores := int64(2)
	logicalProcessors := int64(16)
	memoryBytes := int64(34359738368)
	operatingSystem := "Docker Desktop"
	kernelVersion := "6.12.34-test"
	dockerVersion := "28.3.3"
	storageDriver := "overlayfs"
	backingFilesystem := "extfs"
	hash, err := hostHardwareValuesHash(hostHardwareValues{
		ProcessorModel:          &processorModel,
		Architecture:            &architecture,
		PhysicalCoreCount:       &physicalCores,
		LogicalProcessorCount:   &logicalProcessors,
		MemoryBytes:             &memoryBytes,
		OperatingSystem:         &operatingSystem,
		KernelVersion:           &kernelVersion,
		DockerServerVersion:     &dockerVersion,
		DockerStorageDriver:     &storageDriver,
		DockerBackingFilesystem: &backingFilesystem,
	})
	if err != nil {
		t.Fatal(err)
	}
	if hash != "c4e642cd75f1f5b5028b528beefca104d35f7eccc3dac31627017d4ed5857e42" {
		t.Fatalf("fixed and autoscaled managers disagree on hardware hash: %s", hash)
	}
}

func TestReconcileHostHardwareInventoryPreservesStableCollectionIdentity(
	t *testing.T,
) {
	firstAt := time.Date(2026, 8, 3, 12, 0, 0, 0, time.UTC)
	architecture := "amd64"
	processors := int64(20)
	values := hostHardwareValues{
		Architecture:          &architecture,
		LogicalProcessorCount: &processors,
	}
	first, err := reconcileHostHardwareInventory(
		hostHardwareInventory{},
		hostHardwareSample{values: values, succeeded: true},
		firstAt,
	)
	if err != nil {
		t.Fatal(err)
	}
	if first.Status != "current" || first.CollectedAt == nil ||
		*first.CollectedAt != firstAt.Format(time.RFC3339) ||
		first.InventoryHash == nil {
		t.Fatalf("unexpected initial inventory: %+v", first)
	}

	secondAt := firstAt.Add(5 * time.Minute)
	second, err := reconcileHostHardwareInventory(
		first,
		hostHardwareSample{values: values, succeeded: true},
		secondAt,
	)
	if err != nil {
		t.Fatal(err)
	}
	if second.CollectedAt == nil || *second.CollectedAt != *first.CollectedAt {
		t.Fatalf("stable inventory changed collection identity: %+v", second)
	}
	if second.AttemptedAt != secondAt.Format(time.RFC3339) {
		t.Fatalf("stable inventory did not advance attempt time: %+v", second)
	}

	failedAt := secondAt.Add(5 * time.Minute)
	stale, err := reconcileHostHardwareInventory(
		second,
		hostHardwareSample{},
		failedAt,
	)
	if err != nil {
		t.Fatal(err)
	}
	if stale.Status != "stale" || stale.InventoryHash == nil ||
		*stale.InventoryHash != *second.InventoryHash ||
		stale.AttemptedAt != failedAt.Format(time.RFC3339) {
		t.Fatalf("failed refresh did not preserve stale inventory: %+v", stale)
	}

	unavailable, err := reconcileHostHardwareInventory(
		hostHardwareInventory{},
		hostHardwareSample{},
		failedAt,
	)
	if err != nil {
		t.Fatal(err)
	}
	if unavailable.Status != "unavailable" ||
		unavailable.InventoryHash != nil ||
		unavailable.CollectedAt != nil {
		t.Fatalf("missing initial inventory was not unavailable: %+v", unavailable)
	}
}

func TestReadHostHardwareInventoryRejectsTamperedHash(t *testing.T) {
	at := time.Date(2026, 8, 3, 12, 0, 0, 0, time.UTC)
	architecture := "amd64"
	inventory, err := reconcileHostHardwareInventory(
		hostHardwareInventory{},
		hostHardwareSample{
			values:    hostHardwareValues{Architecture: &architecture},
			succeeded: true,
		},
		at,
	)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "host-hardware.json")
	if err := writeJSONAtomically(path, inventory); err != nil {
		t.Fatal(err)
	}
	if _, err := readHostHardwareInventory(path); err != nil {
		t.Fatalf("valid inventory was rejected: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	tampered := strings.Replace(
		string(data),
		`"architecture": "amd64"`,
		`"architecture": "arm64"`,
		1,
	)
	if err := os.WriteFile(path, []byte(tampered), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := readHostHardwareInventory(path); err == nil {
		t.Fatal("tampered host hardware inventory was accepted")
	}
}

func TestManagerSamplesHardwareOnBoundedIntervalAndPersistsIt(t *testing.T) {
	at := time.Date(2026, 8, 3, 12, 0, 0, 0, time.UTC)
	clock := &fakeClock{current: at}
	docker := newFakeDockerClient(&eventRecorder{})
	architecture := "amd64"
	docker.hardwareSet = true
	docker.hardwareResult = hostHardwareSample{
		values:    hostHardwareValues{Architecture: &architecture},
		succeeded: true,
	}
	stateDirectory := t.TempDir()
	manager := &autoscalerManager{
		docker:        docker,
		clock:         clock,
		paths:         newStatePaths(stateDirectory),
		managerStatus: "running",
	}
	first, err := manager.sampleHostHardware()
	if err != nil {
		t.Fatal(err)
	}
	if first.Status != "current" || docker.hardwareCalls != 1 {
		t.Fatalf("initial hardware sample was not collected: %+v", first)
	}
	if _, err := readHostHardwareInventory(manager.paths.hardware); err != nil {
		t.Fatalf("hardware sample was not persisted: %v", err)
	}

	clock.current = at.Add(hostHardwareInventoryInterval - time.Second)
	if _, err := manager.sampleHostHardware(); err != nil {
		t.Fatal(err)
	}
	if docker.hardwareCalls != 1 {
		t.Fatalf("hardware was resampled before the interval: %d", docker.hardwareCalls)
	}

	clock.current = at.Add(hostHardwareInventoryInterval)
	if _, err := manager.sampleHostHardware(); err != nil {
		t.Fatal(err)
	}
	if docker.hardwareCalls != 2 {
		t.Fatalf("hardware was not resampled at the interval: %d", docker.hardwareCalls)
	}
}

func TestDockerHardwareSampleUsesBoundedSelectedInfo(t *testing.T) {
	executor := newScriptedCommandExecutor(map[string][]scriptedCommandResult{
		"info": {
			{output: `{"logicalProcessorCount":12,"memoryBytes":17179869184,` +
				`"operatingSystem":"Docker Desktop","dockerServerVersion":"28.3.3",` +
				`"dockerStorageDriver":"overlayfs"}`},
			{output: "extfs\n"},
		},
	})
	client := &dockerCLI{
		executor:               executor,
		resourceCommandTimeout: time.Second,
	}
	sample := client.sampleHardware(context.Background(), time.Now())
	if !sample.succeeded ||
		sample.values.LogicalProcessorCount == nil ||
		*sample.values.LogicalProcessorCount != 12 ||
		sample.values.DockerBackingFilesystem == nil ||
		*sample.values.DockerBackingFilesystem != "extfs" {
		t.Fatalf("unexpected Docker hardware sample: %+v", sample)
	}
	if sample.values.Architecture == nil ||
		*sample.values.Architecture != normalizeHardwareArchitecture(runtime.GOARCH) {
		t.Fatalf("hardware architecture used runner-label normalization: %+v", sample.values.Architecture)
	}
	if len(executor.calls) != 2 {
		t.Fatalf("unexpected Docker hardware calls: %#v", executor.calls)
	}
	for _, call := range executor.calls {
		if !call.hasDeadline {
			t.Fatal("hardware Docker query had no deadline")
		}
	}
}

func TestManagerPublishesHardwareWhenPersistenceFails(t *testing.T) {
	at := time.Date(2026, 8, 3, 12, 0, 0, 0, time.UTC)
	clock := &fakeClock{current: at}
	docker := newFakeDockerClient(&eventRecorder{})
	architecture := "amd64"
	docker.hardwareSet = true
	docker.hardwareResult = hostHardwareSample{
		values:    hostHardwareValues{Architecture: &architecture},
		succeeded: true,
	}
	manager := &autoscalerManager{
		docker:        docker,
		clock:         clock,
		paths:         newStatePaths(t.TempDir()),
		managerStatus: "running",
		writeHardware: func(string, any) error {
			return errors.New("read-only state")
		},
	}
	inventory, err := manager.sampleHostHardware()
	if err != nil {
		t.Fatalf("hardware persistence failure suppressed the sample: %v", err)
	}
	if inventory.Status != "current" || inventory.Architecture == nil {
		t.Fatalf("valid in-memory hardware was not retained: %+v", inventory)
	}
}
