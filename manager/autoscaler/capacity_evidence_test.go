package main

import (
	"testing"
	"time"
)

func evidenceSnapshot(
	key string,
	targetSlots int,
	runners []runnerRecord,
	statistics scalerStatistics,
) scalerSnapshot {
	snapshot := scalerSnapshot{
		target: targetSpec{
			key:        key,
			repository: "https://github.com/example/" + key,
			maximum:    8,
		},
		targetSlots: targetSlots,
		statistics:  statistics,
		runners:     runners,
	}
	for _, runner := range runners {
		switch runner.state {
		case runnerDraining, runnerCleanupPending:
			snapshot.drainingRunners++
		case runnerIdle:
			snapshot.idleRunners++
			snapshot.activeRunners++
		case runnerBusy:
			snapshot.busyRunners++
			snapshot.activeRunners++
		default:
			snapshot.activeRunners++
		}
	}
	return snapshot
}

func activeRunners(count int, state runnerLifecycleState) []runnerRecord {
	runners := make([]runnerRecord, 0, count)
	for index := 0; index < count; index++ {
		runners = append(runners, runnerRecord{
			key:   "slot",
			state: state,
		})
	}
	return runners
}

func healthyDiagnostics() managerSubsystemHealth {
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	evidence := &subsystemOperationEvidence{
		Operation:  operationDockerRun,
		ObservedAt: now.Format(time.RFC3339),
		Reason:     reasonNone,
	}
	summary := subsystemHealthSummary{
		State:       subsystemHealthy,
		ObservedAt:  now.Format(time.RFC3339),
		LastSuccess: evidence,
	}
	return managerSubsystemHealth{Docker: summary, GitHub: summary}
}

// TestCapacityEvidenceSeparatesLocalAndRegisteredEvidence proves local Docker
// counts and GitHub registered evidence stay independent in both directions.
func TestCapacityEvidenceSeparatesLocalAndRegisteredEvidence(t *testing.T) {
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	cases := map[string]struct {
		registered          int
		expectedEligibility int
	}{
		"two local zero registered":  {registered: 0, expectedEligibility: 2},
		"two local eight registered": {registered: 8, expectedEligibility: 0},
	}
	for name, testCase := range cases {
		snapshot := evidenceSnapshot(
			"repo-one",
			2,
			activeRunners(2, runnerIdle),
			scalerStatistics{
				observedAt:        now,
				registeredRunners: testCase.registered,
			},
		)
		evidence := buildCapacityEvidence(
			[]scalerSnapshot{snapshot},
			nil,
			healthyDiagnostics(),
			now,
		)
		if evidence.Fixed != nil || len(evidence.Targets) != 1 {
			t.Fatalf("%s produced the wrong shape: %#v", name, evidence)
		}
		target := evidence.Targets[0]
		if target.LocalDeficit != 0 || target.Reason != deficitNone {
			t.Fatalf("%s reported a local deficit: %#v", name, target)
		}
		if target.EligibleWorkers == nil ||
			*target.EligibleWorkers != testCase.registered {
			t.Fatalf("%s lost registered evidence: %#v", name, target)
		}
		if target.EligibilityDeficit == nil ||
			*target.EligibilityDeficit != testCase.expectedEligibility {
			t.Fatalf("%s computed the wrong eligibility deficit: %#v", name, target)
		}
		if target.ActiveWorkers != 2 || target.TargetSlots != 2 {
			t.Fatalf("%s lost local capacity evidence: %#v", name, target)
		}
	}
}

// TestCapacityEvidenceNeverTargetsConfiguredMaximum proves the configured
// autoscaling maximum is never presented as an unmet health target.
func TestCapacityEvidenceNeverTargetsConfiguredMaximum(t *testing.T) {
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	snapshot := evidenceSnapshot(
		"repo-one",
		0,
		nil,
		scalerStatistics{observedAt: now},
	)
	evidence := buildCapacityEvidence(
		[]scalerSnapshot{snapshot},
		nil,
		healthyDiagnostics(),
		now,
	)
	target := evidence.Targets[0]
	if target.TargetSlots != 0 ||
		target.LocalDeficit != 0 ||
		target.Reason != deficitNone {
		t.Fatalf("zero demand created a deficit against the maximum: %#v", target)
	}
}

