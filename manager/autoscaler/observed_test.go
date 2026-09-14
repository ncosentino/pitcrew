package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/actions/scaleset"
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
	currentJob := jobContextFromStarted(&scaleset.JobStarted{
		RunnerID:   2,
		RunnerName: "runner-two",
		JobMessageBase: scaleset.JobMessageBase{
			RepositoryName: "project-b",
			OwnerName:      "example-org",
			JobID:          "123456789",
			JobWorkflowRef: "workflow-ref-not-published",
			JobDisplayName: "Large integration build",
			WorkflowRunID:  987654321,
			RequestLabels:  []string{"request-label-not-published"},
		},
	}, now.Add(-30*time.Second))
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
				key:              "scope-1",
				targetKey:        "scope",
				runnerName:       "runner-one",
				runnerID:         1,
				containerID:      "container-one",
				containerRunning: true,
				state:            runnerIdle,
				startedAt:        now.Add(-2 * time.Minute),
				updatedAt:        now,
				idleSince:        &idleSince,
			},
			{
				key:              "scope-2",
				targetKey:        "scope",
				runnerName:       "runner-two",
				runnerID:         2,
				containerID:      "container-two",
				containerRunning: true,
				state:            runnerBusy,
				startedAt:        now.Add(-time.Minute),
				updatedAt:        now,
				currentJob:       currentJob,
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
		runnerImage:    "example/runner:1.0",
		workerImageID:  "sha256:1111111111111111111111111111111111111111111111111111111111111111",
		workerRevision: testWorkerRevision,
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
	if state.ManagerContractVersion != managerContractVersion || state.DesiredSlots != 3 ||
		state.ConfiguredSlots != 4 || state.ActiveSlots != 3 ||
		state.EligibleSlots != 2 || state.DrainingSlots != 1 {
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
	if state.Update.Status != "current" ||
		state.Update.TargetImage != cfg.runnerImage ||
		state.Update.TargetImageID == nil ||
		*state.Update.TargetImageID != cfg.workerImageID ||
		state.Update.TargetRevision != testWorkerRevision ||
		state.Update.CurrentWorkers != 3 ||
		state.Update.StaleWorkers != 0 {
		t.Fatalf("unexpected update projection: %#v", state.Update)
	}
	if state.ResourceTelemetry.Status != "unavailable" ||
		state.ResourceTelemetry.Host != nil ||
		state.ResourceTelemetry.HostPressure.Status != "unavailable" ||
		state.ResourceTelemetry.HostPressure.Source != "docker-host" ||
		state.ResourceTelemetry.Manager != nil {
		t.Fatalf("resource telemetry fabricated usage: %#v", state.ResourceTelemetry)
	}
	if state.Slots[0].Resources != nil ||
		state.Slots[0].RunnerNameHash == nil ||
		*state.Slots[0].RunnerNameHash !=
			"e0054523055d4ebd049b2b33a1f3b55ba66e5f194b1bbbe5a69eca1ac6a5bf41" ||
		state.Slots[0].Activity == "" ||
		state.Slots[0].Target != "scope" ||
		state.Slots[0].RegistrationStatus != "connected" ||
		state.Slots[2].RegistrationStatus != "disconnected" {
		t.Fatalf("slot projection omitted autoscaling lifecycle data: %#v", state.Slots[0])
	}
	if state.Slots[0].CurrentJob != nil ||
		state.Slots[1].CurrentJob == nil ||
		state.Slots[1].CurrentJob.JobID != "123456789" ||
		state.Slots[2].CurrentJob != nil {
		t.Fatalf("slot projection omitted or fabricated job context: %#v", state.Slots)
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
	if bytes.Contains(data, []byte("runner-one")) ||
		bytes.Contains(data, []byte("runner-two")) ||
		bytes.Contains(data, []byte("runner-three")) ||
		bytes.Contains(data, []byte(`"runnerName"`)) ||
		bytes.Contains(data, []byte(`"containerId"`)) ||
		bytes.Contains(data, []byte(`"containerName"`)) ||
		bytes.Contains(data, []byte("workflow-ref-not-published")) ||
		bytes.Contains(data, []byte("request-label-not-published")) ||
		bytes.Contains(data, []byte(`"jobWorkflowRef"`)) ||
		bytes.Contains(data, []byte(`"requestLabels"`)) {
		t.Fatalf("observed state exposed raw runner or container identity: %s", data)
	}
	for _, field := range []string{
		"schemaVersion", "managerContractVersion", "profileId",
		"managerInstanceId", "managerStatus", "observedAt", "scope",
		"generation", "desiredStateHash", "desiredStateStatus",
		"desiredSlots", "activeSlots", "eligibleSlots", "drainingSlots", "configuredSlots",
		"slots", "resourceTelemetry", "autoscaling", "update", "sourceObservations",
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
	if _, exists := firstSlot["currentJob"]; !exists {
		t.Fatalf("slot projection omitted explicit job availability: %#v", firstSlot)
	}
}

func TestObservedStatePublishesSourceObservationProvenance(t *testing.T) {
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	statisticsObservedAt := now.Add(-statisticsStaleAfter - time.Minute)
	state := buildObservedState(
		config{
			profileID:      "profile-a",
			workerRevision: testWorkerRevision,
			scope:          "repo",
		},
		"instance-a",
		"running",
		nil,
		"waiting",
		[]scalerSnapshot{{
			target: targetSpec{key: "repo-a"},
			statistics: scalerStatistics{
				observedAt: statisticsObservedAt,
			},
		}},
		nil,
		now,
	)
	data, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	sources, ok := decoded["sourceObservations"].(map[string]any)
	if !ok {
		t.Fatalf("observed state omitted source observation provenance: %s", data)
	}
	assertSourceObservation := func(
		name string,
		coverage string,
		retention string,
		observedAt any,
		reason any,
	) {
		t.Helper()
		source, ok := sources[name].(map[string]any)
		if !ok {
			t.Fatalf("source observation %q is missing: %#v", name, sources)
		}
		if source["authority"] != "pitcrew-manager" ||
			source["sourceIdentity"] != "instance-a" ||
			source["coverage"] != coverage ||
			source["retention"] != retention ||
			source["observedAt"] != observedAt ||
			source["reason"] != reason {
			t.Fatalf("source observation %q has the wrong provenance: %#v", name, source)
		}
	}
	assertSourceObservation(
		"localRuntime",
		"complete",
		"live",
		now.Format(time.RFC3339),
		nil,
	)
	assertSourceObservation(
		"githubScaleSet",
		"complete",
		"last-known",
		statisticsObservedAt.Format(time.RFC3339),
		"stale",
	)
	assertSourceObservation(
		"workload",
		"complete",
		"last-known",
		statisticsObservedAt.Format(time.RFC3339),
		"stale",
	)
	assertSourceObservation(
		"resourceTelemetry",
		"unavailable",
		"live",
		nil,
		"source-unavailable",
	)
}

func TestObservedStateDistinguishesMeasuredZeroFromUnavailableSources(t *testing.T) {
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	measured := buildObservedState(
		config{
			profileID:      "profile-a",
			workerRevision: testWorkerRevision,
			scope:          "repo",
		},
		"instance-a",
		"running",
		nil,
		"waiting",
		[]scalerSnapshot{{
			target: targetSpec{key: "repo-a"},
			statistics: scalerStatistics{
				observedAt: now,
			},
		}},
		nil,
		now,
	)
	unavailable := buildObservedState(
		config{
			profileID:      "profile-a",
			workerRevision: testWorkerRevision,
			scope:          "repo",
		},
		"instance-a",
		"running",
		nil,
		"waiting",
		[]scalerSnapshot{{
			target: targetSpec{key: "repo-a"},
		}},
		nil,
		now,
	)
	if measured.SourceObservations.GitHubScaleSet.Coverage != "complete" ||
		measured.SourceObservations.GitHubScaleSet.ObservedAt == nil ||
		measured.Autoscaling.RunningJobs != 0 {
		t.Fatalf("measured zero was not preserved as complete evidence: %#v", measured)
	}
	if unavailable.SourceObservations.GitHubScaleSet.Coverage != "unavailable" ||
		unavailable.SourceObservations.GitHubScaleSet.ObservedAt != nil ||
		unavailable.SourceObservations.GitHubScaleSet.Reason == nil ||
		unavailable.Autoscaling.RunningJobs != 0 {
		t.Fatalf("unavailable evidence was not distinct from zero: %#v", unavailable)
	}
}

func TestObservedStateReportsPartialScaleSetCoverage(t *testing.T) {
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	state := buildObservedState(
		config{
			profileID:      "profile-a",
			workerRevision: testWorkerRevision,
			scope:          "repo",
		},
		"instance-a",
		"running",
		nil,
		"waiting",
		[]scalerSnapshot{
			{
				target: targetSpec{key: "repo-a"},
				statistics: scalerStatistics{
					observedAt: now.Add(-time.Minute),
				},
			},
			{
				target: targetSpec{key: "repo-b"},
			},
		},
		nil,
		now,
	)
	source := state.SourceObservations.GitHubScaleSet
	if source.Coverage != coveragePartial ||
		source.Retention != retentionLive ||
		source.ObservedAt == nil ||
		*source.ObservedAt != now.Add(-time.Minute).Format(time.RFC3339) ||
		source.Reason == nil ||
		*source.Reason != sourceReasonPartial {
		t.Fatalf("mixed target coverage was not reported as partial: %#v", source)
	}
	if state.SourceObservations.Workload.Coverage != coveragePartial {
		t.Fatalf(
			"workload coverage diverged from scale-set evidence: %#v",
			state.SourceObservations.Workload,
		)
	}
}

func TestObservedStateReportsPartialRetainedMixedFreshness(t *testing.T) {
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	oldest := now.Add(-statisticsStaleAfter - time.Minute)
	state := buildObservedState(
		config{
			profileID:      "profile-a",
			workerRevision: testWorkerRevision,
			scope:          "repo",
		},
		"instance-a",
		"running",
		nil,
		"waiting",
		[]scalerSnapshot{
			{
				target: targetSpec{key: "repo-stale"},
				statistics: scalerStatistics{
					observedAt: oldest,
				},
			},
			{
				target: targetSpec{key: "repo-current"},
				statistics: scalerStatistics{
					observedAt: now.Add(-time.Minute),
				},
			},
		},
		nil,
		now,
	)
	source := state.SourceObservations.GitHubScaleSet
	if source.Coverage != coveragePartial ||
		source.Retention != retentionLastKnown ||
		source.ObservedAt == nil ||
		*source.ObservedAt != oldest.Format(time.RFC3339) ||
		source.Reason == nil ||
		*source.Reason != sourceReasonPartial {
		t.Fatalf("mixed current and stale statistics had the wrong source aggregate: %#v", source)
	}
}

func TestCapacitySourceObservationAggregatesTargetEvidence(t *testing.T) {
	currentAt := "2026-07-20T11:59:00Z"
	staleAt := "2026-07-20T11:50:00Z"
	unavailableAt := "2026-07-20T12:00:00Z"
	cases := []struct {
		name      string
		targets   []targetCapacityDeficitEvidence
		observed  *string
		coverage  string
		retention string
		reason    string
	}{
		{
			name: "complete current",
			targets: []targetCapacityDeficitEvidence{
				{capacityDeficitCore: capacityDeficitCore{
					ObservedAt: currentAt,
					Freshness:  freshnessCurrent,
				}},
			},
			observed:  &currentAt,
			coverage:  coverageComplete,
			retention: retentionLive,
		},
		{
			name: "all unavailable",
			targets: []targetCapacityDeficitEvidence{
				{capacityDeficitCore: capacityDeficitCore{
					ObservedAt: unavailableAt,
					Freshness:  freshnessUnavailable,
				}},
			},
			coverage:  coverageUnavailable,
			retention: retentionLive,
			reason:    sourceReasonUnavailable,
		},
		{
			name: "mixed observed and unavailable",
			targets: []targetCapacityDeficitEvidence{
				{capacityDeficitCore: capacityDeficitCore{
					ObservedAt: currentAt,
					Freshness:  freshnessCurrent,
				}},
				{capacityDeficitCore: capacityDeficitCore{
					ObservedAt: unavailableAt,
					Freshness:  freshnessUnavailable,
				}},
			},
			observed:  &currentAt,
			coverage:  coveragePartial,
			retention: retentionLive,
			reason:    sourceReasonPartial,
		},
		{
			name: "all stale",
			targets: []targetCapacityDeficitEvidence{
				{capacityDeficitCore: capacityDeficitCore{
					ObservedAt: staleAt,
					Freshness:  freshnessStale,
				}},
			},
			observed:  &staleAt,
			coverage:  coverageComplete,
			retention: retentionLastKnown,
			reason:    sourceReasonStale,
		},
		{
			name: "mixed current and stale",
			targets: []targetCapacityDeficitEvidence{
				{capacityDeficitCore: capacityDeficitCore{
					ObservedAt: currentAt,
					Freshness:  freshnessCurrent,
				}},
				{capacityDeficitCore: capacityDeficitCore{
					ObservedAt: staleAt,
					Freshness:  freshnessStale,
				}},
			},
			observed:  &staleAt,
			coverage:  coveragePartial,
			retention: retentionLastKnown,
			reason:    sourceReasonPartial,
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			state := observedState{
				ManagerInstanceID: "instance-a",
				ObservedAt:        unavailableAt,
				CapacityEvidence: &managerCapacityEvidence{
					Targets: testCase.targets,
				},
			}
			source := capacitySourceObservation(state)
			observedAtMismatch :=
				(source.ObservedAt == nil) != (testCase.observed == nil)
			if source.ObservedAt != nil && testCase.observed != nil {
				observedAtMismatch = *source.ObservedAt != *testCase.observed
			}
			reason := ""
			if source.Reason != nil {
				reason = *source.Reason
			}
			if observedAtMismatch ||
				source.Coverage != testCase.coverage ||
				source.Retention != testCase.retention ||
				reason != testCase.reason {
				t.Fatalf("capacity aggregate mismatch: %#v", source)
			}
		})
	}
}

func TestSerializedFreshnessBoundaryMatchesManagerValidator(t *testing.T) {
	shell := os.Getenv("PITCREW_TEST_SHELL")
	useWSL := os.Getenv("PITCREW_TEST_WSL") == "1"
	if shell == "" && !useWSL {
		var err error
		shell, err = exec.LookPath("sh")
		if err != nil {
			t.Skip("a POSIX shell is required for the manager contract validator")
		}
	}
	validatorPath, err := filepath.Abs(filepath.Join("..", "observability.sh"))
	if err != nil {
		t.Fatal(err)
	}
	base := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		name        string
		sourceTime  time.Time
		publication time.Time
		freshness   string
		retention   string
		reason      *string
	}{
		{
			name:        "immediately below",
			sourceTime:  base.Add(500 * time.Microsecond),
			publication: base.Add(119*time.Second + 999500*time.Microsecond),
			freshness:   freshnessCurrent,
			retention:   retentionLive,
		},
		{
			name:        "exactly at",
			sourceTime:  base.Add(123 * time.Millisecond),
			publication: base.Add(120*time.Second + 123*time.Millisecond),
			freshness:   freshnessCurrent,
			retention:   retentionLive,
		},
		{
			name:        "immediately above",
			sourceTime:  base.Add(999500 * time.Microsecond),
			publication: base.Add(121*time.Second + 500*time.Microsecond),
			freshness:   freshnessStale,
			retention:   retentionLastKnown,
			reason:      stringPointer(sourceReasonStale),
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			publicationTime := serializedObservationTime(testCase.publication)
			snapshot := evidenceSnapshot(
				"repo-a",
				1,
				activeRunners(1, runnerIdle),
				scalerStatistics{
					observedAt:        testCase.sourceTime,
					registeredRunners: 1,
				},
			)
			state := buildObservedState(
				config{
					profileID:      "profile-a",
					workerRevision: testWorkerRevision,
					runnerImage:    "example/runner:1.0",
					scope:          "repo",
				},
				"instance-a",
				"running",
				nil,
				"waiting",
				[]scalerSnapshot{snapshot},
				nil,
				publicationTime,
			)
			health := healthyDiagnostics()
			capacity := buildCapacityEvidence(
				[]scalerSnapshot{snapshot},
				nil,
				health,
				publicationTime,
			)
			state.OperationJournal = &managerOperationJournal{
				Status:        "current",
				Capacity:      journalCapacity,
				DroppedEvents: 0,
				Events:        []managerEvent{},
			}
			state.SubsystemHealth = &health
			state.CapacityEvidence = &capacity
			state.HostAdmission = &observedHostAdmission{
				Status: hostAdmissionStatusDisabled,
			}
			refreshSourceObservations(
				&state,
				[]scalerSnapshot{snapshot},
				publicationTime,
			)
			if capacity.Targets[0].Freshness != testCase.freshness {
				t.Fatalf(
					"Go freshness at the serialized boundary was %q, expected %q",
					capacity.Targets[0].Freshness,
					testCase.freshness,
				)
			}
			source := state.SourceObservations.GitHubScaleSet
			if source.Retention != testCase.retention ||
				!equalOptionalString(source.Reason, testCase.reason) {
				t.Fatalf("unexpected source freshness aggregate: %#v", source)
			}
			document, err := json.Marshal(state)
			if err != nil {
				t.Fatal(err)
			}
			documentPath := filepath.Join(t.TempDir(), "observed-state.json")
			if err := os.WriteFile(documentPath, document, 0o600); err != nil {
				t.Fatal(err)
			}
			var command *exec.Cmd
			if useWSL {
				validatorCommand := ". " +
					strconv.Quote(wslTestPath(validatorPath)) +
					"; observed_state_is_valid " +
					strconv.Quote(wslTestPath(documentPath))
				command = exec.Command(
					"wsl",
					"bash",
					"-c",
					validatorCommand,
				)
			} else {
				command = exec.Command(
					shell,
					"-c",
					`. "$1"; observed_state_is_valid "$2"`,
					"pitcrew-validator",
					filepath.ToSlash(validatorPath),
					filepath.ToSlash(documentPath),
				)
			}
			if output, err := command.CombinedOutput(); err != nil {
				t.Fatalf(
					"manager validator contradicted Go freshness at %s: %v\n%s\n%s",
					testCase.name,
					err,
					output,
					document,
				)
			}
		})
	}
}

