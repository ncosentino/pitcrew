package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestObservedStateAutoscalingContract(t *testing.T) {
	replicas := 4
	current, err := parseDesiredState([]byte(`{
	  "schemaVersion":1,
	  "generation":9,
	  "scope":"org",
	  "repositories":[],
	  "replicas":4
	}`), "org")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	idleSince := now.Add(-time.Minute)
	snapshot := scalerSnapshot{
		target:      targetSpec{key: "scope", maximum: replicas},
		targetSlots: 3,
		statistics: scalerStatistics{
			assignedJobs:  2,
			runningJobs:   1,
			availableJobs: 1,
		},
		idleRunners: 1,
		busyRunners: 1,
		runners: []runnerRecord{
			{
				key:         "scope-1",
				targetKey:   "scope",
				runnerName:  "runner-one",
				runnerID:    1,
				containerID: "container-one",
				state:       runnerIdle,
				startedAt:   now.Add(-2 * time.Minute),
				updatedAt:   now,
				idleSince:   &idleSince,
			},
			{
				key:         "scope-2",
				targetKey:   "scope",
				runnerName:  "runner-two",
				runnerID:    2,
				containerID: "container-two",
				state:       runnerBusy,
				startedAt:   now.Add(-time.Minute),
				updatedAt:   now,
			},
			{
				key:         "scope-3",
				targetKey:   "scope",
				runnerName:  "runner-three",
				runnerID:    3,
				containerID: "container-three",
				state:       runnerDraining,
				startedAt:   now,
				updatedAt:   now,
			},
		},
		drainingRunners:  1,
		minimumIdleSlots: 1,
	}
	cfg := config{
		profileID:      "profile-a",
		scope:          "org",
		minimumIdle:    1,
		scaleDownDelay: 120 * time.Second,
	}
	state := buildObservedState(
		cfg,
		"instance-a",
		"running",
		&current,
		"accepted",
		[]scalerSnapshot{snapshot},
		nil,
		now,
	)
	if state.ManagerContractVersion != 8 || state.DesiredSlots != 3 ||
		state.ConfiguredSlots != 4 || state.ActiveSlots != 3 ||
		state.DrainingSlots != 1 {
		t.Fatalf("unexpected observed capacity fields: %#v", state)
	}
	if state.Autoscaling.Mode != "scale-set" ||
		state.Autoscaling.MinimumIdleSlots != 1 ||
		state.Autoscaling.MaximumSlots != 4 ||
		state.Autoscaling.AssignedJobs != 2 ||
		state.Autoscaling.RunningJobs != 1 ||
		state.Autoscaling.AvailableJobs != 1 ||
		state.Autoscaling.IdleRunners != 1 ||
		state.Autoscaling.BusyRunners != 1 {
		t.Fatalf("unexpected autoscaling projection: %#v", state.Autoscaling)
	}
	if state.ResourceTelemetry.Status != "unavailable" ||
		state.ResourceTelemetry.Host != nil ||
		state.ResourceTelemetry.Manager != nil {
		t.Fatalf("resource telemetry fabricated usage: %#v", state.ResourceTelemetry)
	}
	if state.Slots[0].Resources != nil ||
		state.Slots[0].Activity == "" ||
		state.Slots[0].Target != "scope" {
		t.Fatalf("slot projection omitted autoscaling lifecycle data: %#v", state.Slots[0])
	}

	path := filepath.Join(projectTestDirectory(t), "observed-state.json")
	if err := writeJSONAtomically(path, state); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{
		"schemaVersion", "managerContractVersion", "profileId",
		"managerInstanceId", "managerStatus", "observedAt", "scope",
		"generation", "desiredStateHash", "desiredStateStatus",
		"desiredSlots", "activeSlots", "drainingSlots", "configuredSlots",
		"slots", "resourceTelemetry", "autoscaling",
	} {
		if _, exists := decoded[field]; !exists {
			t.Fatalf("observed state omitted field %q", field)
		}
	}
	slots := decoded["slots"].([]any)
	firstSlot := slots[0].(map[string]any)
	if firstSlot["target"] != "scope" {
		t.Fatalf("slot target key used the wrong contract field: %#v", firstSlot)
	}
	if _, exists := firstSlot["targetKey"]; exists {
		t.Fatalf("slot projection emitted unsupported targetKey field: %#v", firstSlot)
	}
}

