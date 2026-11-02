package main

import (
	"context"
	"errors"
	"os"
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

func TestControlPlanePrecommitIsConservative(t *testing.T) {
	clock := &fakeClock{
		current: time.Date(2026, 11, 2, 4, 0, 0, 0, time.UTC),
	}
	gate := newControlPlaneRateGate("", "profile-a", clock)
	if err := gate.before(); err != nil {
		t.Fatal(err)
	}
	expected := clock.now().Add(
		registrationAccessNextDelay("profile-a", 0, false),
	)
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

func TestControlPlaneIndeterminateFailureRetainsCrashFence(t *testing.T) {
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
	if err := restarted.before(); err == nil {
		t.Fatal("restart bypassed the durable crash fence")
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
