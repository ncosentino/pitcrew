package main

import (
	"context"
	"io"
	"log/slog"
	"testing"
	"time"
)

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

	clock.advance(registrationAccessCheckInterval - time.Second)
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
		manager.checkRegistrationAccessIfDue(context.Background())
		clock.advance(registrationAccessCheckInterval)
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