func TestObservedStateAggregatesPerTargetMinimumIdle(t *testing.T) {
	current, err := parseDesiredState([]byte(`{
	  "schemaVersion":1,
	  "generation":3,
	  "scope":"repo",
	  "repositories":[
	    {"url":"https://github.com/example/one","workers":1},
	    {"url":"https://github.com/example/two","workers":4}
	  ],
	  "replicas":null
	}`), "repo")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	state := buildObservedState(
		config{
			profileID:      "profile-a",
			scope:          "repo",
			minimumIdle:    2,
			scaleDownDelay: 120 * time.Second,
		},
		"instance-a",
		"running",
		&current,
		"accepted",
		[]scalerSnapshot{
			{
				target:           targetSpec{key: "one", maximum: 1},
				minimumIdleSlots: 1,
			},
			{
				target:           targetSpec{key: "two", maximum: 4},
				minimumIdleSlots: 2,
			},
			{
				target:   targetSpec{key: "retiring", maximum: 0},
				retiring: true,
			},
		},
		nil,
		now,
	)
	if state.Autoscaling.MinimumIdleSlots != 3 {
		t.Fatalf(
			"expected per-target minimum idle aggregate 3, got %d",
			state.Autoscaling.MinimumIdleSlots,
		)
	}
}

func TestObservedStateExpandsMaximumToCoverAppliedControllerTarget(t *testing.T) {
	current, err := parseDesiredState([]byte(`{
	  "schemaVersion":1,
	  "generation":2,
	  "scope":"repo",
	  "repositories":[
	    {"url":"https://github.com/example/one","workers":2}
	  ],
	  "replicas":null
	}`), "repo")
	if err != nil {
		t.Fatal(err)
	}
	state := buildObservedState(
		config{
			profileID:      "profile-a",
			scope:          "repo",
			scaleDownDelay: 120 * time.Second,
		},
		"instance-a",
		"running",
		&current,
		"accepted",
		[]scalerSnapshot{{
			target:      targetSpec{key: "one", maximum: 5},
			targetSlots: 5,
		}},
		errors.New("controller update failed"),
		time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC),
	)
	if state.DesiredSlots != state.Autoscaling.TargetSlots {
		t.Fatalf(
			"desiredSlots %d did not equal targetSlots %d",
			state.DesiredSlots,
			state.Autoscaling.TargetSlots,
		)
	}
	if state.Autoscaling.TargetSlots > state.Autoscaling.MaximumSlots ||
		state.ConfiguredSlots != 5 ||
		state.Autoscaling.MaximumSlots != 5 {
		t.Fatalf("degraded capacity projection was incoherent: %#v", state)
	}
	if state.Autoscaling.Status != "degraded" ||
		state.Autoscaling.LastError == nil {
		t.Fatalf("controller failure was not surfaced: %#v", state.Autoscaling)
	}
}

func TestObservedRecoveredRunnerUsesSafeActivity(t *testing.T) {
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	state := buildObservedState(
		config{profileID: "profile-a", scope: "repo"},
		"instance-a",
		"running",
		nil,
		"waiting",
		[]scalerSnapshot{{
			target: targetSpec{key: "repo-a"},
			runners: []runnerRecord{{
				key:       "repo-a-1",
				targetKey: "repo-a",
				state:     runnerStarting,
				startedAt: now,
				updatedAt: now,
				recovered: true,
				protected: true,
			}},
		}},
		nil,
		now,
	)
	if state.Slots[0].State != "starting" ||
		state.Slots[0].Activity != "unknown" ||
		!state.Slots[0].ProcessRunning {
		t.Fatalf("recovered runner was projected unsafely: %#v", state.Slots[0])
	}
}

func TestStoppedManagerUsesSchemaCompatibleAutoscalingStatus(t *testing.T) {
	if status := autoscalingStatus("stopped", nil); status != "stopping" {
		t.Fatalf("expected stopped manager to retain stopping autoscaling status, got %q", status)
	}
}
