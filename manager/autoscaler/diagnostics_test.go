package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func newTestRecorder(t *testing.T) (*diagnosticsRecorder, string, *fakeClock) {
	t.Helper()
	directory := projectTestDirectory(t)
	clock := &fakeClock{current: time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)}
	return newDiagnosticsRecorder(directory, "instance-one", clock), directory, clock
}

func failureObservation(operation string, reason string) diagnosticsObservation {
	return diagnosticsObservation{
		subsystem:  subsystemDocker,
		operation:  operation,
		outcome:    outcomeFailed,
		reason:     reason,
		evidence:   "a Docker operation failed",
		healthKind: healthDocker,
	}
}

// TestJournalRetainsFailuresAndSkipsRoutineSuccess proves the journal keeps
// operational failures without recording every successful poll.
func TestJournalRetainsFailuresAndSkipsRoutineSuccess(t *testing.T) {
	recorder, _, _ := newTestRecorder(t)
	recorder.record(diagnosticsObservation{
		subsystem:  subsystemListener,
		operation:  operationMessagePoll,
		outcome:    outcomeSucceeded,
		reason:     reasonNone,
		healthKind: healthGitHub,
	})
	recorder.record(failureObservation(operationDockerRun, reasonDockerFailed))

	journal := recorder.journal()
	if journal.Status != journalStatusCurrent || len(journal.Events) != 1 {
		t.Fatalf("unexpected journal projection: %#v", journal)
	}
	event := journal.Events[0]
	if event.Operation != operationDockerRun ||
		event.Outcome != outcomeFailed ||
		event.Reason != reasonDockerFailed ||
		event.Sequence != 1 ||
		event.ManagerInstanceID != "instance-one" ||
		event.FirstObservedAt != event.ObservedAt ||
		event.LastObservedAt != event.ObservedAt ||
		event.OccurrenceCount != 1 {
		t.Fatalf("journal lost failure evidence: %#v", event)
	}
	if journal.HighestSequence == nil || *journal.HighestSequence != 1 {
		t.Fatalf("journal did not publish a durable sequence: %#v", journal)
	}
	health := recorder.subsystemHealth()
	if health.GitHub.State != subsystemHealthy || health.GitHub.LastSuccess == nil {
		t.Fatalf("successful poll did not establish GitHub health: %#v", health.GitHub)
	}
	if health.Docker.State != subsystemDegraded || health.Docker.ConsecutiveFailures != 1 {
		t.Fatalf("Docker failure did not degrade Docker health: %#v", health.Docker)
	}
}

// TestSubsystemHealthTracksDegradationAndRecovery proves repeated failures
// escalate and that recovery is journaled once.
func TestSubsystemHealthTracksDegradationAndRecovery(t *testing.T) {
	recorder, _, clock := newTestRecorder(t)
	for attempt := 0; attempt < subsystemFailureBand; attempt++ {
		recorder.record(failureObservation(operationDockerRun, reasonDockerFailed))
		clock.advance(time.Second)
	}
	if state := recorder.subsystemHealth().Docker; state.State != subsystemUnavailable ||
		state.ConsecutiveFailures != subsystemFailureBand ||
		state.LastFailure == nil {
		t.Fatalf("repeated Docker failures did not report unavailable: %#v", state)
	}
	failures := recorder.journal()
	if len(failures.Events) != 1 ||
		failures.Events[0].OccurrenceCount != subsystemFailureBand ||
		failures.Events[0].FirstObservedAt == failures.Events[0].LastObservedAt {
		t.Fatalf("equivalent failures were not coalesced: %#v", failures)
	}
	recorder.record(diagnosticsObservation{
		subsystem:  subsystemDocker,
		operation:  operationDockerRun,
		outcome:    outcomeSucceeded,
		reason:     reasonNone,
		healthKind: healthDocker,
	})
	health := recorder.subsystemHealth().Docker
	if health.State != subsystemHealthy ||
		health.ConsecutiveFailures != 0 ||
		health.LastSuccess == nil ||
		health.LastFailure == nil {
		t.Fatalf("Docker recovery lost prior failure evidence: %#v", health)
	}
	journal := recorder.journal()
	last := journal.Events[len(journal.Events)-1]
	if last.Outcome != outcomeRecovered || last.Reason != reasonRecovered {
		t.Fatalf("recovery was not journaled: %#v", last)
	}
}

