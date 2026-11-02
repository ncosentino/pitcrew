package main

import (
	"context"
	"io"
	"log/slog"
	"testing"
	"time"
)

func forceRegistrationAccessDue(manager *autoscalerManager) {
	manager.registrationAccessHealth.nextCheckAt = time.Time{}
}

func TestRegistrationAccessHealthPersistsUntilSuccessfulProbe(t *testing.T) {
	clock := &fakeClock{current: time.Date(2026, 8, 30, 12, 0, 0, 0, time.UTC)}
	manager := newAutoscalerManager(
		managerTestConfig(projectTestDirectory(t)),
		newFakeScaleSetServiceFactory(),
		newFakeDockerClient(nil),
		clock,
		slog.New(slog.NewTextHandler(io.Discard, nil)),
		"manager-test",
	)
	api := newFakeScaleSetService(nil)
	api.registrationAccessErrors = []error{errGitHubRunnerAuthorization, nil}
	manager.controllers["target"] = &targetController{
		target: targetSpec{key: "target"},
		api:    api,
	}

	forceRegistrationAccessDue(manager)
	manager.checkRegistrationAccessIfDue(context.Background())
	if api.registrationAccessCalls != 1 {
		t.Fatalf("access checks = %d, want 1", api.registrationAccessCalls)
	}
	health := manager.diagnostics.subsystemHealth()
	manager.applyRegistrationAccessHealth(&health)
	if health.GitHub.State != subsystemDegraded {
		t.Fatalf("GitHub health = %q, want %q", health.GitHub.State, subsystemDegraded)
	}
	if health.GitHub.LastFailure == nil ||
		health.GitHub.LastFailure.Reason != reasonAuthorizationFailed {
		t.Fatalf("GitHub failure = %#v, want authorization failure", health.GitHub.LastFailure)
	}

	manager.diagnostics.record(diagnosticsObservation{
		subsystem:  subsystemSession,
		operation:  operationMessagePoll,
		outcome:    outcomeSucceeded,
		reason:     reasonNone,
		healthKind: healthGitHub,
	})
	health = manager.diagnostics.subsystemHealth()
	manager.applyRegistrationAccessHealth(&health)
	if health.GitHub.State != subsystemDegraded {
		t.Fatal("an unrelated GitHub success concealed the credential failure")
	}

	retryAt := manager.registrationAccessHealth.nextCheckAt
	clock.current = retryAt.Add(-time.Second)
	manager.checkRegistrationAccessIfDue(context.Background())
	if api.registrationAccessCalls != 1 {
		t.Fatal("credential health check ran before its bounded cadence")
	}

	clock.advance(time.Second)
	manager.checkRegistrationAccessIfDue(context.Background())
	if api.registrationAccessCalls != 2 {
		t.Fatalf("access checks = %d, want 2", api.registrationAccessCalls)
	}
	health = manager.diagnostics.subsystemHealth()
	manager.applyRegistrationAccessHealth(&health)
	if health.GitHub.State != subsystemHealthy {
		t.Fatalf("GitHub health after recovery = %q, want %q", health.GitHub.State, subsystemHealthy)
	}

	journal := manager.diagnostics.journal()
	foundRecovery := false
	for _, event := range journal.Events {
		if event.Operation == operationRegistrationTokenCall &&
			event.Outcome == outcomeRecovered {
			foundRecovery = true
		}
	}
	if !foundRecovery {
		t.Fatal("credential authorization recovery was not journaled")
	}
}

