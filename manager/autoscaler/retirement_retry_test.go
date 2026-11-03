package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"testing"
	"time"
)

type retirementLookupService struct {
	scaleSetService
	calls int
	err   error
}

func (s *retirementLookupService) findScaleSet(
	ctx context.Context,
	name, group string,
) (scaleSetHandle, bool, error) {
	s.calls++
	if s.err != nil {
		return scaleSetHandle{}, false, s.err
	}
	return s.scaleSetService.findScaleSet(ctx, name, group)
}

type retirementLookupFactory struct {
	scaleSetServiceFactory
	url     string
	service scaleSetService
}

func (f retirementLookupFactory) newService(url string) (scaleSetService, error) {
	if url == f.url {
		return f.service, nil
	}
	return f.scaleSetServiceFactory.newService(url)
}

func TestRetirementLookupFailureIsDurablyPacedWithoutBlockingDesiredTargets(t *testing.T) {
	directory := projectTestDirectory(t)
	cfg := managerTestConfig(directory)
	current := parseDesiredForTest(t, "repo", `{
	  "schemaVersion":1,"generation":2,"scope":"repo",
	  "repositories":[{"url":"https://github.com/example/current","workers":1}],
	  "replicas":null
	}`)
	removed := targetSpec{
		key:             "removed-target",
		registrationURL: "https://github.com/example/previous",
		repository:      "https://github.com/example/previous",
		maximum:         1,
		scaleSetName:    "pitcrew-profile-a-previous",
	}
	service := newFakeScaleSetService(nil)
	service.scaleSetExists = false
	lookup := &retirementLookupService{
		scaleSetService: service,
		err:             errors.New("registration-token request returned 404 Not Found"),
	}
	factory := retirementLookupFactory{
		scaleSetServiceFactory: newFakeScaleSetServiceFactory(),
		url:                   removed.registrationURL,
		service:               lookup,
	}
	clock := &fakeClock{current: time.Date(2026, 11, 3, 6, 0, 0, 0, time.UTC)}
	manager := newAutoscalerManager(cfg, factory, newFakeDockerClient(nil), clock, testLogger(), "before")
	manager.current = &current
	manager.retirementRecords[removed.key] = retirementRecordFor(removed, 2)
	if err := manager.reconcileRetirements(context.Background()); err == nil {
		t.Fatal("lookup failure was hidden")
	}
	for range 59 {
		clock.advance(time.Second)
		if err := manager.reconcileRetirements(context.Background()); err == nil {
			t.Fatal("pending failed retirement was reported healthy")
		}
	}
	if lookup.calls != 1 {
		t.Fatalf("one-second reconciliation made %d failed API calls, want 1", lookup.calls)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := manager.reconcileDesiredTargets(ctx); err != nil {
		t.Fatalf("failed retirement blocked healthy desired targets: %v", err)
	}
	closeControllersForTest(t, manager)

	restarted := newAutoscalerManager(cfg, factory, newFakeDockerClient(nil), clock, testLogger(), "after")
	restarted.current = &current
	if err := restarted.loadRetirements(); err != nil {
		t.Fatal(err)
	}
	if err := restarted.reconcileRetirements(context.Background()); err == nil {
		t.Fatal("restart discarded failure evidence")
	}
	if lookup.calls != 1 {
		t.Fatal("manager restart bypassed persisted retry deadline")
	}
	clock.advance(time.Second)
	if err := restarted.reconcileRetirements(context.Background()); err == nil {
		t.Fatal("second lookup failure was hidden")
	}
	if lookup.calls != 2 {
		t.Fatalf("expired retry made %d calls, want 2", lookup.calls)
	}
	record := restarted.retirementRecords[removed.key]
	retryAt, err := time.Parse(time.RFC3339, record.StartupRetryAt)
	if err != nil {
		t.Fatal(err)
	}
	if record.StartupAttempts != 2 || retryAt.Sub(clock.now()) != 2*time.Minute {
		t.Fatal("repeated failure did not increase durable backoff")
	}
	lookup.err = nil
	clock.advance(2 * time.Minute)
	if err := restarted.reconcileRetirementsWithFinalization(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	if restarted.retirementRecords[removed.key].StartupAttempts != 0 {
		t.Fatal("successful absence lookup retained a failed-start retry")
	}
	if err := restarted.reconcileRetirements(context.Background()); err != nil {
		t.Fatal(err)
	}
	if lookup.calls != 4 || len(restarted.retirementRecords) != 0 || service.ensureCalls != 0 {
		t.Fatal("authoritatively absent scale set did not retire without recreation")
	}
}

func TestRetirementRetryPrecommitFailureDoesNotReachGitHub(t *testing.T) {
	directory := projectTestDirectory(t)
	factory := newFakeScaleSetServiceFactory()
	manager := newAutoscalerManager(
		managerTestConfig(directory), factory,
		newFakeDockerClient(nil), &fakeClock{current: time.Now().UTC()}, testLogger(), "instance",
	)
	current := parseDesiredForTest(t, "repo", `{
	  "schemaVersion":1,"generation":2,"scope":"repo",
	  "repositories":[{"url":"https://github.com/example/current","workers":1}],
	  "replicas":null
	}`)
	manager.current = &current
	manager.retirementRecords["removed"] = retirementRecord{
		Key: "removed", RegistrationURL: "https://github.com/example/previous",
		Repository: "https://github.com/example/previous", Maximum: 1,
		ScaleSetName: "previous", RetireAtGeneration: 2,
	}
	if err := os.Mkdir(manager.paths.retirements, 0700); err != nil {
		t.Fatal(err)
	}
	if err := manager.reconcileRetirements(context.Background()); err == nil {
		t.Fatal("failed durable retry precommit was hidden")
	}
	if len(factory.services) != 0 {
		t.Fatal("retirement contacted GitHub without a durable retry fence")
	}
}

func TestRetirementRetryStateRejectsInvalidDeadlines(t *testing.T) {
	record := retirementRecord{
		Key: "removed", RegistrationURL: "https://github.com/example/previous",
		Maximum: 1, ScaleSetName: "previous", RetireAtGeneration: 2,
	}
	for _, invalid := range []struct {
		attempts int
		retryAt  string
	}{
		{attempts: -1},
		{attempts: 1},
		{retryAt: "2026-11-03T06:00:00Z"},
		{attempts: 1, retryAt: "invalid"},
	} {
		candidate := record
		candidate.StartupAttempts = invalid.attempts
		candidate.StartupRetryAt = invalid.retryAt
		data, err := json.Marshal(newRetirementDocument(2, map[string]retirementRecord{"removed": candidate}))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := parseRetirementDocument(data); err == nil {
			t.Fatal("invalid retirement retry state was accepted")
		}
	}
}