func TestJournalCoalescesInterleavedFailureStorms(t *testing.T) {
	recorder, _, clock := newTestRecorder(t)
	recorder.record(diagnosticsObservation{
		subsystem: subsystemWorkerExit,
		operation: operationWorkerExit,
		target:    "runner-causal",
		outcome:   outcomeFailed,
		reason:    reasonUnknown,
		evidence:  "worker exit could not release its host lease",
	})
	for attempt := 0; attempt < journalCapacity+20; attempt++ {
		clock.advance(time.Second)
		recorder.record(diagnosticsObservation{
			subsystem: subsystemAdmission,
			operation: operationAdmissionReserve,
			target:    "target-a",
			outcome:   outcomeBlocked,
			reason:    reasonCapacityCeiling,
			evidence:  "host admission withheld worker activation",
		})
		recorder.record(diagnosticsObservation{
			subsystem: subsystemWorkerLaunch,
			operation: operationWorkerLaunch,
			target:    "target-a",
			outcome:   outcomeFailed,
			reason:    reasonUnknown,
			evidence:  "worker launch remained blocked",
		})
	}

	journal := recorder.journal()
	if journal.Status != journalStatusCurrent ||
		journal.DroppedEvents != 0 ||
		journal.EvictedEvents != 0 ||
		journal.RejectedEvents != 0 ||
		journal.UnclassifiedEvents != 0 ||
		len(journal.Events) != 3 {
		t.Fatalf("failure storm displaced causal evidence: %#v", journal)
	}
	if journal.Events[0].Operation != operationWorkerExit {
		t.Fatalf("causal worker-exit evidence was not retained: %#v", journal.Events)
	}
	for _, event := range journal.Events[1:] {
		if event.OccurrenceCount != journalCapacity+20 ||
			event.FirstObservedAt == event.LastObservedAt {
			t.Fatalf("failure storm was not aggregated: %#v", event)
		}
	}
}

func TestJournalOutcomeChangeStartsNewEpisode(t *testing.T) {
	recorder, _, clock := newTestRecorder(t)
	recorder.record(failureObservation(operationDockerRun, reasonDockerFailed))
	clock.advance(time.Second)
	recorder.record(failureObservation(operationDockerRun, reasonDockerFailed))
	clock.advance(time.Second)
	recorder.record(diagnosticsObservation{
		subsystem:  subsystemDocker,
		operation:  operationDockerRun,
		outcome:    outcomeSucceeded,
		reason:     reasonNone,
		healthKind: healthDocker,
	})
	clock.advance(time.Second)
	recorder.record(failureObservation(operationDockerRun, reasonDockerFailed))

	journal := recorder.journal()
	if len(journal.Events) != 3 ||
		journal.Events[0].OccurrenceCount != 2 ||
		journal.Events[1].Outcome != outcomeRecovered ||
		journal.Events[2].OccurrenceCount != 1 {
		t.Fatalf("outcome transition did not bound coalescing: %#v", journal)
	}
}

func TestJournalKeepsSuccessfulTransitionsDistinct(t *testing.T) {
	recorder, _, clock := newTestRecorder(t)
	for attempt := 0; attempt < 2; attempt++ {
		recorder.record(diagnosticsObservation{
			subsystem: subsystemReconciliation,
			operation: operationDesiredStateApply,
			outcome:   outcomeSucceeded,
			reason:    reasonNone,
			evidence:  "accepted a new desired capacity generation",
		})
		clock.advance(time.Second)
	}

	journal := recorder.journal()
	if len(journal.Events) != 2 ||
		journal.Events[0].OccurrenceCount != 1 ||
		journal.Events[1].OccurrenceCount != 1 {
		t.Fatalf("successful transitions were incorrectly coalesced: %#v", journal)
	}
}