func TestRegistrationAccessHealthAggregatesMultipleTargets(t *testing.T) {
	clock := &fakeClock{current: time.Date(2026, 8, 30, 12, 0, 0, 0, time.UTC)}
	manager := newAutoscalerManager(
		managerTestConfig(projectTestDirectory(t)),
		newFakeScaleSetServiceFactory(),
		newFakeDockerClient(nil),
		clock,
		slog.New(slog.NewTextHandler(io.Discard, nil)),
		"manager-test",
	)
	authorized := newFakeScaleSetService(nil)
	forbidden := newFakeScaleSetService(nil)
	forbidden.registrationAccessErrors = []error{errGitHubRunnerAuthorization}
	manager.controllers["authorized"] = &targetController{
		target: targetSpec{key: "authorized"},
		api:    authorized,
	}
	manager.controllers["forbidden"] = &targetController{
		target: targetSpec{key: "forbidden"},
		api:    forbidden,
	}

	forceRegistrationAccessDue(manager)
	manager.checkRegistrationAccessIfDue(context.Background())
	health := manager.diagnostics.subsystemHealth()
	manager.applyRegistrationAccessHealth(&health)
	if health.GitHub.State != subsystemDegraded ||
		health.GitHub.LastFailure == nil ||
		health.GitHub.LastFailure.Reason != reasonAuthorizationFailed {
		t.Fatalf("aggregated GitHub health = %#v", health.GitHub)
	}
	if authorized.jitCallCount() != 0 || forbidden.jitCallCount() != 0 {
		t.Fatal("credential health probe changed runner demand")
	}
}

func TestRegistrationAccessHealthBecomesUnavailableAfterRepeatedFailures(t *testing.T) {
	clock := &fakeClock{current: time.Date(2026, 8, 30, 12, 0, 0, 0, time.UTC)}
	manager := newAutoscalerManager(
		managerTestConfig(projectTestDirectory(t)),
		newFakeScaleSetServiceFactory(),
		newFakeDockerClient(nil),
		clock,
		slog.New(slog.NewTextHandler(io.Discard, nil)),
		"manager-test",
	)
	api := newFakeScaleSetService(nil)
	api.registrationAccessErrors = []error{
		errGitHubRunnerAuthorization,
		errGitHubRunnerAuthorization,
		errGitHubRunnerAuthorization,
	}
	manager.controllers["target"] = &targetController{
		target: targetSpec{key: "target"},
		api:    api,
	}

	for attempt := 0; attempt < subsystemFailureBand; attempt++ {
		forceRegistrationAccessDue(manager)
		manager.checkRegistrationAccessIfDue(context.Background())
	}
	health := manager.diagnostics.subsystemHealth()
	manager.applyRegistrationAccessHealth(&health)
	if health.GitHub.State != subsystemUnavailable {
		t.Fatalf("GitHub health = %q, want %q", health.GitHub.State, subsystemUnavailable)
	}
	if health.GitHub.ConsecutiveFailures != subsystemFailureBand {
		t.Fatalf(
			"consecutive failures = %d, want %d",
			health.GitHub.ConsecutiveFailures,
			subsystemFailureBand,
		)
	}
}

func TestRegistrationAccessHealthChecksAcceptedTargetWithoutController(t *testing.T) {
	clock := &fakeClock{current: time.Date(2026, 8, 30, 12, 0, 0, 0, time.UTC)}
	factory := newFakeScaleSetServiceFactory()
	manager := newAutoscalerManager(
		managerTestConfig(projectTestDirectory(t)),
		factory,
		newFakeDockerClient(nil),
		clock,
		slog.New(slog.NewTextHandler(io.Discard, nil)),
		"manager-test",
	)
	manager.current = &parsedDesiredState{
		state: desiredState{
			SchemaVersion: 1,
			Generation:    1,
			Scope:         "repo",
			Repositories: []desiredRepository{{
				URL:     "https://github.com/example/repository",
				Workers: 0,
			}},
		},
	}
	targets, err := buildTargetSpecs(manager.current.state, manager.cfg)
	if err != nil {
		t.Fatal(err)
	}
	api := newFakeScaleSetService(nil)
	api.registrationAccessErrors = []error{errGitHubRunnerPermissionDenied}
	factory.services[targets[0].registrationURL] = api

	forceRegistrationAccessDue(manager)
	manager.checkRegistrationAccessIfDue(context.Background())
	if api.registrationAccessCalls != 1 {
		t.Fatalf("access checks = %d, want 1", api.registrationAccessCalls)
	}
	health := manager.diagnostics.subsystemHealth()
	manager.applyRegistrationAccessHealth(&health)
	if health.GitHub.State != subsystemDegraded ||
		health.GitHub.LastFailure == nil ||
		health.GitHub.LastFailure.Reason != reasonAuthorizationFailed {
		t.Fatalf("accepted target health = %#v", health.GitHub)
	}
}