// TestCapacityEvidenceMarksStaleAndUnavailableStatistics proves statistics
// freshness is published rather than assumed.
func TestCapacityEvidenceMarksStaleAndUnavailableStatistics(t *testing.T) {
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	stale := evidenceSnapshot(
		"repo-stale",
		2,
		activeRunners(2, runnerIdle),
		scalerStatistics{
			observedAt:        now.Add(-statisticsStaleAfter - time.Minute),
			registeredRunners: 1,
		},
	)
	unavailable := evidenceSnapshot("repo-new", 1, nil, scalerStatistics{})
	evidence := buildCapacityEvidence(
		[]scalerSnapshot{stale, unavailable},
		nil,
		healthyDiagnostics(),
		now,
	)
	if evidence.Targets[0].Freshness != freshnessStale ||
		evidence.Targets[0].EligibleWorkers == nil {
		t.Fatalf("stale statistics were not published: %#v", evidence.Targets[0])
	}
	fresh := evidence.Targets[1]
	if fresh.Freshness != freshnessUnavailable ||
		fresh.EligibleWorkers != nil ||
		fresh.EligibilityDeficit != nil ||
		fresh.Reason != deficitUnknown {
		t.Fatalf("unobserved statistics were fabricated: %#v", fresh)
	}
}

// TestCapacityEvidenceReportsManagerBlockingReason proves the published reason
// is the manager's own blocking reason for each condition.
func TestCapacityEvidenceReportsManagerBlockingReason(t *testing.T) {
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	statistics := scalerStatistics{observedAt: now, registeredRunners: 1}
	cases := map[string]struct {
		mutate    func(*scalerSnapshot)
		condition targetCapacityCondition
		expected  string
	}{
		"admission ceiling": {
			mutate: func(snapshot *scalerSnapshot) {
				snapshot.blocking = capacityBlock{
					reason:   deficitAdmissionCeiling,
					evidence: "profile active-worker ceiling deferred requested capacity",
				}
			},
			expected: deficitAdmissionCeiling,
		},
		"jit failed": {
			mutate: func(snapshot *scalerSnapshot) {
				snapshot.blocking = capacityBlock{reason: deficitJITFailed}
			},
			expected: deficitJITFailed,
		},
		"docker failed": {
			mutate: func(snapshot *scalerSnapshot) {
				snapshot.blocking = capacityBlock{reason: deficitDockerFailed}
			},
			expected: deficitDockerFailed,
		},
		"cleanup backlog": {
			mutate: func(snapshot *scalerSnapshot) {
				snapshot.pendingCleanups = []registrationCleanupRecord{{
					SlotKey:  "repo-one-9",
					RunnerID: 9,
				}}
			},
			expected: deficitCleanupPending,
		},
		"listener unavailable": {
			condition: targetCapacityCondition{listenerStopped: true},
			expected:  deficitListenerUnavailable,
		},
		"session unavailable": {
			condition: targetCapacityCondition{sessionMissing: true},
			expected:  deficitSessionUnavailable,
		},
		"retry backoff": {
			condition: targetCapacityCondition{restartPending: true},
			expected:  deficitRetryBackoff,
		},
		"invalid desired state": {
			condition: targetCapacityCondition{desiredStatus: "invalid"},
			expected:  deficitInvalidDesiredState,
		},
		"draining target": {
			mutate: func(snapshot *scalerSnapshot) {
				snapshot.retiring = true
			},
			expected: deficitWorkerDraining,
		},
		"launch pending": {
			mutate: func(snapshot *scalerSnapshot) {
				snapshot.runners = activeRunners(1, runnerStarting)
				snapshot.activeRunners = 1
			},
			expected: deficitLaunchPending,
		},
	}
	for name, testCase := range cases {
		snapshot := evidenceSnapshot("repo-one", 2, nil, statistics)
		if testCase.mutate != nil {
			testCase.mutate(&snapshot)
		}
		evidence := buildCapacityEvidence(
			[]scalerSnapshot{snapshot},
			map[string]targetCapacityCondition{"repo-one": testCase.condition},
			healthyDiagnostics(),
			now,
		)
		target := evidence.Targets[0]
		if target.LocalDeficit == 0 {
			t.Fatalf("%s did not report a deficit: %#v", name, target)
		}
		if target.Reason != testCase.expected {
			t.Fatalf("%s reported reason %q", name, target.Reason)
		}
	}
}