// TestJournalSurvivesManagerRestart proves listener and Docker failures that
// preceded recovery remain visible after the manager restarts, with stable
// event identity for connector deduplication.
func TestJournalSurvivesManagerRestart(t *testing.T) {
	recorder, directory, clock := newTestRecorder(t)
	recorder.record(diagnosticsObservation{
		subsystem:  subsystemListener,
		operation:  operationMessagePoll,
		outcome:    outcomeFailed,
		reason:     reasonTimeout,
		evidence:   "scale-set listener stopped for this target",
		healthKind: healthGitHub,
	})
	recorder.record(failureObservation(operationDockerRun, reasonDockerFailed))

	restarted := newDiagnosticsRecorder(directory, "instance-two", clock)
	restarted.restore()
	journal := restarted.journal()
	if len(journal.Events) != 3 {
		t.Fatalf("restart lost durable journal events: %#v", journal)
	}
	if journal.Events[0].ManagerInstanceID != "instance-one" ||
		journal.Events[0].Sequence != 1 ||
		journal.Events[0].Operation != operationMessagePoll ||
		journal.Events[1].Sequence != 2 ||
		journal.Events[1].Operation != operationDockerRun {
		t.Fatalf("restart changed durable event identity: %#v", journal.Events)
	}
	if journal.Events[2].Operation != operationJournalRestore ||
		journal.Events[2].ManagerInstanceID != "instance-two" {
		t.Fatalf("restart did not record its own recovery: %#v", journal.Events[2])
	}
	restarted.record(failureObservation(operationDockerRemove, reasonDockerFailed))
	journal = restarted.journal()
	next := journal.Events[len(journal.Events)-1]
	if next.Sequence != 4 || next.ManagerInstanceID != "instance-two" {
		t.Fatalf("restart did not continue the durable sequence: %#v", next)
	}
}

func TestJournalRestoresCoalescedAndLegacyEvents(t *testing.T) {
	recorder, directory, clock := newTestRecorder(t)
	recorder.record(failureObservation(operationDockerRun, reasonDockerFailed))
	clock.advance(time.Second)
	recorder.record(failureObservation(operationDockerRun, reasonDockerFailed))

	path := filepath.Join(directory, diagnosticsJournalFileName)
	var document journalDocument
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &document); err != nil {
		t.Fatal(err)
	}
	document.SchemaVersion = legacyDiagnosticsSchemaVersion
	document.Events = append(document.Events, managerEvent{
		Sequence:          document.HighestSequence + 1,
		ManagerInstanceID: "legacy-instance",
		ObservedAt:        "2026-07-20T12:00:02Z",
		Subsystem:         subsystemCleanup,
		Operation:         operationRegistrationCleanup,
		Outcome:           outcomeRetry,
		Reason:            reasonRetryBackoff,
	})
	document.HighestSequence++
	data, err = json.MarshalIndent(document, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}

	restarted := newDiagnosticsRecorder(directory, "instance-two", clock)
	restarted.restore()
	journal := restarted.journal()
	if len(journal.Events) != 3 {
		t.Fatalf("restart lost aggregate or legacy evidence: %#v", journal)
	}
	aggregate := journal.Events[0]
	if aggregate.OccurrenceCount != 2 ||
		aggregate.FirstObservedAt == aggregate.LastObservedAt {
		t.Fatalf("restart lost coalesced event metadata: %#v", aggregate)
	}
	legacy := journal.Events[1]
	if legacy.OccurrenceCount != 1 ||
		legacy.FirstObservedAt != legacy.ObservedAt ||
		legacy.LastObservedAt != legacy.ObservedAt {
		t.Fatalf("legacy event was not normalized during restore: %#v", legacy)
	}
}

