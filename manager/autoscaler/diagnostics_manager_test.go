package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestObservedStatePublishesContractTwelveDiagnostics proves the manager
// publishes durable operation evidence, subsystem health, and per-target
// capacity evidence alongside the existing projection.
func TestObservedStatePublishesContractTwelveDiagnostics(t *testing.T) {
	directory := projectTestDirectory(t)
	cfg := managerTestConfig(directory)
	clock := &fakeClock{current: time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)}
	manager := newAutoscalerManager(
		cfg,
		newFakeScaleSetServiceFactory(),
		newFakeDockerClient(nil),
		clock,
		testLogger(),
		"instance-one",
	)
	manager.diagnostics.record(diagnosticsObservation{
		subsystem:  subsystemListener,
		operation:  operationMessagePoll,
		target:     "repo-one",
		outcome:    outcomeFailed,
		reason:     reasonTimeout,
		evidence:   "scale-set listener stopped for this target",
		healthKind: healthGitHub,
	})
	if err := manager.publishObserved(); err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(manager.paths.observed)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{
		"operationJournal", "subsystemHealth", "capacityEvidence",
	} {
		if _, exists := decoded[field]; !exists {
			t.Fatalf("observed state omitted contract-12 field %q", field)
		}
	}
	if version, _ := decoded["managerContractVersion"].(float64); int(version) != managerContractVersion {
		t.Fatalf("diagnostics changed the active manager contract: %v", decoded["managerContractVersion"])
	}
	journal := decoded["operationJournal"].(map[string]any)
	if journal["status"] != journalStatusCurrent {
		t.Fatalf("unexpected journal status: %#v", journal)
	}
	events := journal["events"].([]any)
	published := false
	for _, entry := range events {
		event := entry.(map[string]any)
		if event["operation"] == operationMessagePoll &&
			event["outcome"] == outcomeFailed &&
			event["reason"] == reasonTimeout &&
			event["target"] == "repo-one" {
			published = true
		}
	}
	if !published {
		t.Fatalf("journal did not publish the listener failure: %#v", journal)
	}
	health := decoded["subsystemHealth"].(map[string]any)
	github := health["github"].(map[string]any)
	if github["state"] != subsystemDegraded {
		t.Fatalf("GitHub health was not published: %#v", github)
	}
	docker := health["docker"].(map[string]any)
	if docker["state"] != subsystemUnknown {
		t.Fatalf("unobserved Docker health was fabricated: %#v", docker)
	}
	capacity := decoded["capacityEvidence"].(map[string]any)
	if capacity["fixed"] != nil {
		t.Fatalf("autoscaled profile published fixed capacity evidence: %#v", capacity)
	}
}

// TestManagerRestartRetainsPrecedingFailures proves a restart keeps listener and
// Docker failures that preceded recovery.
func TestManagerRestartRetainsPrecedingFailures(t *testing.T) {
	directory := projectTestDirectory(t)
	cfg := managerTestConfig(directory)
	clock := &fakeClock{current: time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)}
	manager := newAutoscalerManager(
		cfg,
		newFakeScaleSetServiceFactory(),
		newFakeDockerClient(nil),
		clock,
		testLogger(),
		"instance-one",
	)
	manager.diagnostics.record(diagnosticsObservation{
		subsystem:  subsystemDocker,
		operation:  operationDockerRun,
		outcome:    outcomeFailed,
		reason:     reasonDockerFailed,
		evidence:   "worker container launch failed",
		healthKind: healthDocker,
	})

	restarted := newAutoscalerManager(
		cfg,
		newFakeScaleSetServiceFactory(),
		newFakeDockerClient(nil),
		clock,
		testLogger(),
		"instance-two",
	)
	restarted.diagnostics.restore()
	journal := restarted.diagnostics.journal()
	if len(journal.Events) < 1 || journal.Events[0].Operation != operationDockerRun {
		t.Fatalf("restart lost the preceding Docker failure: %#v", journal)
	}
	if journal.Events[0].ManagerInstanceID != "instance-one" {
		t.Fatalf("restart rewrote the observer identity: %#v", journal.Events[0])
	}
}

// TestCorruptJournalPreservesAcceptedCapacity proves corrupt diagnostic state
// cannot destroy accepted desired capacity or retirement state.
func TestCorruptJournalPreservesAcceptedCapacity(t *testing.T) {
	directory := projectTestDirectory(t)
	cfg := managerTestConfig(directory)
	clock := &fakeClock{current: time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)}
	accepted := `{
	  "schemaVersion":1,
	  "generation":4,
	  "scope":"repo",
	  "repositories":[{"url":"https://github.com/example/one","workers":2}],
	  "replicas":null
	}`
	if err := os.WriteFile(
		filepath.Join(directory, "last-valid-capacity.json"),
		[]byte(accepted),
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(directory, diagnosticsJournalFileName),
		[]byte("{corrupt"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	manager := newAutoscalerManager(
		cfg,
		newFakeScaleSetServiceFactory(),
		newFakeDockerClient(nil),
		clock,
		testLogger(),
		"instance-one",
	)
	manager.diagnostics.restore()
	if err := manager.restoreLastValid(); err != nil {
		t.Fatalf("corrupt journal blocked capacity restore: %v", err)
	}
	if manager.current == nil || manager.current.state.Generation != 4 {
		t.Fatalf("corrupt journal destroyed accepted capacity: %#v", manager.current)
	}
	if status := manager.diagnostics.journal().Status; status != journalStatusUnavailable {
		t.Fatalf("corrupt journal was not reported: %q", status)
	}
	if err := manager.publishObserved(); err != nil {
		t.Fatalf("corrupt journal blocked observed-state publication: %v", err)
	}
}

// TestJournalPersistenceFailureKeepsPoolRunning proves a diagnostics write
// failure never stops the manager from publishing or scaling.
func TestJournalPersistenceFailureKeepsPoolRunning(t *testing.T) {
	scaler, _, _, _, cancel := newTestScalerInDirectory(
		t,
		1,
		0,
		0,
		projectTestDirectory(t),
	)
	defer cancel()
	scaler.diagnostics.write = func(string, []byte, os.FileMode) error {
		return errors.New("journal directory is read only")
	}
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatalf("journal persistence failure blocked scaling: %v", err)
	}
	if count := len(scaler.snapshot().runners); count != 1 {
		t.Fatalf("expected one live worker, got %d", count)
	}
	if !scaler.diagnostics.persistenceDegraded() {
		t.Fatal("journal persistence failure was not recorded")
	}
}

