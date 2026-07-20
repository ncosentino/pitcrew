package main

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestResourceTelemetryParsers(t *testing.T) {
	t.Run("CPU cores", func(t *testing.T) {
		cores, err := parseCPUCores("125.50%")
		if err != nil {
			t.Fatal(err)
		}
		if math.Abs(cores-1.255) > 0.0000001 {
			t.Fatalf("unexpected CPU cores %.8f", cores)
		}
		for _, invalid := range []string{"12", "-1%", "NaN%", "busy%"} {
			if _, err := parseCPUCores(invalid); err == nil {
				t.Fatalf("expected CPU value %q to be rejected", invalid)
			}
		}
	})

	t.Run("memory sizes", func(t *testing.T) {
		tests := []struct {
			value    string
			expected int64
		}{
			{value: "128MiB", expected: 134217728},
			{value: "1.5 GiB", expected: 1610612736},
			{value: "2GB", expected: 2000000000},
			{value: "512", expected: 512},
			{value: "0.5B", expected: 1},
		}
		for _, test := range tests {
			actual, err := parseSizeBytes(test.value)
			if err != nil {
				t.Fatalf("parse %q: %v", test.value, err)
			}
			if actual != test.expected {
				t.Fatalf(
					"size %q: expected %d, got %d",
					test.value,
					test.expected,
					actual,
				)
			}
		}
		for _, invalid := range []string{"", "1XB", "-1MiB", "1.2.3MB"} {
			if _, err := parseSizeBytes(invalid); err == nil {
				t.Fatalf("expected size %q to be rejected", invalid)
			}
		}
	})

	t.Run("container usage", func(t *testing.T) {
		usage, err := parseContainerResourceUsage(
			"25.00%",
			"128MiB / 32GiB",
			json.RawMessage(`"12"`),
		)
		if err != nil {
			t.Fatal(err)
		}
		if usage.CPUCores != 0.25 ||
			usage.MemoryWorkingSetBytes != 134217728 ||
			usage.PIDs != 12 {
			t.Fatalf("unexpected normalized usage: %#v", usage)
		}
		if _, err := parseContainerResourceUsage(
			"25.00%",
			"128MiB / 32GiB",
			json.RawMessage(`"-"`),
		); err == nil {
			t.Fatal("invalid PID data produced success-shaped usage")
		}
	})

	t.Run("host capacity", func(t *testing.T) {
		host, err := parseHostResourceCapacity([]byte(
			`{"logicalProcessorCount":16.0,"memoryBytes":34359738368}`,
		))
		if err != nil {
			t.Fatal(err)
		}
		if host.LogicalProcessorCount != 16 ||
			host.MemoryBytes != 34359738368 {
			t.Fatalf("unexpected host capacity: %#v", host)
		}
		for _, invalid := range []string{
			`{"logicalProcessorCount":0,"memoryBytes":1}`,
			`{"logicalProcessorCount":8,"memoryBytes":0}`,
			`{"logicalProcessorCount":8.5,"memoryBytes":1024}`,
		} {
			if _, err := parseHostResourceCapacity([]byte(invalid)); err == nil {
				t.Fatalf("expected host capacity %s to be rejected", invalid)
			}
		}
	})
}