func TestJournalMigratesUnclassifiedLegacyDropsWithoutDegradingCurrentWindow(t *testing.T) {
	directory := projectTestDirectory(t)
	document := journalDocument{
		SchemaVersion:   previousDiagnosticsSchemaVersion,
		HighestSequence: 1,
		DroppedEvents:   12,
		Events: []managerEvent{{
			Sequence:          1,
			ManagerInstanceID: "instance-one",
			ObservedAt:        "2026-07-20T12:00:00Z",
			FirstObservedAt:   "2026-07-20T12:00:00Z",
			LastObservedAt:    "2026-07-20T12:00:00Z",
			OccurrenceCount:   1,
			Subsystem:         subsystemDocker,
			Operation:         operationDockerRun,
			Outcome:           outcomeRecovered,
			Reason:            reasonRecovered,
		}},
	}
	data, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(directory, diagnosticsJournalFileName),
		data,
		0o644,
	); err != nil {
		t.Fatal(err)
	}

	recorder := newDiagnosticsRecorder(directory, "instance-two", nil)
	recorder.restore()
	journal := recorder.journal()
	if journal.Status != journalStatusCurrent ||
		journal.DroppedEvents != 12 ||
		journal.EvictedEvents != 0 ||
		journal.RejectedEvents != 0 ||
		journal.UnclassifiedEvents != 12 {
		t.Fatalf("legacy drops were not retained as non-priority unclassified evidence: %#v", journal)
	}
	migratedData, err := os.ReadFile(filepath.Join(directory, diagnosticsJournalFileName))
	if err != nil {
		t.Fatal(err)
	}
	var migrated journalDocument
	if err := json.Unmarshal(migratedData, &migrated); err != nil {
		t.Fatal(err)
	}
	if migrated.SchemaVersion != diagnosticsSchemaVersion ||
		migrated.DroppedEvents != 12 ||
		migrated.UnclassifiedEvents != 12 {
		t.Fatalf("legacy journal was not persisted in the classified schema: %#v", migrated)
	}
}

// TestJournalCorruptionIsContained proves a corrupt journal is discarded
// without destroying live state or failing the manager.
func TestJournalCorruptionIsContained(t *testing.T) {
	directory := projectTestDirectory(t)
	path := filepath.Join(directory, diagnosticsJournalFileName)
	if err := os.WriteFile(path, []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	clock := &fakeClock{current: time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)}
	recorder := newDiagnosticsRecorder(directory, "instance-one", clock)
	recorder.restore()
	journal := recorder.journal()
	if journal.Status != journalStatusUnavailable ||
		journal.DroppedEvents < 1 ||
		journal.RejectedEvents < 1 ||
		len(journal.Events) != 0 ||
		journal.HighestSequence != nil {
		t.Fatalf("corrupt journal was not contained: %#v", journal)
	}
	recorder.record(failureObservation(operationDockerRun, reasonDockerFailed))
	journal = recorder.journal()
	if journal.Status != journalStatusTruncated || len(journal.Events) != 1 {
		t.Fatalf("recorder did not resume after journal corruption: %#v", journal)
	}
}

// TestJournalDropsMalformedPersistedEntries proves one malformed entry cannot
// invalidate the retained window.
func TestJournalDropsMalformedPersistedEntries(t *testing.T) {
	directory := projectTestDirectory(t)
	document := journalDocument{
		SchemaVersion:   legacyDiagnosticsSchemaVersion,
		HighestSequence: 2,
		Events: []managerEvent{
			{Sequence: 0, ManagerInstanceID: "", Operation: ""},
			{
				Sequence:          2,
				ManagerInstanceID: "instance-one",
				ObservedAt:        "2026-07-20T12:00:00Z",
				Subsystem:         subsystemDocker,
				Operation:         operationDockerRun,
				Outcome:           outcomeFailed,
				Reason:            reasonDockerFailed,
			},
		},
	}

	data, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(directory, diagnosticsJournalFileName),
		data,
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	recorder := newDiagnosticsRecorder(directory, "instance-two", nil)
	recorder.restore()
	journal := recorder.journal()
	if len(journal.Events) != 2 || journal.Events[0].Sequence != 2 {
		t.Fatalf("valid retained events were lost: %#v", journal)
	}
	if journal.Status != journalStatusTruncated ||
		journal.DroppedEvents != 1 ||
		journal.RejectedEvents != 1 ||
		journal.EvictedEvents != 0 ||
		journal.UnclassifiedEvents != 0 {
		t.Fatalf("malformed entry was not counted as dropped: %#v", journal)
	}
}

