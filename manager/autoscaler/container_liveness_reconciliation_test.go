package main

import (
	"context"
	"errors"
	"testing"
	"time"
)

// TestContainerLivenessReconciliationReclaimsAbsentContainerIndependentOfWedgedMonitor
// proves the exact regression PR #160 left uncaught: a monitor pair whose
// docker wait call never returns (the unhardened child/process-tree bug)
// must not be the only path that can ever discover an absent container.
// docker.wait is left permanently blocked on ctx.Done() (no queued result),
// simulating a wedged docker CLI child that ignores its parent's
// cancellation; reconcileContainerLiveness's own independent isRunning probe
// must still reclaim the slot and release its lease.
func TestContainerLivenessReconciliationReclaimsAbsentContainerIndependentOfWedgedMonitor(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, api, docker, clock, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	runner := findRunner(t, scaler)
	originalLeaseKey := leaseSlotKey("profile-a", runner.hostSlotKey)

	docker.mu.Lock()
	docker.running[runner.containerID] = false
	docker.mu.Unlock()
	clock.advance(containerLivenessReconcileGrace + time.Second)

	if err := scaler.tick(context.Background()); err != nil {
		t.Fatal(err)
	}

	if scaler.hasRunner(runner.containerID) {
		t.Fatal("confirmed absent container was not reclaimed independently of its wedged monitor pair")
	}
	released := false
	for _, key := range client.releaseCalls {
		if key == originalLeaseKey {
			released = true
		}
	}
	if !released {
		t.Fatalf("host admission lease was not released for the confirmed absent container: %#v", client.releaseCalls)
	}
	if len(api.removeCalls) != 1 || api.removeCalls[0] != runner.runnerID {
		t.Fatalf("registration was not removed for the reclaimed runner: %#v", api.removeCalls)
	}
	if len(docker.stopRemove) != 0 {
		t.Fatalf("reconciliation must never issue a worker-directed command for an already-absent container: %#v", docker.stopRemove)
	}
	// Target capacity stays 1, so the same tick that reclaims the absent
	// slot must also restore withheld demand with a fresh replacement
	// rather than leaving capacity stuck short.
	if len(docker.launches) != 2 {
		t.Fatalf("withheld demand was not restored after reclaiming the absent container: %#v", docker.launches)
	}
	if client.leaseCount() != 1 {
		t.Fatalf("expected exactly one lease for the replacement runner, got %d", client.leaseCount())
	}
}

// TestContainerLivenessReconciliationFailsClosedOnAmbiguousProbe proves an
// ambiguous Docker probe (socket error, daemon unreachable) changes nothing:
// the runner, its lease, and its containerConfirmedAt watermark must all be
// preserved so the next tick retries rather than guessing the container is
// gone.
func TestContainerLivenessReconciliationFailsClosedOnAmbiguousProbe(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, _, docker, clock, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	runner := findRunner(t, scaler)
	originalConfirmedAt := runner.containerConfirmedAt

	docker.mu.Lock()
	docker.runningErrors[runner.containerID] = []error{errors.New("dial unix docker.sock: connection refused")}
	docker.mu.Unlock()
	clock.advance(containerLivenessReconcileGrace + time.Second)

	if err := scaler.tick(context.Background()); err == nil {
		t.Fatal("expected the ambiguous probe error to surface rather than be swallowed")
	}

	if !scaler.hasRunner(runner.containerID) {
		t.Fatal("ambiguous probe incorrectly reclaimed a runner it could not confirm absent")
	}
	if client.leaseCount() != 1 {
		t.Fatalf("ambiguous probe incorrectly released a lease: %d outstanding", client.leaseCount())
	}
	reconciled := findRunner(t, scaler)
	if !reconciled.containerConfirmedAt.Equal(originalConfirmedAt) {
		t.Fatalf("ambiguous probe must not refresh containerConfirmedAt: was %v now %v", originalConfirmedAt, reconciled.containerConfirmedAt)
	}
	if slot := observedRunnerSlot(reconciled, false, ""); !slot.ProcessRunning {
		t.Fatal("ambiguous probe must preserve the last confirmed processRunning evidence, not clear it")
	}
}