// TestWorkerLaunchFailureJournalsBlockingReason proves a failed launch records
// evidence and the blocking reason without leaving a phantom worker.
func TestWorkerLaunchFailureJournalsBlockingReason(t *testing.T) {
	scaler, api, docker, _, cancel := newTestScaler(t, 1, 0, 0)
	defer cancel()
	docker.runErrors = []error{errors.New("docker run failed")}
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err == nil {
		t.Fatal("expected the launch failure to surface")
	}
	snapshot := scaler.snapshot()
	if len(snapshot.runners) != 0 {
		t.Fatalf("failed launch left a phantom worker: %#v", snapshot.runners)
	}
	if snapshot.blocking.reason != deficitDockerFailed {
		t.Fatalf("failed launch did not record its blocking reason: %#v", snapshot.blocking)
	}
	if len(api.removeCalls) != 1 {
		t.Fatalf("failed launch did not fence its registration: %#v", api.removeCalls)
	}
	journal := scaler.diagnostics.journal()
	if len(journal.Events) == 0 {
		t.Fatal("failed launch was not journaled")
	}
	last := journal.Events[len(journal.Events)-1]
	if last.Operation != operationWorkerLaunch || last.Outcome != outcomeFailed {
		t.Fatalf("unexpected launch event: %#v", last)
	}
}

// TestJITFailureJournalsPendingConfiguration proves a JIT generation failure is
// reported as the target's blocking reason.
func TestJITFailureJournalsPendingConfiguration(t *testing.T) {
	scaler, api, _, _, cancel := newTestScaler(t, 1, 0, 0)
	defer cancel()
	api.generateErrors = []error{errors.New("scale set rejected the request")}
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err == nil {
		t.Fatal("expected the JIT failure to surface")
	}
	snapshot := scaler.snapshot()
	if snapshot.blocking.reason != deficitJITFailed {
		t.Fatalf("JIT failure did not record its blocking reason: %#v", snapshot.blocking)
	}
	journal := scaler.diagnostics.journal()
	last := journal.Events[len(journal.Events)-1]
	if last.Operation != operationWorkerLaunch || last.Outcome != outcomeFailed {
		t.Fatalf("JIT failure was not journaled: %#v", last)
	}
}

// TestAdmissionCeilingJournalsBlockedCapacity proves the profile-wide ceiling
// publishes a blocked admission rather than silently withholding capacity.
func TestAdmissionCeilingJournalsBlockedCapacity(t *testing.T) {
	scaler, _, _, _, cancel := newTestScaler(t, 4, 0, 0)
	defer cancel()
	scaler.admission = newAdmissionController(1)
	scaler.admission.join(scaler.target.key, scaler.runnerCount)
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 3); err != nil {
		t.Fatal(err)
	}
	snapshot := scaler.snapshot()
	if len(snapshot.runners) != 1 {
		t.Fatalf("admission ceiling was not enforced: %d workers", len(snapshot.runners))
	}
	if snapshot.blocking.reason != deficitAdmissionCeiling {
		t.Fatalf("admission ceiling was not published: %#v", snapshot.blocking)
	}
	journal := scaler.diagnostics.journal()
	blocked := false
	for _, event := range journal.Events {
		if event.Operation == operationAdmissionReserve &&
			event.Outcome == outcomeBlocked &&
			event.Reason == reasonCapacityCeiling {
			blocked = true
		}
	}
	if !blocked {
		t.Fatalf("blocked admission was not journaled: %#v", journal.Events)
	}
}

// TestRegistrationCleanupBacklogJournalsRetry proves a failed exact removal is
// published as pending cleanup with a retry time.
func TestRegistrationCleanupBacklogJournalsRetry(t *testing.T) {
	scaler, api, docker, _, cancel := newTestScaler(t, 1, 0, 0)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	runner := findRunner(t, scaler)
	api.removeErrors[runner.runnerID] = errors.New("registration removal rejected")
	docker.mu.Lock()
	docker.running[runner.containerID] = false
	docker.mu.Unlock()
	scaler.handleContainerExit(runner.containerID, exitStatus(1))

	if count := scaler.pendingRegistrationCount(); count != 1 {
		t.Fatalf("expected one pending cleanup record, got %d", count)
	}
	journal := scaler.diagnostics.journal()
	retried := false
	exited := false
	for _, event := range journal.Events {
		if event.Operation == operationRegistrationCleanup &&
			event.Outcome == outcomeRetry &&
			event.RetryAt != nil {
			retried = true
		}
		if event.Operation == operationWorkerExit {
			exited = true
		}
	}
	if !retried || !exited {
		t.Fatalf("cleanup backlog evidence was incomplete: %#v", journal.Events)
	}
}