func wslTestPath(path string) string {
	if runtime.GOOS != "windows" {
		return filepath.ToSlash(path)
	}
	volume := filepath.VolumeName(path)
	relative := strings.TrimPrefix(path, volume)
	return "/mnt/" + strings.ToLower(strings.TrimSuffix(volume, ":")) +
		filepath.ToSlash(relative)
}

func equalOptionalString(left *string, right *string) bool {
	if left == nil || right == nil {
		return left == nil && right == nil
	}
	return *left == *right
}

func TestSourceObservationsMapPartialAndRetainedEvidence(t *testing.T) {
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	sampledAt := now.Add(-time.Minute).Format(time.RFC3339)
	hardwareObservedAt := now.Add(-time.Hour).Format(time.RFC3339)
	healthObservedAt := now.Add(-30 * time.Second).Format(time.RFC3339)
	capacityObservedAt := now.Add(-15 * time.Second).Format(time.RFC3339)
	state := observedState{
		ManagerInstanceID: "instance-a",
		ManagerStatus:     "running",
		ObservedAt:        now.Format(time.RFC3339),
		Slots: []observedSlot{{
			Activity: "unknown",
		}},
		ResourceTelemetry: resourceTelemetry{
			SampledAt: sampledAt,
			Status:    "partial",
		},
		Host: observedHost{
			Hardware: hostHardwareInventory{
				Status:      "stale",
				CollectedAt: &hardwareObservedAt,
			},
		},
		HostAdmission: &observedHostAdmission{
			Status: hostAdmissionStatusDegraded,
		},
		SubsystemHealth: &managerSubsystemHealth{
			Docker: subsystemHealthSummary{
				State:      subsystemHealthy,
				ObservedAt: healthObservedAt,
			},
			GitHub: subsystemHealthSummary{
				State: subsystemUnknown,
			},
		},
		CapacityEvidence: &managerCapacityEvidence{
			Fixed: &capacityDeficitCore{
				ObservedAt: capacityObservedAt,
				Freshness:  freshnessUnavailable,
			},
		},
	}
	refreshSourceObservations(&state, nil, now)
	cases := map[string]struct {
		source    sourceObservation
		coverage  string
		retention string
		observed  *string
		reason    string
	}{
		"local runtime": {
			source:    state.SourceObservations.LocalRuntime,
			coverage:  coveragePartial,
			retention: retentionLive,
			observed:  &state.ObservedAt,
			reason:    sourceReasonPartial,
		},
		"resource telemetry": {
			source:    state.SourceObservations.ResourceTelemetry,
			coverage:  coveragePartial,
			retention: retentionLive,
			observed:  &sampledAt,
			reason:    sourceReasonPartial,
		},
		"host hardware": {
			source:    state.SourceObservations.HostHardware,
			coverage:  coverageComplete,
			retention: retentionLastKnown,
			observed:  &hardwareObservedAt,
			reason:    sourceReasonStale,
		},
		"host admission": {
			source:    state.SourceObservations.HostAdmission,
			coverage:  coveragePartial,
			retention: retentionLive,
			observed:  &state.ObservedAt,
			reason:    sourceReasonPartial,
		},
		"subsystem health": {
			source:    state.SourceObservations.SubsystemHealth,
			coverage:  coveragePartial,
			retention: retentionLive,
			observed:  &healthObservedAt,
			reason:    sourceReasonPartial,
		},
		"capacity": {
			source:    state.SourceObservations.Capacity,
			coverage:  coverageUnavailable,
			retention: retentionLive,
			observed:  nil,
			reason:    sourceReasonUnavailable,
		},
	}
	for name, testCase := range cases {
		source := testCase.source
		observedAtMismatch :=
			(source.ObservedAt == nil) != (testCase.observed == nil)
		if source.ObservedAt != nil && testCase.observed != nil {
			observedAtMismatch = *source.ObservedAt != *testCase.observed
		}
		if source.Coverage != testCase.coverage ||
			source.Retention != testCase.retention ||
			observedAtMismatch ||
			source.Reason == nil ||
			*source.Reason != testCase.reason {
			t.Fatalf("%s provenance mismatch: %#v", name, source)
		}
	}
	if state.SourceObservations.GitHubScaleSet.Coverage != coverageUnavailable ||
		state.SourceObservations.GitHubScaleSet.Reason == nil ||
		*state.SourceObservations.GitHubScaleSet.Reason != sourceReasonNotObserved {
		t.Fatalf(
			"missing scale-set evidence was not unavailable: %#v",
			state.SourceObservations.GitHubScaleSet,
		)
	}
}