func TestDockerResourceSamplingAvailable(t *testing.T) {
	executor := newScriptedCommandExecutor(map[string][]scriptedCommandResult{
		"info": {{
			output: `{"logicalProcessorCount":16,"memoryBytes":34359738368}`,
		}},
		"stats": {{
			output: strings.Join([]string{
				`{"CPUPerc":"1.25%","ID":"manager123","MemUsage":"32MiB / 32GiB","PIDs":"7"}`,
				`{"CPUPerc":"25.00%","ID":"worker123456","MemUsage":"128MiB / 32GiB","PIDs":"12"}`,
			}, "\n"),
		}},
	})
	docker := &dockerCLI{
		executor:               executor,
		hostname:               func() (string, error) { return "manager123", nil },
		resourceCommandTimeout: 100 * time.Millisecond,
	}
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	sample := docker.sampleResources(
		context.Background(),
		"profile-a",
		[]resourceContainer{{
			containerID:   "worker1234567890",
			containerName: "runner-one",
			slotKey:       "slot-one",
		}},
		now,
	)

	if sample.telemetry.Status != "available" ||
		sample.telemetry.Host == nil ||
		sample.telemetry.Manager == nil {
		t.Fatalf("complete Docker data was not available: %#v", sample.telemetry)
	}
	if sample.telemetry.Manager.CPUCores != 0.0125 ||
		sample.telemetry.Manager.MemoryWorkingSetBytes != 33554432 ||
		sample.telemetry.Manager.PIDs != 7 {
		t.Fatalf("manager usage was normalized incorrectly: %#v", sample.telemetry.Manager)
	}
	worker, exists := sample.slots["slot-one"]
	if !exists || worker.CPUCores != 0.25 ||
		worker.MemoryWorkingSetBytes != 134217728 ||
		worker.PIDs != 12 {
		t.Fatalf("worker usage was normalized incorrectly: %#v", sample.slots)
	}
	for _, call := range executor.snapshotCalls() {
		if !call.hasDeadline || call.deadlineRemaining <= 0 ||
			call.deadlineRemaining > 100*time.Millisecond {
			t.Fatalf("Docker telemetry command had no hard deadline: %#v", call)
		}
	}
}

func TestDockerResourceSamplingFindsManagerByProfileLabel(t *testing.T) {
	executor := newScriptedCommandExecutor(map[string][]scriptedCommandResult{
		"info": {{
			output: `{"logicalProcessorCount":16,"memoryBytes":34359738368}`,
		}},
		"ps": {{
			output: "manager123456\n",
		}},
		"stats": {{
			output: `{"CPUPerc":"1.25%","ID":"manager123456","MemUsage":"32MiB / 32GiB","PIDs":"7"}`,
		}},
	})
	docker := &dockerCLI{
		executor: executor,
		hostname: func() (string, error) {
			return "", errors.New("hostname unavailable")
		},
		resourceCommandTimeout: 100 * time.Millisecond,
	}
	sample := docker.sampleResources(
		context.Background(),
		"profile-a",
		nil,
		time.Now(),
	)
	if sample.telemetry.Status != "available" ||
		sample.telemetry.Manager == nil {
		t.Fatalf("manager label fallback did not recover telemetry: %#v", sample.telemetry)
	}
	calls := executor.snapshotCalls()
	if len(calls) != 3 ||
		!strings.Contains(
			strings.Join(calls[1].arguments, " "),
			managerProfileLabelKey+"=profile-a",
		) {
		t.Fatalf("manager lookup did not use the exact profile label: %#v", calls)
	}
}