func TestJournalUnsupportedSchemaIsUnavailable(t *testing.T) {
	directory := projectTestDirectory(t)
	document := journalDocument{SchemaVersion: 99}
	data, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(directory, diagnosticsJournalFileName),
		data,
		0o644,
	); err != nil {
		t.Fatal(err)
	}

	recorder := newDiagnosticsRecorder(directory, "instance-two", nil)
	recorder.restore()
	journal := recorder.journal()
	if journal.Status != journalStatusUnavailable ||
		journal.DroppedEvents != 1 ||
		journal.RejectedEvents != 1 ||
		len(journal.Events) != 0 {
		t.Fatalf("unsupported journal schema did not fail closed: %#v", journal)
	}
}

func TestJournalRejectsInvalidSchemaThreeAggregate(t *testing.T) {
	directory := projectTestDirectory(t)
	document := journalDocument{
		SchemaVersion:   diagnosticsSchemaVersion,
		HighestSequence: 1,
		Events: []managerEvent{{
			Sequence:          1,
			ManagerInstanceID: "instance-one",
			ObservedAt:        "2026-07-20T12:00:00Z",
			FirstObservedAt:   "2026-07-20T12:00:00Z",
			LastObservedAt:    "2026-07-20T12:00:00Z",
			OccurrenceCount:   0,
			Subsystem:         subsystemDocker,
			Operation:         operationDockerRun,
			Outcome:           outcomeFailed,
			Reason:            reasonDockerFailed,
		}},
	}
	data, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(directory, diagnosticsJournalFileName),
		data,
		0o644,
	); err != nil {
		t.Fatal(err)
	}

	recorder := newDiagnosticsRecorder(directory, "instance-two", nil)
	recorder.restore()
	journal := recorder.journal()
	if journal.Status != journalStatusTruncated ||
		journal.DroppedEvents != 1 ||
		len(journal.Events) != 0 {
		t.Fatalf("invalid schema-three aggregate was not discarded: %#v", journal)
	}
}

// TestJournalWriteFailureIsRecordedNotPropagated proves diagnostic persistence
// failure preserves the live pool.
func TestJournalWriteFailureIsRecordedNotPropagated(t *testing.T) {
	recorder, _, _ := newTestRecorder(t)
	recorder.write = func(string, []byte, os.FileMode) error {
		return errors.New("state directory is read only")
	}
	recorder.record(failureObservation(operationDockerRun, reasonDockerFailed))
	if !recorder.persistenceDegraded() {
		t.Fatal("journal write failure was not recorded")
	}
	if journal := recorder.journal(); len(journal.Events) != 1 {
		t.Fatalf("journal write failure discarded in-memory evidence: %#v", journal)
	}
}

// TestJournalRespectsCapacityAndSizeBudget proves the retained window stays
// bounded in both entries and serialized bytes.
func TestJournalRespectsCapacityAndSizeBudget(t *testing.T) {
	recorder, _, _ := newTestRecorder(t)
	for attempt := 0; attempt < journalCapacity+5; attempt++ {
		recorder.record(diagnosticsObservation{
			subsystem: subsystemCleanup,
			operation: operationRegistrationCleanup,
			target:    fmt.Sprintf("repo-one-%d", attempt),
			outcome:   outcomeRetry,
			reason:    reasonRetryBackoff,
			evidence:  "exact runner registration removal is still pending",
		})
	}
	journal := recorder.journal()
	if len(journal.Events) > journalCapacity {
		t.Fatalf("journal exceeded its capacity: %d", len(journal.Events))
	}
	if journal.Status != journalStatusCurrent ||
		journal.DroppedEvents < 5 ||
		journal.EvictedEvents != journal.DroppedEvents ||
		journal.RejectedEvents != 0 ||
		journal.UnclassifiedEvents != 0 {
		t.Fatalf("expected eviction did not preserve a current retained window: %#v", journal)
	}
	encoded, err := json.Marshal(journal.Events)
	if err != nil {
		t.Fatal(err)
	}
	if len(encoded) > journalMaximumBytes {
		t.Fatalf("journal exceeded its serialized budget: %d bytes", len(encoded))
	}
}