func TestStoppedManagerRetainsResourceSampleWithoutRefreshingIt(t *testing.T) {
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	sampledAt := now.Add(-time.Minute).Format(time.RFC3339)
	state := observedState{
		ManagerInstanceID: "instance-a",
		ManagerStatus:     "stopped",
		ObservedAt:        now.Format(time.RFC3339),
		ResourceTelemetry: resourceTelemetry{
			SampledAt: sampledAt,
			Status:    "available",
		},
	}
	source := resourceTelemetrySourceObservation(state)
	if source.Coverage != coverageComplete ||
		source.Retention != retentionLastKnown ||
		source.ObservedAt == nil ||
		*source.ObservedAt != sampledAt ||
		source.Reason == nil ||
		*source.Reason != sourceReasonStale {
		t.Fatalf("stopped manager refreshed retained telemetry: %#v", source)
	}
}

func TestHashRunnerNameUsesExactLowercaseSHA256(t *testing.T) {
	hash := hashRunnerName("runner-one")
	if hash == nil ||
		*hash != "e0054523055d4ebd049b2b33a1f3b55ba66e5f194b1bbbe5a69eca1ac6a5bf41" {
		t.Fatalf("unexpected runner-name hash: %v", hash)
	}
	if hashRunnerName("") != nil {
		t.Fatal("empty runner name produced a correlation hash")
	}
}