func TestDockerResourceSamplingPartialFailures(t *testing.T) {
	runner := resourceContainer{
		containerID:   "worker1234567890",
		containerName: "runner-one",
		slotKey:       "slot-one",
	}
	validStats := strings.Join([]string{
		`{"CPUPerc":"1.25%","ID":"manager123","MemUsage":"32MiB / 32GiB","PIDs":"7"}`,
		`{"CPUPerc":"25.00%","ID":"worker123456","MemUsage":"128MiB / 32GiB","PIDs":"12"}`,
	}, "\n")
	tests := []struct {
		name           string
		results        map[string][]scriptedCommandResult
		expectedStatus string
		expectHost     bool
		expectManager  bool
		expectWorker   bool
	}{
		{
			name: "host unavailable",
			results: map[string][]scriptedCommandResult{
				"info":  {{err: errors.New("Docker info failed")}},
				"stats": {{output: validStats}},
			},
			expectedStatus: "partial",
			expectManager:  true,
			expectWorker:   true,
		},
		{
			name: "stats unavailable",
			results: map[string][]scriptedCommandResult{
				"info": {{
					output: `{"logicalProcessorCount":16,"memoryBytes":34359738368}`,
				}},
				"stats": {{err: errors.New("Docker stats failed")}},
			},
			expectedStatus: "partial",
			expectHost:     true,
		},
		{
			name: "stats command returned usable partial output",
			results: map[string][]scriptedCommandResult{
				"info": {{
					output: `{"logicalProcessorCount":16,"memoryBytes":34359738368}`,
				}},
				"stats": {{
					output: validStats,
					err:    errors.New("one Docker stats target disappeared"),
				}},
			},
			expectedStatus: "partial",
			expectHost:     true,
			expectManager:  true,
			expectWorker:   true,
		},
		{
			name: "one malformed worker",
			results: map[string][]scriptedCommandResult{
				"info": {{
					output: `{"logicalProcessorCount":16,"memoryBytes":34359738368}`,
				}},
				"stats": {{
					output: strings.Join([]string{
						`{"CPUPerc":"1.25%","ID":"manager123","MemUsage":"32MiB / 32GiB","PIDs":"7"}`,
						`{"CPUPerc":"25.00%","ID":"worker123456","MemUsage":"128MiB / 32GiB","PIDs":"-"}`,
					}, "\n"),
				}},
			},
			expectedStatus: "partial",
			expectHost:     true,
			expectManager:  true,
		},
		{
			name: "nothing available",
			results: map[string][]scriptedCommandResult{
				"info":  {{err: errors.New("Docker info failed")}},
				"stats": {{err: errors.New("Docker stats failed")}},
			},
			expectedStatus: "unavailable",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			docker := &dockerCLI{
				executor: newScriptedCommandExecutor(test.results),
				hostname: func() (string, error) {
					return "manager123", nil
				},
				resourceCommandTimeout: 100 * time.Millisecond,
			}
			sample := docker.sampleResources(
				context.Background(),
				"profile-a",
				[]resourceContainer{runner},
				time.Now(),
			)
			if sample.telemetry.Status != test.expectedStatus {
				t.Fatalf(
					"expected %s, got %#v",
					test.expectedStatus,
					sample.telemetry,
				)
			}
			if (sample.telemetry.Host != nil) != test.expectHost {
				t.Fatalf("unexpected host telemetry: %#v", sample.telemetry.Host)
			}
			if (sample.telemetry.Manager != nil) != test.expectManager {
				t.Fatalf("unexpected manager telemetry: %#v", sample.telemetry.Manager)
			}
			_, workerAvailable := sample.slots[runner.slotKey]
			if workerAvailable != test.expectWorker {
				t.Fatalf("unexpected worker telemetry: %#v", sample.slots)
			}
			if !test.expectManager && sample.telemetry.Manager != nil {
				t.Fatal("missing manager metrics were fabricated as zero usage")
			}
			if !test.expectWorker && len(sample.slots) != 0 {
				t.Fatal("missing worker metrics were fabricated as zero usage")
			}
		})
	}
}

func TestDockerResourceSamplingCommandsTimeOut(t *testing.T) {
	executor := newScriptedCommandExecutor(map[string][]scriptedCommandResult{
		"info":  {{waitForContext: true}},
		"stats": {{waitForContext: true}},
	})
	docker := &dockerCLI{
		executor:               executor,
		hostname:               func() (string, error) { return "manager123", nil },
		resourceCommandTimeout: 15 * time.Millisecond,
	}
	started := time.Now()
	sample := docker.sampleResources(
		context.Background(),
		"profile-a",
		nil,
		time.Now(),
	)
	elapsed := time.Since(started)
	if elapsed > 500*time.Millisecond {
		t.Fatalf("stalled Docker commands exceeded hard deadlines: %s", elapsed)
	}
	if sample.telemetry.Status != "unavailable" ||
		sample.telemetry.Host != nil ||
		sample.telemetry.Manager != nil {
		t.Fatalf("timed-out commands fabricated resource usage: %#v", sample.telemetry)
	}
}