// TestContainerLivenessReconciliationRefreshesConfirmationForLiveBusyRunner
// proves a genuinely live, busy worker is left untouched and its
// containerConfirmedAt watermark is refreshed by the independent probe, so
// a merely-slow (not wedged) monitor pair never causes a live worker to be
// mistaken for absent on a later cycle.
func TestContainerLivenessReconciliationRefreshesConfirmationForLiveBusyRunner(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, _, docker, clock, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	runner := findRunner(t, scaler)
	scaler.handleLogSignal(runner.containerID, "Running job")
	originalConfirmedAt := findRunner(t, scaler).containerConfirmedAt

	docker.mu.Lock()
	docker.running[runner.containerID] = true
	docker.mu.Unlock()
	clock.advance(containerLivenessReconcileGrace + time.Second)

	if err := scaler.tick(context.Background()); err != nil {
		t.Fatal(err)
	}

	reconciled := findRunner(t, scaler)
	if reconciled.state != runnerBusy {
		t.Fatalf("busy worker state was disturbed by liveness reconciliation: %q", reconciled.state)
	}
	if !reconciled.containerConfirmedAt.After(originalConfirmedAt) {
		t.Fatalf("live container's confirmation watermark was not refreshed: before=%v after=%v", originalConfirmedAt, reconciled.containerConfirmedAt)
	}
	if client.leaseCount() != 1 {
		t.Fatalf("live/busy worker's lease was disturbed: %d outstanding", client.leaseCount())
	}
	if len(docker.stopRemove) != 0 {
		t.Fatalf("live/busy worker must never receive a worker-directed command: %#v", docker.stopRemove)
	}
	if slot := observedRunnerSlot(reconciled, false, ""); !slot.ProcessRunning {
		t.Fatal("confirmed-live worker must report processRunning true")
	}
}

// TestContainerLivenessReconciliationReclaimsStaleRecoveredContainerAfterRestartAdoption
// closes the restart/adoption gap: a container this manager instance
// adopted from a prior process (recoverRunning) that turns out to already be
// gone by the time it is actually probed must still be reclaimed once the
// grace period elapses, exactly like a normally launched runner. Adoption
// must only protect a runner from premature scale-down, never from ever
// being reconciled against reality.
func TestContainerLivenessReconciliationReclaimsStaleRecoveredContainerAfterRestartAdoption(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	client.preGrant("profile-a", "slot-recovered", true)
	scaler, api, docker, clock, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()

	container := recoveredContainer{
		containerID: "container-recovered",
		name:        "runner-recovered",
		runnerName:  "runner-recovered",
		runnerID:    300,
		targetKey:   "repo-1234",
		slotKey:     "repo-1234-300",
		revision:    testWorkerRevision,
		createdAt:   clock.now().Add(-time.Hour),
		hostSlotKey: "slot-recovered",
	}
	if err := scaler.recover(container); err != nil {
		t.Fatalf("recovery of a running container must succeed: %v", err)
	}
	runner := findRunner(t, scaler)
	if runner.hostSlotKey != "slot-recovered" || !runner.hostLeaseAdopted {
		t.Fatalf("recovered runner did not adopt its prior lease: %+v", runner)
	}

	// The container a prior manager instance created is already gone by the
	// time this instance's own probe resolves it; its own recovered monitor
	// pair is left permanently wedged (no queued wait result), matching the
	// exact reported symptom of a restart inheriting an orphaned pair.
	docker.mu.Lock()
	docker.running[runner.containerID] = false
	docker.mu.Unlock()
	clock.advance(containerLivenessReconcileGrace + time.Second)

	if err := scaler.tick(context.Background()); err != nil {
		t.Fatal(err)
	}

	if scaler.hasRunner(runner.containerID) {
		t.Fatal("stale recovered container record was not reclaimed after the grace period")
	}
	if client.leaseCount() != 0 {
		t.Fatalf("adopted lease was not released for a stale recovered container: %d outstanding", client.leaseCount())
	}
	if len(api.removeCalls) != 1 || api.removeCalls[0] != 300 {
		t.Fatalf("stale recovered runner's registration was not removed exactly: %#v", api.removeCalls)
	}
}