func TestCleanupSlotOmitsRunnerNameHash(t *testing.T) {
	slot := observedCleanupSlot(
		registrationCleanupRecord{
			SlotKey:    "scope-1",
			RunnerName: "runner-one",
		},
		scalerSnapshot{target: targetSpec{key: "scope"}},
	)
	if slot.ProcessRunning || slot.RunnerNameHash != nil {
		t.Fatalf("non-running cleanup slot retained live identity: %#v", slot)
	}
}

func TestObservedRunnerDoesNotInferProcessFromRetainedRecord(t *testing.T) {
	slot := observedRunnerSlot(
		runnerRecord{
			key:              "scope-1",
			targetKey:        "scope",
			containerID:      "container-one",
			containerRunning: false,
			state:            runnerDraining,
			updatedAt:        time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC),
		},
		false,
		"",
	)
	if slot.ProcessRunning {
		t.Fatalf("retained runner record was reported as a running container: %#v", slot)
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
			workerRevision: testWorkerRevision,
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
			workerRevision: testWorkerRevision,
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
		config{
			profileID:      "profile-a",
			workerRevision: testWorkerRevision,
			scope:          "repo",
		},
		"instance-a",
		"running",
		nil,
		"waiting",
		[]scalerSnapshot{{
			target: targetSpec{key: "repo-a"},
			runners: []runnerRecord{{
				key:              "repo-a-1",
				targetKey:        "repo-a",
				containerRunning: true,
				state:            runnerStarting,
				startedAt:        now,
				updatedAt:        now,
				recovered:        true,
				protected:        true,
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