// TestCapacityEvidenceReportsDockerHealthWhenUnexplained proves an unexplained
// deficit falls back to the manager's own Docker evidence.
func TestCapacityEvidenceReportsDockerHealthWhenUnexplained(t *testing.T) {
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	health := healthyDiagnostics()
	health.Docker.State = subsystemUnavailable
	health.Docker.ConsecutiveFailures = subsystemFailureBand
	snapshot := evidenceSnapshot(
		"repo-one",
		2,
		nil,
		scalerStatistics{observedAt: now},
	)
	evidence := buildCapacityEvidence(
		[]scalerSnapshot{snapshot},
		nil,
		health,
		now,
	)
	if evidence.Targets[0].Reason != deficitDockerUnavailable {
		t.Fatalf("unexplained deficit ignored Docker health: %#v", evidence.Targets[0])
	}
}

// TestCapacityEvidenceKeepsSimultaneousTargetsIndependent proves one blocked
// target never distorts another target's evidence.
func TestCapacityEvidenceKeepsSimultaneousTargetsIndependent(t *testing.T) {
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	statistics := scalerStatistics{observedAt: now, registeredRunners: 2}
	satisfied := evidenceSnapshot(
		"repo-one",
		2,
		activeRunners(2, runnerBusy),
		statistics,
	)
	blocked := evidenceSnapshot("repo-two", 3, nil, statistics)
	blocked.blocking = capacityBlock{reason: deficitAdmissionCeiling}
	evidence := buildCapacityEvidence(
		[]scalerSnapshot{satisfied, blocked},
		nil,
		healthyDiagnostics(),
		now,
	)
	if evidence.Targets[0].Reason != deficitNone ||
		evidence.Targets[0].LocalDeficit != 0 {
		t.Fatalf("satisfied target inherited a deficit: %#v", evidence.Targets[0])
	}
	if evidence.Targets[1].Reason != deficitAdmissionCeiling ||
		evidence.Targets[1].LocalDeficit != 3 {
		t.Fatalf("blocked target lost its own evidence: %#v", evidence.Targets[1])
	}
	if evidence.Targets[0].Key != "repo-one" || evidence.Targets[1].Key != "repo-two" {
		t.Fatalf("target identity was not preserved: %#v", evidence.Targets)
	}
}

// TestCapacityEvidenceCountsDrainingAndCleanupWorkersSeparately proves busy and
// draining workers are never counted as replaceable capacity.
func TestCapacityEvidenceCountsDrainingAndCleanupWorkersSeparately(t *testing.T) {
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	snapshot := evidenceSnapshot(
		"repo-one",
		2,
		[]runnerRecord{
			{key: "repo-one-1", state: runnerBusy},
			{key: "repo-one-2", state: runnerDraining},
			{key: "repo-one-3", state: runnerCleanupPending},
		},
		scalerStatistics{observedAt: now, registeredRunners: 3},
	)
	snapshot.pendingCleanups = []registrationCleanupRecord{{
		SlotKey:  "repo-one-4",
		RunnerID: 4,
	}}
	evidence := buildCapacityEvidence(
		[]scalerSnapshot{snapshot},
		nil,
		healthyDiagnostics(),
		now,
	)
	target := evidence.Targets[0]
	if target.ActiveWorkers != 1 ||
		target.DrainingWorkers != 1 ||
		target.CleanupPendingWorkers != 2 {
		t.Fatalf("worker states were conflated: %#v", target)
	}
	if target.LocalDeficit != 1 || target.Reason != deficitCleanupPending {
		t.Fatalf("cleanup backlog was not reported: %#v", target)
	}
}