func TestManagerPublishesAndCachesRunnerResourceTelemetry(t *testing.T) {
	directory := projectTestDirectory(t)
	clock := &fakeClock{
		current: time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC),
	}
	docker := newFakeDockerClient(nil)
	host := hostResourceCapacity{
		LogicalProcessorCount: 16,
		MemoryBytes:           34359738368,
	}
	managerUsage := resourceUsage{
		CPUCores:              0.01,
		MemoryWorkingSetBytes: 33554432,
		PIDs:                  7,
	}
	docker.resourceSet = true
	docker.resourceResult = resourceSample{
		telemetry: resourceTelemetry{
			Status:  "available",
			Host:    &host,
			Manager: &managerUsage,
		},
		slots: map[string]resourceUsage{
			"repo-one-77": {
				CPUCores:              0.25,
				MemoryWorkingSetBytes: 134217728,
				PIDs:                  12,
			},
		},
	}
	manager := newAutoscalerManager(
		managerTestConfig(directory),
		newFakeScaleSetServiceFactory(),
		docker,
		clock,
		testLogger(),
		"instance",
	)
	manager.managerStatus = "running"
	manager.recovered["repo-one"] = []recoveredContainer{{
		containerID: "worker123",
		name:        "runner-one",
		runnerName:  "runner-one",
		runnerID:    77,
		targetKey:   "repo-one",
		slotKey:     "repo-one-77",
		createdAt:   clock.now(),
	}}
	var published observedState
	manager.writeObserved = func(_ string, value any) error {
		published = value.(observedState)
		return nil
	}

	if err := manager.publishObserved(); err != nil {
		t.Fatal(err)
	}
	if published.ResourceTelemetry.Status != "available" ||
		published.ResourceTelemetry.SampledAt != clock.now().UTC().Format(time.RFC3339) ||
		published.ResourceTelemetry.Host == nil ||
		published.ResourceTelemetry.Manager == nil ||
		len(published.Slots) != 1 ||
		published.Slots[0].Resources == nil {
		t.Fatalf("observed state lost Docker resource telemetry: %#v", published)
	}
	if published.Slots[0].Resources.CPUCores != 0.25 {
		t.Fatalf("runner CPU telemetry was not projected: %#v", published.Slots[0])
	}
	if docker.resourceCalls != 1 ||
		len(docker.resourceRequests) != 1 ||
		len(docker.resourceRequests[0]) != 1 {
		t.Fatalf("unexpected Docker resource inventory: %#v", docker.resourceRequests)
	}

	if err := manager.publishObserved(); err != nil {
		t.Fatal(err)
	}
	if docker.resourceCalls != 1 {
		t.Fatal("unchanged inventory was sampled again before the observation interval")
	}
	clock.advance(manager.cfg.observedInterval)
	if err := manager.publishObserved(); err != nil {
		t.Fatal(err)
	}
	if docker.resourceCalls != 2 {
		t.Fatal("resource telemetry was not refreshed after the observation interval")
	}
}

type scriptedCommandResult struct {
	output         string
	err            error
	waitForContext bool
}

type scriptedCommandCall struct {
	arguments         []string
	hasDeadline       bool
	deadlineRemaining time.Duration
}

type scriptedCommandExecutor struct {
	mu      sync.Mutex
	results map[string][]scriptedCommandResult
	calls   []scriptedCommandCall
}

func newScriptedCommandExecutor(
	results map[string][]scriptedCommandResult,
) *scriptedCommandExecutor {
	cloned := make(map[string][]scriptedCommandResult, len(results))
	for command, commandResults := range results {
		cloned[command] = append([]scriptedCommandResult(nil), commandResults...)
	}
	return &scriptedCommandExecutor{results: cloned}
}

func (e *scriptedCommandExecutor) run(
	ctx context.Context,
	arguments ...string,
) ([]byte, error) {
	deadline, hasDeadline := ctx.Deadline()
	call := scriptedCommandCall{
		arguments:   append([]string(nil), arguments...),
		hasDeadline: hasDeadline,
	}
	if hasDeadline {
		call.deadlineRemaining = time.Until(deadline)
	}
	e.mu.Lock()
	e.calls = append(e.calls, call)
	if len(arguments) == 0 || len(e.results[arguments[0]]) == 0 {
		e.mu.Unlock()
		return nil, errors.New("unexpected command")
	}
	result := e.results[arguments[0]][0]
	e.results[arguments[0]] = e.results[arguments[0]][1:]
	e.mu.Unlock()
	if result.waitForContext {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	return []byte(result.output), result.err
}

func (e *scriptedCommandExecutor) stream(
	context.Context,
	[]string,
	func(string),
) error {
	return errors.New("stream is not expected for telemetry tests")
}

func (e *scriptedCommandExecutor) snapshotCalls() []scriptedCommandCall {
	e.mu.Lock()
	defer e.mu.Unlock()
	return append([]scriptedCommandCall(nil), e.calls...)
}

var _ commandExecutor = (*scriptedCommandExecutor)(nil)