// TestContainerLivenessReconciliationRepeatedCyclesLeaveNoDuplicateRunnersOrLeases
// simulates long manager uptime: many independent reconcile cycles pass for
// a runner that stays alive the entire time. None of them may duplicate the
// runner record, relaunch a replacement container, or touch its lease.
func TestContainerLivenessReconciliationRepeatedCyclesLeaveNoDuplicateRunnersOrLeases(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, _, docker, clock, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	runner := findRunner(t, scaler)

	for cycle := 0; cycle < 20; cycle++ {
		clock.advance(containerLivenessReconcileGrace + time.Second)
		if err := scaler.tick(context.Background()); err != nil {
			t.Fatalf("cycle %d: %v", cycle, err)
		}
	}

	final := findRunner(t, scaler)
	if final.containerID != runner.containerID {
		t.Fatalf("repeated reconcile cycles replaced a live runner's container identity: %+v", final)
	}
	if len(docker.launches) != 1 {
		t.Fatalf("repeated reconcile cycles launched a duplicate container for a still-live runner: %#v", docker.launches)
	}
	if client.leaseCount() != 1 {
		t.Fatalf("repeated reconcile cycles disturbed a stable lease: %d outstanding", client.leaseCount())
	}
}

// TestContainerLivenessReconciliationConvergesMonitorLeaseInvariant proves
// the end-state invariant this fix restores after any mix of confirmed and
// ambiguous absences: once convergence completes, every runner this scaler
// still tracks has exactly one live container and exactly one held
// admission lease, and every held lease belongs to exactly one tracked
// runner (unmatched leases == 0). It also proves withheld demand is
// restored: target capacity is exactly rebuilt, not left short.
func TestContainerLivenessReconciliationConvergesMonitorLeaseInvariant(t *testing.T) {
	client := newFakeHostAdmissionClient(2)
	scaler, _, docker, clock, _, cancel := newHostAdmissionTestScaler(t, 2, client)
	defer cancel()

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 2); err != nil {
		t.Fatal(err)
	}
	initial := scaler.snapshot().runners
	if len(initial) != 2 {
		t.Fatalf("expected two runners, got %d", len(initial))
	}
	live := initial[0]
	toReplace := initial[1]

	docker.mu.Lock()
	docker.running[toReplace.containerID] = false
	docker.mu.Unlock()
	clock.advance(containerLivenessReconcileGrace + time.Second)

	if err := scaler.tick(context.Background()); err != nil {
		t.Fatal(err)
	}

	converged := scaler.snapshot().runners
	if len(converged) != 2 {
		t.Fatalf("withheld demand was not restored after convergence: expected 2 runners, got %d: %#v", len(converged), converged)
	}
	if client.leaseCount() != 2 {
		t.Fatalf("lease count does not equal live runner count after convergence: leases=%d runners=%d", client.leaseCount(), len(converged))
	}
	if client.remainingBudget() != 0 {
		t.Fatalf("unmatched or leaked lease budget after convergence: %d units unaccounted for", client.remainingBudget())
	}
	for _, runner := range converged {
		if runner.hostSlotKey == "" {
			t.Fatalf("converged runner has no lease identity: %+v", runner)
		}
	}
	foundLive := false
	for _, runner := range converged {
		if runner.containerID == live.containerID {
			foundLive = true
		}
		if runner.containerID == toReplace.containerID {
			t.Fatal("absent container's slot key was not exactly reclaimed")
		}
	}
	if !foundLive {
		t.Fatal("live/busy compatible worker was disturbed by convergence")
	}
}