func TestJournalRetainsUnresolvedRecoveryAcrossAdmissionFailures(t *testing.T) {
	recorder, _, _ := newTestRecorder(t)
	recorder.record(diagnosticsObservation{
		subsystem: subsystemRecovery,
		operation: operationManagerStart,
		outcome:   outcomeBlocked,
		reason:    reasonInvalidState,
		evidence:  "orphaned host admission lease reconciliation is pending",
	})
	for attempt := 0; attempt < journalCapacity+5; attempt++ {
		recorder.record(diagnosticsObservation{
			subsystem: subsystemAdmission,
			operation: operationAdmissionReserve,
			target:    fmt.Sprintf("repo-one-%d", attempt),
			outcome:   outcomeBlocked,
			reason:    reasonCapacityCeiling,
			evidence:  "host admission withheld worker activation",
		})
	}
	journal := recorder.journal()
	foundPending := false
	for _, event := range journal.Events {
		if event.Subsystem == subsystemRecovery &&
			event.Outcome == outcomeBlocked {
			foundPending = true
			break
		}
	}
	if !foundPending {
		t.Fatal("repeated admission failures evicted unresolved recovery evidence")
	}

	recorder.record(diagnosticsObservation{
		subsystem: subsystemRecovery,
		operation: operationManagerStart,
		outcome:   outcomeRecovered,
		reason:    reasonRecovered,
		evidence:  "orphaned host admission lease reconciliation completed",
	})
	journal = recorder.journal()
	for _, event := range journal.Events {
		if event.Subsystem == subsystemRecovery &&
			event.Outcome == outcomeBlocked {
			t.Fatal("resolved recovery evidence remained protected from normal truncation")
		}
	}
}

// TestSanitizedEvidenceRejectsUnsafeCharacters proves evidence cannot relay
// URLs, tokens, headers, or raw command output.
func TestSanitizedEvidenceRejectsUnsafeCharacters(t *testing.T) {
	evidence := sanitizedEvidence(
		"docker run failed: https://api.github.com/x?token=abc&id=1 @host",
	)
	if evidence == nil {
		t.Fatal("evidence was discarded entirely")
	}
	for _, symbol := range []string{":", "/", "@", "?", "=", "&"} {
		if contains := *evidence; len(contains) > 0 &&
			containsSymbol(contains, symbol) {
			t.Fatalf("evidence relayed unsafe characters: %q", *evidence)
		}
	}
	if len(*sanitizedEvidence(longEvidenceText())) > evidenceMaximumRunes {
		t.Fatal("evidence exceeded the contract length budget")
	}
}

func containsSymbol(text string, symbol string) bool {
	for index := 0; index+len(symbol) <= len(text); index++ {
		if text[index:index+len(symbol)] == symbol {
			return true
		}
	}
	return false
}

func longEvidenceText() string {
	text := ""
	for len(text) < 400 {
		text += "worker container launch failed "
	}
	return text
}

