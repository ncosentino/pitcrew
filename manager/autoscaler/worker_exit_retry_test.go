package main

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

func TestWorkerExitRetryDelayIsDeterministicJitteredAndBounded(t *testing.T) {
	first := workerExitRetryDelay("profile-a", "target-a", 1)
	if first < time.Minute || first >= time.Minute+workerExitRetryJitter {
		t.Fatalf("first delay outside jitter window: %s", first)
	}
	if first != workerExitRetryDelay("profile-a", "target-a", 1) {
		t.Fatal("retry jitter is not deterministic")
	}
	distinct := make(map[time.Duration]bool)
	for _, profile := range []string{"profile-a", "profile-b"} {
		for _, target := range []string{"target-a", "target-b"} {
			distinct[workerExitRetryDelay(profile, target, 1)] = true
		}
	}
	if len(distinct) < 2 {
		t.Fatal("profile/target identities did not spread retry deadlines")
	}
	jitter := first - time.Minute
	for failures, base := range []time.Duration{
		0, time.Minute, 2 * time.Minute, 4 * time.Minute,
		8 * time.Minute, 15 * time.Minute, 15 * time.Minute,
	} {
		expected := min(base+jitter, workerLaunchRetryMaximum)
		if failures == 0 {
			expected = 0
		}
		if actual := workerExitRetryDelay("profile-a", "target-a", failures); actual != expected {
			t.Fatalf("failure %d: delay = %s, want %s", failures, actual, expected)
		}
	}
}

func TestUnexpectedWorkerExitUsesProgressiveBackoffAcrossSuccessfulLaunches(t *testing.T) {
	scaler, api, docker, clock, cancel := newTestScaler(t, 1, 0, 0)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	for attempt := 1; attempt <= 7; attempt++ {
		runner := findRunner(t, scaler)
		clock.advance(4 * time.Second)
		scaler.handleContainerExit(runner.containerID, exitStatus(1))
		deadline := clock.now().Add(workerExitRetryDelay(scaler.profileID, scaler.target.key, attempt))
		if scaler.runnerCount() != 0 || api.jitCalls != attempt || len(docker.launches) != attempt {
			t.Fatal("failed worker was immediately replaced")
		}
		if scaler.exitFailures != attempt || !scaler.exitRetryAt.Equal(deadline) {
			t.Fatalf("exit retry lost progressive state: failures=%d deadline=%s", scaler.exitFailures, scaler.exitRetryAt)
		}
		if len(api.removeCalls) != attempt || api.removeCalls[attempt-1] != runner.runnerID {
			t.Fatal("backoff did not clean up the exact exited registration")
		}
		blocking := scaler.snapshot().blocking
		if blocking.reason != deficitRetryBackoff || blocking.evidence != workerExitRetryEvidence {
			t.Fatalf("exit backoff is not observable: %#v", blocking)
		}
		recorded := false
		for _, event := range scaler.diagnostics.journal().Events {
			if event.Operation == operationWorkerExit && event.Outcome == outcomeRetry &&
				event.Attempt != nil && *event.Attempt == attempt && event.RetryAt != nil &&
				*event.RetryAt == deadline.Format(time.RFC3339) {
				recorded = true
			}
		}
		if !recorded {
			t.Fatal("exit retry attempt/deadline was not journaled")
		}
		scaler.handleContainerExit(runner.containerID, exitStatus(1))
		if scaler.exitFailures != attempt {
			t.Fatal("duplicate exit callback advanced backoff")
		}
		clock.advance(deadline.Sub(clock.now()) - time.Second)
		if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
			t.Fatal(err)
		}
		if err := scaler.tick(context.Background()); err != nil {
			t.Fatal(err)
		}
		if api.jitCalls != attempt {
			t.Fatal("demand callback or reconciliation bypassed exit backoff")
		}
		clock.advance(time.Second)
		if err := scaler.tick(context.Background()); err != nil {
			t.Fatal(err)
		}
		if api.jitCalls != attempt+1 || len(docker.launches) != attempt+1 {
			t.Fatal("retry deadline did not admit exactly one replacement")
		}
		if err := scaler.tick(context.Background()); err != nil {
			t.Fatal(err)
		}
		if scaler.exitFailures != attempt {
			t.Fatal("Docker launch or satisfied local capacity was mistaken for worker health")
		}
	}
}

