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

func TestControlPlaneRateLimitBackoffSurvivesRestart(t *testing.T) {
	directory := projectTestDirectory(t)
	path := newStatePaths(directory).controlPlane
	clock := &fakeClock{
		current: time.Date(2026, 11, 2, 4, 0, 0, 0, time.UTC),
	}
	gate := newControlPlaneRateGate(path, "profile-a", clock)
	api := newFakeScaleSetService(nil)
	api.ensureErrors = []error{errors.New("API rate limit exceeded")}
	service := &pacedScaleSetService{inner: api, gate: gate}

	if _, err := service.ensureScaleSet(
		context.Background(),
		"scale-set",
		"",
		nil,
	); err == nil {
		t.Fatal("rate-limited control-plane operation succeeded")
	}
	if api.ensureCalls != 1 {
		t.Fatalf("initial API calls = %d, want 1", api.ensureCalls)
	}
	retryAt := gate.nextAttemptAt
	if retryAt.Sub(clock.now()) < registrationAccessRateLimitBase {
		t.Fatalf("rate-limit deadline is too short: %s", retryAt)
	}

	restarted := newControlPlaneRateGate(path, "profile-a", clock)
	if err := restarted.load(); err != nil {
		t.Fatal(err)
	}
	restartedService := &pacedScaleSetService{inner: api, gate: restarted}
	if _, err := restartedService.ensureScaleSet(
		context.Background(),
		"scale-set",
		"",
		nil,
	); err == nil {
		t.Fatal("restart bypassed control-plane backoff")
	} else {
		var backoffErr controlPlaneBackoffError
		if !errors.As(err, &backoffErr) {
			t.Fatalf("unexpected blocked operation error: %v", err)
		}
	}
	if api.ensureCalls != 1 {
		t.Fatal("backoff reached the underlying API")
	}

	clock.advance(retryAt.Sub(clock.now()))
	if _, err := restartedService.ensureScaleSet(
		context.Background(),
		"scale-set",
		"",
		nil,
	); err != nil {
		t.Fatal(err)
	}
	if api.ensureCalls != 2 {
		t.Fatalf("recovered API calls = %d, want 2", api.ensureCalls)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("successful operation retained control-plane backoff: %v", err)
	}
}

func TestControlPlanePrecommitUsesBoundedCrashDelay(t *testing.T) {
	clock := &fakeClock{
		current: time.Date(2026, 11, 2, 4, 0, 0, 0, time.UTC),
	}
	gate := newControlPlaneRateGate("", "profile-a", clock)
	if err := gate.before(); err != nil {
		t.Fatal(err)
	}
	delay := gate.nextAttemptAt.Sub(clock.now())
	if delay < time.Minute || delay >= time.Minute+controlPlaneCrashRetryJitter {
		t.Fatalf("crash retry is outside its bounded jitter window: %s", delay)
	}
	expected := clock.now().Add(gate.crashRetryDelay())
	if !gate.nextAttemptAt.Equal(expected) {
		t.Fatalf(
			"precommit deadline = %s, want %s",
			gate.nextAttemptAt,
			expected,
		)
	}
}

func TestControlPlaneOrdinaryFailureDoesNotBlockPeers(t *testing.T) {
	clock := &fakeClock{
		current: time.Date(2026, 11, 2, 4, 0, 0, 0, time.UTC),
	}
	gate := newControlPlaneRateGate("", "profile-a", clock)
	api := newFakeScaleSetService(nil)
	api.ensureErrors = []error{errors.New("temporary target failure")}
	service := &pacedScaleSetService{inner: api, gate: gate}
	if _, err := service.ensureScaleSet(
		context.Background(),
		"failed-target",
		"",
		nil,
	); err == nil {
		t.Fatal("ordinary failure was hidden")
	}
	if _, err := service.ensureScaleSet(
		context.Background(),
		"healthy-target",
		"",
		nil,
	); err != nil {
		t.Fatalf("ordinary target failure blocked a healthy peer: %v", err)
	}
	if api.ensureCalls != 2 {
		t.Fatalf("underlying API calls = %d, want 2", api.ensureCalls)
	}
}