// TestClassifyFailureUsesClosedVocabulary proves errors are mapped to contract
// reasons rather than relayed verbatim.
func TestClassifyFailureUsesClosedVocabulary(t *testing.T) {
	cases := map[string]struct {
		err            error
		expectedReason string
		expectOutcome  string
	}{
		"timeout": {
			err:            context.DeadlineExceeded,
			expectedReason: reasonTimeout,
			expectOutcome:  outcomeTimedOut,
		},
		"cancelled": {
			err:            context.Canceled,
			expectedReason: reasonCancelled,
			expectOutcome:  outcomeFailed,
		},
		"unknown": {
			err:            errors.New("api returned 500 for https://example.test"),
			expectedReason: reasonUnknown,
			expectOutcome:  outcomeFailed,
		},
	}
	for name, testCase := range cases {
		if reason := classifyFailure(testCase.err); reason != testCase.expectedReason {
			t.Fatalf("%s classified as %q", name, reason)
		}
		if outcome := failureOutcome(testCase.err); outcome != testCase.expectOutcome {
			t.Fatalf("%s produced outcome %q", name, outcome)
		}
	}
	if reason := dockerFailureReason(errors.New("docker daemon refused")); reason != reasonDockerFailed {
		t.Fatalf("Docker failure classified as %q", reason)
	}
}

// TestInstrumentedDockerClientPublishesLaunchFailure proves Docker launch
// failures reach the journal and Docker health without leaking command output.
func TestInstrumentedDockerClientPublishesLaunchFailure(t *testing.T) {
	recorder, _, _ := newTestRecorder(t)
	docker := newFakeDockerClient(nil)
	docker.runErrors = []error{errors.New("docker run failed: permission denied /var/run/docker.sock")}
	instrumented := instrumentDockerClient(docker, recorder)
	if _, err := instrumented.run(context.Background(), containerLaunch{}); err == nil {
		t.Fatal("expected the launch failure to surface to the caller")
	}
	journal := recorder.journal()
	if len(journal.Events) != 1 || journal.Events[0].Operation != operationDockerRun {
		t.Fatalf("Docker launch failure was not journaled: %#v", journal)
	}
	if evidence := journal.Events[0].Evidence; evidence != nil &&
		containsSymbol(*evidence, "/") {
		t.Fatalf("Docker evidence relayed a raw path: %q", *evidence)
	}
	if recorder.subsystemHealth().Docker.State != subsystemDegraded {
		t.Fatal("Docker health did not degrade after a launch failure")
	}
}

// TestInstrumentedScaleSetServicePublishesFailures proves JIT generation and
// session failures are published as GitHub subsystem evidence.
func TestInstrumentedScaleSetServicePublishesFailures(t *testing.T) {
	recorder, _, _ := newTestRecorder(t)
	api := newFakeScaleSetService(nil)
	api.generateErrors = []error{errors.New("scale set rejected the request")}
	instrumented := instrumentScaleSetService(api, recorder)
	if _, err := instrumented.generateJIT(context.Background(), 42, "runner"); err == nil {
		t.Fatal("expected the JIT failure to surface to the caller")
	}
	journal := recorder.journal()
	if len(journal.Events) != 1 ||
		journal.Events[0].Operation != operationJITConfigGenerate ||
		journal.Events[0].Subsystem != subsystemJIT {
		t.Fatalf("JIT failure was not journaled: %#v", journal)
	}
	if recorder.subsystemHealth().GitHub.State != subsystemDegraded {
		t.Fatal("GitHub health did not degrade after a JIT failure")
	}
}

// TestListenerOpenTimeoutIsPublished proves an open-session timeout is reported
// as a timed-out listener operation rather than an unclassified failure.
func TestListenerOpenTimeoutIsPublished(t *testing.T) {
	recorder, _, _ := newTestRecorder(t)
	session := newFakeMessageSession()
	session.getError = context.DeadlineExceeded
	instrumented := instrumentMessageSession(session, recorder)
	if _, err := instrumented.GetMessage(context.Background(), 0, 1); err == nil {
		t.Fatal("expected the poll timeout to surface to the caller")
	}
	journal := recorder.journal()
	if len(journal.Events) != 1 ||
		journal.Events[0].Outcome != outcomeTimedOut ||
		journal.Events[0].Reason != reasonTimeout {
		t.Fatalf("listener timeout was not published: %#v", journal)
	}
}