func TestRegistrationAccessScheduleIsStaggeredAndBounded(t *testing.T) {
	first := registrationAccessFirstCheckDelay("automation-control")
	second := registrationAccessFirstCheckDelay("default")
	if first < registrationAccessInitialDelay ||
		first >= registrationAccessInitialDelay+registrationAccessJitterWindow {
		t.Fatalf("first delay = %s, outside initial jitter window", first)
	}
	if second < registrationAccessInitialDelay ||
		second >= registrationAccessInitialDelay+registrationAccessJitterWindow {
		t.Fatalf("second delay = %s, outside initial jitter window", second)
	}
	if first == second {
		t.Fatalf("distinct profiles received identical initial delay %s", first)
	}
	if first != registrationAccessFirstCheckDelay("automation-control") {
		t.Fatal("profile jitter is not deterministic")
	}
}

func TestRegistrationAccessNextDelayBacksOffRateLimits(t *testing.T) {
	jitter := registrationAccessJitter("image-builder")
	tests := []struct {
		failures    int
		rateLimited bool
		expected    time.Duration
	}{
		{failures: 0, expected: registrationAccessSuccessInterval + jitter},
		{failures: 1, expected: registrationAccessFailureInterval + jitter},
		{
			failures:    1,
			rateLimited: true,
			expected:    registrationAccessRateLimitBase + jitter,
		},
		{
			failures:    2,
			rateLimited: true,
			expected:    2*registrationAccessRateLimitBase + jitter,
		},
		{
			failures:    3,
			rateLimited: true,
			expected:    registrationAccessMaxBackoff + jitter,
		},
		{
			failures:    20,
			rateLimited: true,
			expected:    registrationAccessMaxBackoff + jitter,
		},
	}
	for _, test := range tests {
		actual := registrationAccessNextDelay(
			"image-builder",
			test.failures,
			test.rateLimited,
		)
		if actual != test.expected {
			t.Fatalf(
				"failures=%d rateLimited=%t delay=%s, want %s",
				test.failures,
				test.rateLimited,
				actual,
				test.expected,
			)
		}
	}
}

func TestRegistrationAccessDeadlineSurvivesManagerRestart(t *testing.T) {
		directory := projectTestDirectory(t)
		cfg := managerTestConfig(directory)
		clock := &fakeClock{
			current: time.Date(2026, 8, 30, 12, 0, 0, 0, time.UTC),
		}
		manager := newAutoscalerManager(
			cfg,
			newFakeScaleSetServiceFactory(),
			newFakeDockerClient(nil),
			clock,
			slog.New(slog.NewTextHandler(io.Discard, nil)),
			"manager-first",
		)
		api := newFakeScaleSetService(nil)
		api.registrationAccessErrors = []error{errGitHubRunnerRateLimited}
		manager.controllers["target"] = &targetController{
			target: targetSpec{key: "target"},
			api:    api,
		}
		forceRegistrationAccessDue(manager)
		manager.checkRegistrationAccessIfDue(context.Background())
		if api.registrationAccessCalls != 1 {
			t.Fatalf("initial access calls = %d, want 1", api.registrationAccessCalls)
		}
		retryAt := manager.registrationAccessHealth.nextCheckAt

		restarted := newAutoscalerManager(
			cfg,
			newFakeScaleSetServiceFactory(),
			newFakeDockerClient(nil),
			clock,
			slog.New(slog.NewTextHandler(io.Discard, nil)),
			"manager-restarted",
		)
		restartedAPI := newFakeScaleSetService(nil)
		restarted.controllers["target"] = &targetController{
			target: targetSpec{key: "target"},
			api:    restartedAPI,
		}
		if err := restarted.loadRegistrationAccessRetry(); err != nil {
			t.Fatal(err)
		}
		restarted.checkRegistrationAccessIfDue(context.Background())
		if restartedAPI.registrationAccessCalls != 0 {
			t.Fatal("manager restart bypassed registration access backoff")
		}

		clock.advance(retryAt.Sub(clock.now()))
		restarted.checkRegistrationAccessIfDue(context.Background())
		if restartedAPI.registrationAccessCalls != 1 {
			t.Fatal("registration access did not resume at persisted deadline")
	}
}