func TestCompletedWorkerClearsExitBackoffAndReplenishesImmediately(t *testing.T) {
	scaler, api, _, clock, cancel := newTestScaler(t, 1, 1, 0)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	failed := findRunner(t, scaler)
	scaler.handleContainerExit(failed.containerID, exitStatus(1))
	clock.advance(scaler.exitRetryAt.Sub(clock.now()))
	if err := scaler.tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	completed := findRunner(t, scaler)
	if err := scaler.HandleJobCompleted(context.Background(), &scaleset.JobCompleted{
		RunnerID: int(completed.runnerID), RunnerName: completed.runnerName,
	}); err != nil {
		t.Fatal(err)
	}
	scaler.handleContainerExit(completed.containerID, exitStatus(0))
	if scaler.runnerCount() != 1 || api.jitCalls != 3 {
		t.Fatal("one-job completion did not replenish the idle floor immediately")
	}
	if scaler.exitFailures != 0 || !scaler.exitRetryAt.IsZero() {
		t.Fatal("successful one-job completion did not clear exit backoff")
	}
	replacement := findRunner(t, scaler)
	scaler.handleContainerExit(replacement.containerID, exitStatus(1))
	if scaler.exitFailures != 1 {
		t.Fatal("failure after successful work did not restart at the base delay")
	}
}

func TestExitBackoffPreservesBusyWorkerAndCurrentDemand(t *testing.T) {
	scaler, api, docker, clock, cancel := newTestScaler(t, 2, 0, 0)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 2); err != nil {
		t.Fatal(err)
	}
	runners := scaler.snapshot().runners
	busy, failed := runners[0], runners[1]
	scaler.handleLogSignal(busy.containerID, "Running job")
	scaler.handleContainerExit(failed.containerID, exitStatus(1))
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 2); err != nil {
		t.Fatal(err)
	}
	if scaler.runnerCount() != 1 || api.jitCalls != 2 || len(docker.stopRemove) != 0 {
		t.Fatal("demand changes bypassed backoff or disturbed an active worker")
	}
	if findRunner(t, scaler).state != runnerBusy {
		t.Fatal("exit backoff changed a surviving busy worker")
	}
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	clock.advance(scaler.exitRetryAt.Sub(clock.now()))
	if err := scaler.tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if api.jitCalls != 2 || scaler.snapshot().targetSlots != 1 {
		t.Fatal("expired retry invented demand after target reduction")
	}
}

func TestExitBackoffDoesNotLaunchAfterCancellationOrShutdown(t *testing.T) {
	for _, shutdown := range []bool{false, true} {
		t.Run(map[bool]string{false: "cancellation", true: "shutdown"}[shutdown], func(t *testing.T) {
			scaler, api, _, clock, cancel := newTestScaler(t, 1, 0, 0)
			defer cancel()
			if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
				t.Fatal(err)
			}
			runner := findRunner(t, scaler)
			scaler.handleContainerExit(runner.containerID, exitStatus(1))
			clock.advance(scaler.exitRetryAt.Sub(clock.now()))
			if shutdown {
				if err := scaler.shutdown(context.Background()); err != nil {
					t.Fatal(err)
				}
				if err := scaler.tick(context.Background()); err != nil {
					t.Fatal(err)
				}
			} else {
				cancel()
				if err := scaler.tick(scaler.lifecycleContext); !errors.Is(err, context.Canceled) {
					t.Fatalf("canceled retry returned %v", err)
				}
			}
			if api.jitCalls != 1 {
				t.Fatal("exit retry launched after cancellation/shutdown")
			}
		})
	}
}