func TestControlPlaneConcurrencyWaitHonorsContext(t *testing.T) {
	gate := newControlPlaneRateGate(
		"",
		"profile-a",
		&fakeClock{current: time.Now().UTC()},
	)
	for index := 0; index < registrationAccessMaxConcurrency; index++ {
		gate.slots <- struct{}{}
	}
	service := &pacedScaleSetService{
		inner: newFakeScaleSetService(nil),
		gate:  gate,
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := service.ensureScaleSet(
		ctx,
		"scale-set",
		"",
		nil,
	); !errors.Is(err, context.Canceled) {
		t.Fatalf("blocked control-plane operation ignored cancellation: %v", err)
	}
}

func TestControlPlaneIndeterminateFailureClearsCompletedCrashFence(t *testing.T) {
	directory := projectTestDirectory(t)
	path := newStatePaths(directory).controlPlane
	clock := &fakeClock{current: time.Now().UTC()}
	gate := newControlPlaneRateGate(path, "profile-a", clock)
	api := newFakeScaleSetService(nil)
	api.ensureErrors = []error{context.DeadlineExceeded}
	service := &pacedScaleSetService{inner: api, gate: gate}
	if _, err := service.ensureScaleSet(
		context.Background(),
		"failed-target",
		"",
		nil,
	); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("indeterminate failure was not preserved: %v", err)
	}
	if !gate.nextAttemptAt.IsZero() {
		t.Fatal("indeterminate failure blocked healthy peers in-process")
	}
	restarted := newControlPlaneRateGate(path, "profile-a", clock)
	if err := restarted.load(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("completed operation retained a synthetic crash fence: %v", err)
	}
	if err := restarted.before(); err != nil {
		t.Fatalf("completed operation blocked a replacement manager: %v", err)
	}

	func TestControlPlaneCompletedOperationsClearDurableGuard(t *testing.T) {
		for _, test := range []struct {
			name string
			err  error
		}{
			{name: "success"},
			{name: "ordinary", err: errors.New("temporary target failure")},
			{name: "authorization", err: errors.New("HTTP 403 forbidden")},
			{name: "canceled", err: context.Canceled},
			{name: "deadline", err: context.DeadlineExceeded},
		} {
			t.Run(test.name, func(t *testing.T) {
				path := newStatePaths(projectTestDirectory(t)).controlPlane
				clock := &fakeClock{current: time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)}
				gate := newControlPlaneRateGate(path, "profile-a", clock)
				service := &pacedScaleSetService{gate: gate}
				err := service.run(context.Background(), func() error { return test.err })
				if !errors.Is(err, test.err) {
					t.Fatalf("operation result changed: %v", err)
				}
				if gate.inFlight != 0 || len(gate.slots) != 0 || !gate.nextAttemptAt.IsZero() {
					t.Fatal("completed operation retained transient gate ownership")
				}
				if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
					t.Fatalf("completed operation retained durable guard: %v", err)
				}
				restarted := newControlPlaneRateGate(path, "profile-a", clock)
				if err := restarted.load(); err != nil {
					t.Fatal(err)
				}
				if err := restarted.before(); err != nil {
					t.Fatalf("ordinary result blocked progress after restart: %v", err)
				}
			})
		}
	}

	func TestControlPlaneCancellationDuringOperationClearsGuard(t *testing.T) {
		path := newStatePaths(projectTestDirectory(t)).controlPlane
		clock := &fakeClock{current: time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)}
		gate := newControlPlaneRateGate(path, "profile-a", clock)
		service := &pacedScaleSetService{gate: gate}
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		started := make(chan struct{})
		result := make(chan error, 1)
		go func() {
			result <- service.run(ctx, func() error {
				close(started)
				<-ctx.Done()
				return ctx.Err()
			})
		}()
		select {
		case <-started:
		case <-time.After(time.Second):
			t.Fatal("operation did not start")
		}
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("in-flight operation did not precommit its crash guard: %v", err)
		}
		cancel()
		select {
		case err := <-result:
			if !errors.Is(err, context.Canceled) {
				t.Fatalf("cancellation was not propagated: %v", err)
			}
		case <-time.After(time.Second):
			t.Fatal("canceled operation did not settle")
		}
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("cancellation retained the synthetic guard: %v", err)
		}
	}

	func TestControlPlaneCanceledBeforeAdmissionDoesNotWriteOrCall(t *testing.T) {
		for _, occupied := range []bool{false, true} {
			path := newStatePaths(projectTestDirectory(t)).controlPlane
			gate := newControlPlaneRateGate(path, "profile-a", &fakeClock{})
			if occupied {
				for index := 0; index < registrationAccessMaxConcurrency; index++ {
					gate.slots <- struct{}{}
				}
			}
			service := &pacedScaleSetService{gate: gate}
			ctx, cancel := context.WithCancel(context.Background())
			cancel()
			called := false
			err := service.run(ctx, func() error {
				called = true
				return nil
			})
			if !errors.Is(err, context.Canceled) || called {
				t.Fatalf("canceled request entered the control plane: called=%t err=%v", called, err)
			}
			if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("canceled admission wrote retry state: %v", err)
			}
		}
	}

	func TestControlPlaneInterruptedOperationHasOnlyBoundedRestartGuard(t *testing.T) {
		path := newStatePaths(projectTestDirectory(t)).controlPlane
		clock := &fakeClock{current: time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)}
		gate := newControlPlaneRateGate(path, "profile-a", clock)
		if err := gate.before(); err != nil {
			t.Fatal(err)
		}
		deadline := gate.nextAttemptAt
		restarted := newControlPlaneRateGate(path, "profile-a", clock)
		if err := restarted.load(); err != nil {
			t.Fatal(err)
		}
		var blocked controlPlaneBackoffError
		if err := restarted.before(); !errors.As(err, &blocked) || !blocked.retryAt.Equal(deadline) {
			t.Fatalf("interrupted operation did not retain its bounded crash guard: %v", err)
		}
		clock.advance(deadline.Sub(clock.now()))
		if err := restarted.before(); err != nil {
			t.Fatalf("bounded guard did not expire: %v", err)
		}
		if err := restarted.after(nil); err != nil {
			t.Fatal(err)
		}
	}

	func TestControlPlaneLegacyZeroFailureGuardMigratesOnce(t *testing.T) {
		path := newStatePaths(projectTestDirectory(t)).controlPlane
		clock := &fakeClock{current: time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)}
		identity := "app:example"
		legacy := controlPlaneRetryState{
			SchemaVersion: 1, ManagerContractVersion: managerContractVersion,
			ProfileID: "profile-a", CredentialIdentity: identity,
			NextAttemptAt: clock.now().Add(registrationAccessNextDelay("profile-a", 0, false)).Format(time.RFC3339),
		}
		if err := writeJSONAtomically(path, legacy); err != nil {
			t.Fatal(err)
		}
		gate := newControlPlaneRateGate(path, "profile-a", clock)
		gate.credentialIdentity = identity
		if err := gate.load(); err != nil {
			t.Fatal(err)
		}
		deadline := clock.now().Add(gate.crashRetryDelay())
		if gate.rateLimited || gate.consecutiveFailures != 0 || !gate.nextAttemptAt.Equal(deadline) {
			t.Fatal("legacy synthetic guard was treated as real rate-limit evidence")
		}
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var migrated controlPlaneRetryState
		if err := json.Unmarshal(data, &migrated); err != nil {
			t.Fatal(err)
		}
		if migrated.NextAttemptAt != deadline.Format(time.RFC3339) ||
			migrated.ConsecutiveFailures != 0 || migrated.CredentialIdentity != identity {
			t.Fatalf("migration did not durably preserve the bounded identity: %#v", migrated)
		}
		for restart := 0; restart < 3; restart++ {
			clock.advance(10 * time.Second)
			gate = newControlPlaneRateGate(path, "profile-a", clock)
			gate.credentialIdentity = identity
			if err := gate.load(); err != nil {
				t.Fatal(err)
			}
			if !gate.nextAttemptAt.Equal(deadline) {
				t.Fatal("repeated restart extended the migrated deadline")
			}
		}
		clock.advance(deadline.Sub(clock.now()))
		if err := gate.before(); err != nil {
			t.Fatalf("migrated guard did not expire: %v", err)
		}
		if err := gate.after(nil); err != nil {
			t.Fatal(err)
		}
	}

	func TestControlPlaneMigrationPreservesPositiveFailureCooldowns(t *testing.T) {
		for failures := 1; failures <= 3; failures++ {
			path := newStatePaths(projectTestDirectory(t)).controlPlane
			clock := &fakeClock{current: time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)}
			deadline := clock.now().Add(registrationAccessNextDelay("profile-a", failures, true))
			state := controlPlaneRetryState{
				SchemaVersion: 1, ManagerContractVersion: managerContractVersion,
				ProfileID: "profile-a", CredentialIdentity: "app:example",
				ConsecutiveFailures: failures, NextAttemptAt: deadline.Format(time.RFC3339),
			}
			if err := writeJSONAtomically(path, state); err != nil {
				t.Fatal(err)
			}
			before, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			gate := newControlPlaneRateGate(path, "profile-a", clock)
			gate.credentialIdentity = state.CredentialIdentity
			if err := gate.load(); err != nil {
				t.Fatal(err)
			}
			after, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if string(before) != string(after) || !gate.rateLimited ||
				gate.consecutiveFailures != failures || !gate.nextAttemptAt.Equal(deadline) {
				t.Fatal("migration changed genuine rate-limit evidence")
			}
			var blocked controlPlaneBackoffError
			if err := gate.before(); !errors.As(err, &blocked) {
				t.Fatalf("positive-failure cooldown was bypassed: %v", err)
			}
		}
	}

	func TestControlPlaneLoadDoesNotExtendShortOrExpiredSyntheticGuard(t *testing.T) {
		for _, remaining := range []time.Duration{-time.Second, 10 * time.Second} {
			path := newStatePaths(projectTestDirectory(t)).controlPlane
			clock := &fakeClock{current: time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)}
			deadline := clock.now().Add(remaining)
			state := controlPlaneRetryState{
				SchemaVersion: 1, ManagerContractVersion: managerContractVersion,
				ProfileID: "profile-a", NextAttemptAt: deadline.Format(time.RFC3339),
			}
			if err := writeJSONAtomically(path, state); err != nil {
				t.Fatal(err)
			}
			gate := newControlPlaneRateGate(path, "profile-a", clock)
			if err := gate.load(); err != nil {
				t.Fatal(err)
			}
			if !gate.nextAttemptAt.Equal(deadline) {
				t.Fatal("loading a short or expired guard extended its deadline")
			}
		}
	}

	func TestControlPlaneMigrationRejectsIncompatibleState(t *testing.T) {
		for _, mutate := range []func(*controlPlaneRetryState){
			func(state *controlPlaneRetryState) { state.ProfileID = "another-profile" },
			func(state *controlPlaneRetryState) { state.SchemaVersion = 2 },
			func(state *controlPlaneRetryState) { state.ConsecutiveFailures = -1 },
			func(state *controlPlaneRetryState) { state.NextAttemptAt = "invalid" },
		} {
			path := newStatePaths(projectTestDirectory(t)).controlPlane
			clock := &fakeClock{current: time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)}
			state := controlPlaneRetryState{
				SchemaVersion: 1, ManagerContractVersion: managerContractVersion,
				ProfileID: "profile-a", NextAttemptAt: clock.now().Add(time.Hour).Format(time.RFC3339),
			}
			mutate(&state)
			if err := writeJSONAtomically(path, state); err != nil {
				t.Fatal(err)
			}
			before, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			gate := newControlPlaneRateGate(path, "profile-a", clock)
			if err := gate.load(); err == nil {
				t.Fatal("migration accepted incompatible state")
			}
			after, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if string(before) != string(after) {
				t.Fatal("migration rewrote incompatible state")
			}
		}
	}

	func TestControlPlaneOverlappingOperationsRetainGuardUntilLastCompletion(t *testing.T) {
		for _, rateLimited := range []bool{false, true} {
			path := newStatePaths(projectTestDirectory(t)).controlPlane
			clock := &fakeClock{current: time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)}
			gate := newControlPlaneRateGate(path, "profile-a", clock)
			service := &pacedScaleSetService{gate: gate}
			started := make(chan struct{}, 2)
			release := []chan struct{}{make(chan struct{}), make(chan struct{})}
			results := []chan error{make(chan error, 1), make(chan error, 1)}
			for index := range release {
				go func(index int) {
					results[index] <- service.run(context.Background(), func() error {
						started <- struct{}{}
						<-release[index]
						if index == 1 {
							return context.Canceled
						}
						return nil
					})
				}(index)
			}
			for range release {
				select {
				case <-started:
				case <-time.After(time.Second):
					t.Fatal("overlapping operation did not start")
				}
			}
			if rateLimited {
				if err := gate.observe(errors.New("API rate limit exceeded")); err != nil {
					t.Fatal(err)
				}
			}
			close(release[0])
			if err := <-results[0]; err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(path); err != nil {
				t.Fatalf("first completion removed a peer's durable guard: %v", err)
			}
			close(release[1])
			if err := <-results[1]; !errors.Is(err, context.Canceled) {
				t.Fatal(err)
			}
			if rateLimited {
				restarted := newControlPlaneRateGate(path, "profile-a", clock)
				if err := restarted.load(); err != nil {
					t.Fatal(err)
				}
				if !restarted.rateLimited || restarted.consecutiveFailures != 1 {
					t.Fatal("successful/canceled peers erased observed rate-limit evidence")
				}
			} else if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("last ordinary completion retained synthetic guard: %v", err)
			}
		}
	}

	func TestControlPlanePersistenceErrorsAreReturned(t *testing.T) {
		directory := projectTestDirectory(t)
		parent := filepath.Join(directory, "not-a-directory")
		if err := os.WriteFile(parent, []byte("fixture"), 0o600); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(parent, "retry.json")
		clock := &fakeClock{current: time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)}
		gate := newControlPlaneRateGate(path, "profile-a", clock)
		service := &pacedScaleSetService{gate: gate}
		called := false
		if err := service.run(context.Background(), func() error {
			called = true
			return nil
		}); err == nil || called {
			t.Fatalf("failed precommit reached API: called=%t err=%v", called, err)
		}
		gate = newControlPlaneRateGate("", "profile-a", clock)
		service.gate = gate
		rateErr := errors.New("API rate limit exceeded")
		err := service.run(context.Background(), func() error {
			gate.path = path
			return rateErr
		})
		var storageErr *os.PathError
		if !errors.Is(err, rateErr) || !errors.As(err, &storageErr) || !gate.rateLimited {
			t.Fatalf("rate-limit persistence failure was hidden: %v", err)
		}
		inner := newFakeMessageSession()
		inner.getError = rateErr
		session := &pacedMessageSession{inner: inner, gate: gate}
		if _, err := session.GetMessage(context.Background(), 0, 1); !errors.As(err, &storageErr) {
			t.Fatalf("message-session persistence failure was hidden: %v", err)
		}
	}

	func TestControlPlaneClearFailureIsReturnedWithoutHourlyFallback(t *testing.T) {
		path := newStatePaths(projectTestDirectory(t)).controlPlane
		clock := &fakeClock{current: time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)}
		gate := newControlPlaneRateGate(path, "profile-a", clock)
		service := &pacedScaleSetService{gate: gate}
		err := service.run(context.Background(), func() error {
			if err := os.Remove(path); err != nil {
				return err
			}
			if err := os.Mkdir(path, 0o700); err != nil {
				return err
			}
			return os.WriteFile(filepath.Join(path, "retained"), []byte("fixture"), 0o600)
		})
		if err == nil {
			t.Fatal("retry-state removal failure was hidden")
		}
		if gate.nextAttemptAt.Sub(clock.now()) != gate.crashRetryDelay() {
			t.Fatal("clear failure fabricated an hourly cooldown")
		}
	}
	if _, err := service.ensureScaleSet(
		context.Background(),
		"healthy-target",
		"",
		nil,
	); err != nil {
		t.Fatalf("indeterminate peer failure blocked healthy progress: %v", err)
	}
}

func TestMessageSessionRateLimitActivatesControlPlaneGate(t *testing.T) {
	clock := &fakeClock{current: time.Now().UTC()}
	gate := newControlPlaneRateGate("", "profile-a", clock)
	session := newFakeMessageSession()
	session.getError = errors.New("API rate limit exceeded")
	paced := &pacedMessageSession{inner: session, gate: gate}
	if _, err := paced.GetMessage(context.Background(), 0, 1); err == nil {
		t.Fatal("rate-limited message poll succeeded")
	}
	if !gate.rateLimited ||
		gate.nextAttemptAt.Sub(clock.now()) < registrationAccessRateLimitBase {
		t.Fatalf(
			"message poll did not activate durable rate backoff: limited=%t retry=%s",
			gate.rateLimited,
			gate.nextAttemptAt,
		)
	}
	api := newFakeScaleSetService(nil)
	service := &pacedScaleSetService{inner: api, gate: gate}
	if _, err := service.ensureScaleSet(
		context.Background(),
		"scale-set",
		"",
		nil,
	); err == nil {
		t.Fatal("control-plane call bypassed message-session rate backoff")
	}
	if api.ensureCalls != 0 {
		t.Fatal("rate gate reached the underlying control-plane API")
	}
}
