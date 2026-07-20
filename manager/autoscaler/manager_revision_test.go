package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

func TestDurableRetirementReloadsRemovedBusyTarget(t *testing.T) {
	directory := projectTestDirectory(t)
	cfg := managerTestConfig(directory)
	previous := parseDesiredForTest(t, "repo", `{
	  "schemaVersion":1,
	  "generation":1,
	  "scope":"repo",
	  "repositories":[
	    {"url":"https://github.com/example/one","workers":1},
	    {"url":"https://github.com/example/two","workers":1}
	  ],
	  "replicas":null
	}`)
	next := parseDesiredForTest(t, "repo", `{
	  "schemaVersion":1,
	  "generation":2,
	  "scope":"repo",
	  "repositories":[
	    {"url":"https://github.com/example/two","workers":1}
	  ],
	  "replicas":null
	}`)
	clock := &fakeClock{current: time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)}
	manager := newAutoscalerManager(
		cfg,
		newFakeScaleSetServiceFactory(),
		newFakeDockerClient(nil),
		clock,
		testLogger(),
		"instance-one",
	)
	manager.current = &previous
	if err := manager.acceptDesiredTransition(
		context.Background(),
		next,
		"generation-two-document",
	); err != nil {
		t.Fatal(err)
	}

	documentData, err := os.ReadFile(manager.paths.retirements)
	if err != nil {
		t.Fatal(err)
	}
	document, err := parseRetirementDocument(documentData)
	if err != nil {
		t.Fatal(err)
	}
	if document.Generation != 2 || len(document.Targets) != 1 {
		t.Fatalf("retirement intent was not durably recorded: %#v", document)
	}
	if err := manager.publishAcknowledgement(); err == nil {
		t.Fatal("missing desired controller was acknowledged")
	}
	if _, err := os.Stat(manager.paths.acknowledgement); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("acknowledgement was written before desired controllers were live")
	}

	previousTargets, err := buildTargetSpecs(previous.state, cfg)
	if err != nil {
		t.Fatal(err)
	}
	removed := previousTargets[0]
	docker := newFakeDockerClient(nil)
	docker.recovered = []recoveredContainer{{
		containerID: "recovered-container",
		name:        "recovered-container",
		runnerName:  "recovered-runner",
		runnerID:    77,
		targetKey:   removed.key,
		slotKey:     removed.key + "-77",
		createdAt:   clock.now().Add(-time.Minute),
	}}
	docker.logs["recovered-container"] = []string{"Running job: build"}
	factory := newFakeScaleSetServiceFactory()
	restarted := newAutoscalerManager(
		cfg,
		factory,
		docker,
		clock,
		testLogger(),
		"instance-two",
	)
	if err := restarted.scanRecovered(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := restarted.restoreLastValid(); err != nil {
		t.Fatal(err)
	}
	if err := restarted.loadRetirements(); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := restarted.reconcileDesiredTargets(ctx); err != nil {
		t.Fatal(err)
	}
	if err := restarted.reconcileRetirements(ctx); err != nil {
		t.Fatal(err)
	}
	if err := restarted.publishAcknowledgement(); err != nil {
		t.Fatalf("acknowledge reconciled retirement: %v", err)
	}
	acknowledgementData, err := os.ReadFile(restarted.paths.acknowledgement)
	if err != nil {
		t.Fatal(err)
	}
	var ack acknowledgement
	if err := json.Unmarshal(acknowledgementData, &ack); err != nil {
		t.Fatal(err)
	}
	if ack.Generation != 2 || ack.DesiredSlots != 1 {
		t.Fatalf("unexpected retirement acknowledgement: %#v", ack)
	}
	retiring := restarted.retiring[removed.key]
	if retiring == nil {
		t.Fatal("removed target was not restored as a retiring controller")
	}
	snapshot := retiring.snapshot()
	if !snapshot.retiring || snapshot.target.maximum != 0 ||
		len(snapshot.runners) != 1 || snapshot.runners[0].state != runnerBusy {
		t.Fatalf("reloaded retirement did not preserve the busy runner: %#v", snapshot)
	}
	service := fakeServiceForURL(t, factory, removed.registrationURL)
	if len(service.removeCalls) != 0 || len(docker.stopRemove) != 0 ||
		len(service.deletedScaleSet) != 0 {
		t.Fatal("busy retirement removed a runner, container, or scale set")
	}

	runner := snapshot.runners[0]
	if err := retiring.scaler.HandleJobCompleted(
		context.Background(),
		&scaleset.JobCompleted{
			RunnerID:   int(runner.runnerID),
			RunnerName: runner.runnerName,
		},
	); err != nil {
		t.Fatal(err)
	}
	retiring.scaler.handleContainerExit(runner.containerID, 0)
	if err := restarted.reconcileRetirements(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, exists := restarted.retirementRecords[removed.key]; exists {
		t.Fatal("completed retirement was not removed from durable state")
	}
	if len(service.deletedScaleSet) != 1 {
		t.Fatalf("scale set was not deleted after runner count reached zero: %#v", service.deletedScaleSet)
	}

	cancel()
	closeControllersForTest(t, restarted)
}

func TestAcknowledgementWaitsForDurableRetirementIntent(t *testing.T) {
	directory := projectTestDirectory(t)
	cfg := managerTestConfig(directory)
	previous := parseDesiredForTest(t, "repo", `{
	  "schemaVersion":1,
	  "generation":1,
	  "scope":"repo",
	  "repositories":[
	    {"url":"https://github.com/example/one","workers":1},
	    {"url":"https://github.com/example/two","workers":1}
	  ],
	  "replicas":null
	}`)
	next := parseDesiredForTest(t, "repo", `{
	  "schemaVersion":1,
	  "generation":2,
	  "scope":"repo",
	  "repositories":[{"url":"https://github.com/example/two","workers":1}],
	  "replicas":null
	}`)
	manager := newAutoscalerManager(
		cfg,
		newFakeScaleSetServiceFactory(),
		newFakeDockerClient(nil),
		&fakeClock{current: time.Now()},
		testLogger(),
		"instance",
	)
	manager.current = &previous
	blockedPath := filepath.Join(directory, "retirement-is-a-directory")
	if err := os.Mkdir(blockedPath, 0o755); err != nil {
		t.Fatal(err)
	}
	manager.paths.retirements = blockedPath

	if err := manager.acceptDesiredTransition(
		context.Background(),
		next,
		"generation-two-document",
	); err == nil {
		t.Fatal("expected retirement persistence to fail")
	}
	if manager.current.state.Generation != 1 || manager.ackPending {
		t.Fatal("failed retirement persistence advanced the accepted generation")
	}
	if err := manager.publishAcknowledgement(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(manager.paths.acknowledgement); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("generation was acknowledged without durable retirement intent")
	}
}

func TestRetirementControllerIsRetainedAndRetriedAfterRemovalError(t *testing.T) {
	directory := projectTestDirectory(t)
	cfg := managerTestConfig(directory)
	current := parseDesiredForTest(t, "repo", `{
	  "schemaVersion":1,
	  "generation":2,
	  "scope":"repo",
	  "repositories":[{"url":"https://github.com/example/two","workers":1}],
	  "replicas":null
	}`)
	removed := targetSpec{
		key:             "removed-target",
		registrationURL: "https://github.com/example/one",
		repository:      "https://github.com/example/one",
		maximum:         1,
		scaleSetName:    "pitcrew-profile-a-removed",
	}
	factory := newFakeScaleSetServiceFactory()
	service := newFakeScaleSetService(nil)
	service.removeErrors[77] = errors.New("temporary registration failure")
	factory.services[removed.registrationURL] = service
	docker := newFakeDockerClient(nil)
	docker.recovered = []recoveredContainer{{
		containerID: "recovered-container",
		name:        "recovered-container",
		runnerName:  "recovered-runner",
		runnerID:    77,
		targetKey:   removed.key,
		slotKey:     removed.key + "-77",
		createdAt:   time.Now().Add(-time.Minute),
	}}
	docker.logs["recovered-container"] = []string{"Listening for Jobs"}
	manager := newAutoscalerManager(
		cfg,
		factory,
		docker,
		&fakeClock{current: time.Now()},
		testLogger(),
		"instance",
	)
	manager.current = &current
	manager.retirementGeneration = current.state.Generation
	manager.retirementRecords[removed.key] = retirementRecordFor(
		removed,
		current.state.Generation,
	)
	if err := manager.persistRetirements(
		current.state.Generation,
		manager.retirementRecords,
	); err != nil {
		t.Fatal(err)
	}
	if err := manager.scanRecovered(context.Background()); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := manager.reconcileRetirements(ctx); err == nil {
		t.Fatal("expected the first runner removal to fail")
	}
	controller := manager.retiring[removed.key]
	if controller == nil || controller.runnerCount() != 1 {
		t.Fatal("failed retirement controller was forgotten instead of retained")
	}
	if len(docker.stopRemove) != 0 ||
		len(manager.retirementRecords) != 1 {
		t.Fatal("failed API removal advanced destructive retirement")
	}

	service.removeErrors[77] = nil
	if err := manager.reconcileRetirements(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(manager.retirementRecords) != 0 ||
		len(service.deletedScaleSet) != 1 {
		t.Fatal("retirement did not complete after the transient error cleared")
	}
	cancel()
	closeControllersForTest(t, manager)
}

func TestCompletedRetirementDoesNotRecreateMissingScaleSet(t *testing.T) {
	directory := projectTestDirectory(t)
	cfg := managerTestConfig(directory)
	current := parseDesiredForTest(t, "repo", `{
	  "schemaVersion":1,
	  "generation":2,
	  "scope":"repo",
	  "repositories":[{"url":"https://github.com/example/two","workers":1}],
	  "replicas":null
	}`)
	removed := targetSpec{
		key:             "removed-target",
		registrationURL: "https://github.com/example/one",
		repository:      "https://github.com/example/one",
		maximum:         1,
		scaleSetName:    "pitcrew-profile-a-removed",
	}
	factory := newFakeScaleSetServiceFactory()
	service := newFakeScaleSetService(nil)
	service.scaleSetExists = false
	factory.services[removed.registrationURL] = service
	manager := newAutoscalerManager(
		cfg,
		factory,
		newFakeDockerClient(nil),
		&fakeClock{current: time.Now()},
		testLogger(),
		"instance",
	)
	manager.current = &current
	manager.retirementGeneration = current.state.Generation
	manager.retirementRecords[removed.key] = retirementRecordFor(
		removed,
		current.state.Generation,
	)
	if err := manager.persistRetirements(
		current.state.Generation,
		manager.retirementRecords,
	); err != nil {
		t.Fatal(err)
	}

	if err := manager.reconcileRetirements(context.Background()); err != nil {
		t.Fatal(err)
	}
	if service.ensureCalls != 0 {
		t.Fatal("retirement recreated a scale set that was already absent")
	}
	if len(manager.retirementRecords) != 0 {
		t.Fatal("already-absent scale set did not complete retirement")
	}
}

func TestGracefulShutdownDeletesUnattachedRetiringScaleSet(t *testing.T) {
	directory := projectTestDirectory(t)
	cfg := managerTestConfig(directory)
	record := retirementRecordFor(targetSpec{
		key:             "removed-target",
		registrationURL: "https://github.com/example/one",
		repository:      "https://github.com/example/one",
		maximum:         1,
		scaleSetName:    "pitcrew-profile-a-removed",
	}, 2)
	factory := newFakeScaleSetServiceFactory()
	service := newFakeScaleSetService(nil)
	factory.services[record.RegistrationURL] = service
	manager := newAutoscalerManager(
		cfg,
		factory,
		newFakeDockerClient(nil),
		&fakeClock{current: time.Now()},
		testLogger(),
		"instance",
	)
	manager.retirementRecords[record.Key] = record
	manager.writeObserved = func(string, any) error { return nil }
	requestFullStop(t, manager)

	if err := manager.shutdown(); err != nil {
		t.Fatal(err)
	}
	if len(service.deletedScaleSet) != 1 {
		t.Fatal("graceful shutdown left an unattached retiring scale set")
	}
}

func TestManagerHandoffClosesSessionWithoutDestroyingPool(t *testing.T) {
	directory := projectTestDirectory(t)
	cfg := managerTestConfig(directory)
	service := newFakeScaleSetService(nil)
	session := newFakeMessageSession()
	service.sessionFactory = func() messageSession { return session }
	docker := newFakeDockerClient(nil)
	ctx := context.Background()
	controller, err := startTargetController(
		ctx,
		cfg,
		targetSpec{
			key:             "repo-one",
			registrationURL: "https://github.com/example/one",
			repository:      "https://github.com/example/one",
			maximum:         1,
			scaleSetName:    "pitcrew-profile-a-one",
		},
		service,
		service.ensureHandle,
		docker,
		&fakeClock{current: time.Now()},
		cfg.sessionOwner,
		[]recoveredContainer{{
			containerID: "live-container",
			name:        "live-container",
			runnerName:  "live-runner",
			runnerID:    77,
			targetKey:   "repo-one",
			slotKey:     "repo-one-77",
			revision:    testWorkerRevision,
			createdAt:   time.Now().Add(-time.Minute),
		}},
		testLogger(),
		nil,
		func(error) {},
		func(string, error) {},
	)
	if err != nil {
		t.Fatal(err)
	}
	manager := newAutoscalerManager(
		cfg,
		newFakeScaleSetServiceFactory(),
		docker,
		&fakeClock{current: time.Now()},
		testLogger(),
		"instance",
	)
	manager.controllers["repo-one"] = controller
	manager.writeObserved = func(string, any) error { return nil }

	if err := manager.shutdown(); err != nil {
		t.Fatal(err)
	}
	if session.closeCalls == 0 {
		t.Fatal("manager handoff did not close the scale-set session")
	}
	if len(docker.stopRemove) != 0 || len(docker.stops) != 0 ||
		len(service.deletedScaleSet) != 0 {
		t.Fatal("manager handoff destructively modified the worker pool")
	}
}

func TestListenerFailureCanRestartWithoutDestroyingPool(t *testing.T) {
	service := newFakeScaleSetService(nil)
	var sessionCount int
	service.sessionFactory = func() messageSession {
		sessionCount++
		session := newFakeMessageSession()
		if sessionCount == 1 {
			session.getError = errors.New("listener transport failed")
		}
		return session
	}
	docker := newFakeDockerClient(nil)
	failures := make(chan error, 1)
	ctx, cancel := context.WithCancel(context.Background())
	controller, err := startTargetController(
		ctx,
		managerTestConfig(projectTestDirectory(t)),
		targetSpec{
			key:             "repo-one",
			registrationURL: "https://github.com/example/one",
			repository:      "https://github.com/example/one",
			maximum:         1,
			scaleSetName:    "pitcrew-profile-a-one",
		},
		service,
		service.ensureHandle,
		docker,
		&fakeClock{current: time.Now()},
		"instance",
		nil,
		testLogger(),
		nil,
		func(error) {},
		func(_ string, err error) { failures <- err },
	)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-failures:
	case <-time.After(2 * time.Second):
		t.Fatal("listener failure was not reported")
	}
	if err := controller.restartListener(context.Background()); err != nil {
		t.Fatal(err)
	}
	if service.openSessionCalls != 2 {
		t.Fatalf("listener was not reopened: %d sessions", service.openSessionCalls)
	}
	if len(docker.stopRemove) != 0 || len(docker.stops) != 0 ||
		len(service.deletedScaleSet) != 0 {
		t.Fatal("listener failure destructively modified the pool")
	}
	cancel()
	closeControllerForTest(t, controller)
}

func TestOneTargetFailureDoesNotStopHealthyTarget(t *testing.T) {
	directory := projectTestDirectory(t)
	cfg := managerTestConfig(directory)
	current := parseDesiredForTest(t, "repo", `{
	  "schemaVersion":1,
	  "generation":1,
	  "scope":"repo",
	  "repositories":[
	    {"url":"https://github.com/example/failing","workers":1},
	    {"url":"https://github.com/example/healthy","workers":1}
	  ],
	  "replicas":null
	}`)
	targets, err := buildTargetSpecs(current.state, cfg)
	if err != nil {
		t.Fatal(err)
	}
	factory := newFakeScaleSetServiceFactory()
	failing := newFakeScaleSetService(nil)
	failing.ensureErrors = []error{errors.New("scale-set update failed")}
	healthy := newFakeScaleSetService(nil)
	healthy.ensureHandle = scaleSetHandle{id: 2, name: "healthy"}
	factory.services[targets[0].registrationURL] = failing
	factory.services[targets[1].registrationURL] = healthy
	docker := newFakeDockerClient(nil)
	manager := newAutoscalerManager(
		cfg,
		factory,
		docker,
		&fakeClock{current: time.Now()},
		testLogger(),
		"instance",
	)
	manager.current = &current
	manager.retirementGeneration = current.state.Generation
	manager.writeObserved = func(string, any) error { return nil }

	ctx, cancel := context.WithCancel(context.Background())
	manager.runReconciliationCycle(ctx)
	if manager.controllers[targets[1].key] == nil {
		t.Fatal("healthy target was not started after a peer target failed")
	}
	if manager.controllers[targets[0].key] != nil {
		t.Fatal("failing target unexpectedly started")
	}
	if len(docker.stopRemove) != 0 || len(docker.stops) != 0 ||
		len(healthy.deletedScaleSet) != 0 {
		t.Fatal("one target failure triggered destructive global cleanup")
	}
	cancel()
	closeControllersForTest(t, manager)
}

func TestFailedMaximumDecreaseKeepsPriorAppliedCapacitySnapshot(t *testing.T) {
	directory := projectTestDirectory(t)
	cfg := managerTestConfig(directory)
	cfg.minimumIdle = 5
	previous := parseDesiredForTest(t, "repo", `{
	  "schemaVersion":1,
	  "generation":1,
	  "scope":"repo",
	  "repositories":[
	    {"url":"https://github.com/example/one","workers":5}
	  ],
	  "replicas":null
	}`)
	next := parseDesiredForTest(t, "repo", `{
	  "schemaVersion":1,
	  "generation":2,
	  "scope":"repo",
	  "repositories":[
	    {"url":"https://github.com/example/one","workers":2}
	  ],
	  "replicas":null
	}`)
	factory := newFakeScaleSetServiceFactory()
	docker := newFakeDockerClient(nil)
	manager := newAutoscalerManager(
		cfg,
		factory,
		docker,
		&fakeClock{current: time.Now()},
		testLogger(),
		"instance",
	)
	manager.current = &previous
	manager.applied = &previous
	manager.retirementGeneration = previous.state.Generation
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := manager.reconcileDesiredTargets(ctx); err != nil {
		t.Fatal(err)
	}
	targets, err := buildTargetSpecs(previous.state, cfg)
	if err != nil {
		t.Fatal(err)
	}
	controller := manager.controllers[targets[0].key]
	if controller == nil {
		t.Fatal("initial controller was not started")
	}
	if _, err := controller.scaler.HandleDesiredRunnerCount(
		context.Background(),
		0,
	); err != nil {
		t.Fatal(err)
	}
	if controller.snapshot().targetSlots != 5 {
		t.Fatal("initial controller did not expose the prior maximum")
	}

	if err := manager.acceptDesiredTransition(
		context.Background(),
		next,
		"generation-two-document",
	); err != nil {
		t.Fatal(err)
	}
	service := fakeServiceForURL(t, factory, targets[0].registrationURL)
	service.ensureErrors = []error{errors.New("scale-set update failed")}
	var published observedState
	manager.writeObserved = func(_ string, value any) error {
		published = value.(observedState)
		return nil
	}

	manager.runReconciliationCycle(ctx)
	if manager.applied == nil || manager.applied.state.Generation != 1 {
		t.Fatal("failed decrease replaced the prior applied generation")
	}
	if published.Generation != 1 ||
		published.ConfiguredSlots != 5 ||
		published.DesiredSlots != 5 ||
		published.Autoscaling.TargetSlots != 5 ||
		published.Autoscaling.MaximumSlots != 5 {
		t.Fatalf("degraded snapshot committed the lower maximum: %#v", published)
	}
	if published.DesiredSlots != published.Autoscaling.TargetSlots ||
		published.Autoscaling.TargetSlots > published.Autoscaling.MaximumSlots {
		t.Fatalf("degraded snapshot violated capacity invariants: %#v", published)
	}
	if published.Autoscaling.Status != "degraded" ||
		published.Autoscaling.LastError == nil {
		t.Fatalf("failed controller update was not surfaced: %#v", published.Autoscaling)
	}
	if _, err := os.Stat(manager.paths.acknowledgement); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("failed maximum decrease was acknowledged")
	}

	manager.runReconciliationCycle(ctx)
	if manager.applied == nil || manager.applied.state.Generation != 2 {
		t.Fatal("successful retry did not promote the accepted generation")
	}
	if published.Generation != 2 ||
		published.ConfiguredSlots != 2 ||
		published.DesiredSlots != 2 ||
		published.Autoscaling.TargetSlots != 2 ||
		published.Autoscaling.MaximumSlots != 2 {
		t.Fatalf("successful retry did not publish the new capacity: %#v", published)
	}
	acknowledgementData, err := os.ReadFile(manager.paths.acknowledgement)
	if err != nil {
		t.Fatal(err)
	}
	var ack acknowledgement
	if err := json.Unmarshal(acknowledgementData, &ack); err != nil {
		t.Fatal(err)
	}
	if ack.Generation != 2 || ack.DesiredSlots != 2 {
		t.Fatalf("successful capacity update was not acknowledged: %#v", ack)
	}

	cancel()
	closeControllersForTest(t, manager)
}

func TestControllerMaximumUpdateRollsBackAfterPartialFailure(t *testing.T) {
	cfg := managerTestConfig(projectTestDirectory(t))
	cfg.minimumIdle = 3
	cfg.scaleDownDelay = time.Minute
	previous := targetSpec{
		key:             "repo-one",
		registrationURL: "https://github.com/example/one",
		repository:      "https://github.com/example/one",
		maximum:         1,
		scaleSetName:    "pitcrew-profile-a-one",
	}
	controller := newCoherenceTestController(cfg, previous)
	api := controller.api.(*fakeScaleSetService)
	if _, err := controller.scaler.HandleDesiredRunnerCount(
		context.Background(),
		0,
	); err != nil {
		t.Fatal(err)
	}
	partialFailure := errors.New("second JIT allocation failed")
	api.generateErrors = []error{nil, partialFailure}
	next := previous
	next.maximum = 3

	err := controller.update(context.Background(), cfg, next)
	if !errors.Is(err, partialFailure) {
		t.Fatalf("partial update failure was not preserved: %v", err)
	}
	snapshot := controller.snapshot()
	if snapshot.target.maximum != previous.maximum ||
		snapshot.targetSlots != previous.maximum ||
		len(snapshot.runners) != 2 {
		t.Fatalf("failed maximum update was not rolled back: %#v", snapshot)
	}
	if controller.target != previous {
		t.Fatalf("listener target changed before scaler success: %#v", controller.target)
	}
	if !controller.matches(previous) {
		t.Fatal("controller no longer matches its rolled-back applied maximum")
	}
	if controller.matches(next) {
		t.Fatal("controller reported the failed maximum as applied")
	}
	controller.cancel()
}

func TestAcknowledgementRequiresExactLiveDesiredControllers(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*autoscalerManager, *targetController, targetSpec)
		valid  bool
	}{
		{name: "healthy exact controller", valid: true},
		{
			name: "capacity increase not applied",
			mutate: func(
				_ *autoscalerManager,
				controller *targetController,
				_ targetSpec,
			) {
				controller.scaler.mu.Lock()
				controller.scaler.target.maximum = 2
				controller.scaler.targetSlots = 2
				controller.scaler.mu.Unlock()
			},
		},
		{
			name: "missing controller",
			mutate: func(
				manager *autoscalerManager,
				_ *targetController,
				target targetSpec,
			) {
				delete(manager.controllers, target.key)
			},
		},
		{
			name: "pending creation",
			mutate: func(
				manager *autoscalerManager,
				_ *targetController,
				target targetSpec,
			) {
				manager.pending[target.key] = pendingScaleSet{
					api: newFakeScaleSetService(nil),
				}
			},
		},
		{
			name: "restart scheduled",
			mutate: func(
				manager *autoscalerManager,
				_ *targetController,
				target targetSpec,
			) {
				manager.restarts[target.key] = restartState{
					at:       time.Now(),
					attempts: 1,
				}
			},
		},
		{
			name: "listener failure pending",
			mutate: func(
				manager *autoscalerManager,
				_ *targetController,
				target targetSpec,
			) {
				manager.reportListenerFailure(
					target.key,
					errors.New("listener failed"),
				)
			},
		},
		{
			name: "listener stopped",
			mutate: func(
				_ *autoscalerManager,
				controller *targetController,
				_ targetSpec,
			) {
				close(controller.done)
			},
		},
		{
			name: "retiring controller",
			mutate: func(
				manager *autoscalerManager,
				controller *targetController,
				target targetSpec,
			) {
				controller.scaler.mu.Lock()
				controller.scaler.retiring = true
				controller.scaler.mu.Unlock()
				manager.retiring[target.key] = controller
			},
		},
		{
			name: "target exceeds maximum",
			mutate: func(
				_ *autoscalerManager,
				controller *targetController,
				_ targetSpec,
			) {
				controller.scaler.mu.Lock()
				controller.scaler.targetSlots = 6
				controller.scaler.mu.Unlock()
			},
		},
		{
			name: "extra active controller",
			mutate: func(
				manager *autoscalerManager,
				_ *targetController,
				_ targetSpec,
			) {
				extraTarget := targetSpec{
					key:             "extra",
					registrationURL: "https://github.com/example/extra",
					maximum:         1,
					scaleSetName:    "extra",
				}
				manager.controllers[extraTarget.key] = newCoherenceTestController(
					manager.cfg,
					extraTarget,
				)
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			directory := projectTestDirectory(t)
			cfg := managerTestConfig(directory)
			current := parseDesiredForTest(t, "repo", `{
			  "schemaVersion":1,
			  "generation":2,
			  "scope":"repo",
			  "repositories":[
			    {"url":"https://github.com/example/one","workers":5}
			  ],
			  "replicas":null
			}`)
			targets, err := buildTargetSpecs(current.state, cfg)
			if err != nil {
				t.Fatal(err)
			}
			manager := newAutoscalerManager(
				cfg,
				newFakeScaleSetServiceFactory(),
				newFakeDockerClient(nil),
				&fakeClock{current: time.Now()},
				testLogger(),
				"instance",
			)
			manager.current = &current
			manager.applied = &current
			manager.ackPending = true
			manager.retirementGeneration = current.state.Generation
			controller := newCoherenceTestController(cfg, targets[0])
			manager.controllers[targets[0].key] = controller
			if test.mutate != nil {
				test.mutate(manager, controller, targets[0])
			}

			if coherent := manager.currentConfigurationCoherent(); coherent != test.valid {
				t.Fatalf("expected coherence %t, got %t", test.valid, coherent)
			}
			err = manager.publishAcknowledgement()
			if test.valid {
				if err != nil {
					t.Fatalf("healthy configuration was not acknowledged: %v", err)
				}
			} else {
				if err == nil {
					t.Fatal("incoherent configuration was acknowledged")
				}
				if _, statErr := os.Stat(manager.paths.acknowledgement); !errors.Is(statErr, os.ErrNotExist) {
					t.Fatal("incoherent configuration wrote an acknowledgement")
				}
			}
			for _, active := range manager.controllers {
				if active.context != nil {
					active.cancel()
				}
			}
		})
	}
}

func TestListenerFailureTrackingIsLosslessAcrossMultiTargetOutage(t *testing.T) {
	manager := newAutoscalerManager(
		managerTestConfig(projectTestDirectory(t)),
		newFakeScaleSetServiceFactory(),
		newFakeDockerClient(nil),
		&fakeClock{current: time.Now()},
		testLogger(),
		"instance",
	)
	const targetCount = 96
	for index := 0; index < targetCount; index++ {
		key := fmt.Sprintf("target-%03d", index)
		manager.reportListenerFailure(key, fmt.Errorf("listener %s failed", key))
	}
	if !manager.processListenerFailures() {
		t.Fatal("listener outage was not observed")
	}
	if len(manager.restarts) != targetCount {
		t.Fatalf(
			"listener failure tracking lost targets: expected %d, got %d",
			targetCount,
			len(manager.restarts),
		)
	}
	manager.listenerFailureMu.Lock()
	remainingFailures := len(manager.listenerFailureState)
	manager.listenerFailureMu.Unlock()
	if remainingFailures != 0 {
		t.Fatalf("processed listener failures remain queued: %d", remainingFailures)
	}
}

func TestStoppedListenersAreDetectedWithoutFailureNotification(t *testing.T) {
	clock := &fakeClock{current: time.Now()}
	manager := newAutoscalerManager(
		managerTestConfig(projectTestDirectory(t)),
		newFakeScaleSetServiceFactory(),
		newFakeDockerClient(nil),
		clock,
		testLogger(),
		"instance",
	)
	const targetCount = 48
	for index := 0; index < targetCount; index++ {
		target := targetSpec{
			key:             fmt.Sprintf("target-%03d", index),
			registrationURL: fmt.Sprintf("https://github.com/example/%03d", index),
			maximum:         1,
			scaleSetName:    fmt.Sprintf("scale-set-%03d", index),
		}
		controller := newCoherenceTestController(manager.cfg, target)
		close(controller.done)
		manager.controllers[target.key] = controller
	}
	if !manager.detectStoppedListeners() {
		t.Fatal("closed listeners were not detected")
	}
	if len(manager.restarts) != targetCount {
		t.Fatalf(
			"periodic detection lost stopped listeners: expected %d, got %d",
			targetCount,
			len(manager.restarts),
		)
	}
	clock.advance(time.Second)
	if err := manager.restartFailedListeners(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(manager.restarts) != 0 {
		t.Fatalf("not every stopped listener was restarted: %d pending", len(manager.restarts))
	}
	for _, controller := range manager.controllers {
		if controller.listenerStopped() {
			t.Fatal("listener remained stopped after scheduled restart")
		}
		controller.cancel()
	}
}

func TestUnexpectedStartupErrorPreservesRecoveredContainers(t *testing.T) {
	directory := projectTestDirectory(t)
	cfg := managerTestConfig(directory)
	paths := newStatePaths(directory)
	if err := os.WriteFile(paths.lastValid, []byte("{invalid"), 0o644); err != nil {
		t.Fatal(err)
	}
	docker := newFakeDockerClient(nil)
	docker.recovered = []recoveredContainer{{
		containerID: "live-container",
		targetKey:   "repo-one",
		slotKey:     "repo-one-1",
		runnerID:    1,
	}}
	manager := newAutoscalerManager(
		cfg,
		newFakeScaleSetServiceFactory(),
		docker,
		&fakeClock{current: time.Now()},
		testLogger(),
		"instance",
	)
	if err := manager.run(context.Background()); err == nil {
		t.Fatal("expected invalid persisted state to fail startup")
	}
	if len(docker.stopRemove) != 0 || len(docker.stops) != 0 {
		t.Fatal("unexpected process error stopped recovered containers")
	}
}

func TestManagerShutdownDeadlineBoundsHungScalingOperation(t *testing.T) {
	directory := projectTestDirectory(t)
	cfg := managerTestConfig(directory)
	current := parseDesiredForTest(t, "repo", `{
	  "schemaVersion":1,
	  "generation":1,
	  "scope":"repo",
	  "repositories":[
	    {"url":"https://github.com/example/one","workers":1}
	  ],
	  "replicas":null
	}`)
	factory := newFakeScaleSetServiceFactory()
	manager := newAutoscalerManager(
		cfg,
		factory,
		newFakeDockerClient(nil),
		&fakeClock{current: time.Now()},
		testLogger(),
		"instance",
	)
	manager.current = &current
	manager.applied = &current
	manager.retirementGeneration = current.state.Generation
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := manager.reconcileDesiredTargets(ctx); err != nil {
		t.Fatal(err)
	}
	targets, err := buildTargetSpecs(current.state, cfg)
	if err != nil {
		t.Fatal(err)
	}
	controller := manager.controllers[targets[0].key]
	if controller == nil {
		t.Fatal("desired controller was not started")
	}
	service := fakeServiceForURL(t, factory, targets[0].registrationURL)
	service.generateStarted = make(chan struct{}, 1)
	generateContinue := make(chan struct{})
	service.generateContinue = generateContinue
	scaleResult := make(chan error, 1)
	go func() {
		_, scaleErr := controller.scaler.HandleDesiredRunnerCount(
			context.Background(),
			1,
		)
		scaleResult <- scaleErr
	}()
	select {
	case <-service.generateStarted:
	case <-time.After(time.Second):
		close(generateContinue)
		t.Fatal("blocked scale-set operation did not start")
	}

	manager.shutdownTimeout = 40 * time.Millisecond
	requestFullStop(t, manager)
	startedAt := time.Now()
	err = manager.shutdown()
	elapsed := time.Since(startedAt)
	close(generateContinue)
	select {
	case <-scaleResult:
	case <-time.After(time.Second):
		t.Fatal("blocked listener callback did not finish after release")
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("manager shutdown did not report its deadline: %v", err)
	}
	if elapsed > 400*time.Millisecond {
		t.Fatalf("manager shutdown exceeded its internal deadline: %s", elapsed)
	}
}

func TestObservedWriteFailureIsRetriedWithoutStoppingManager(t *testing.T) {
	directory := projectTestDirectory(t)
	cfg := managerTestConfig(directory)
	cfg.observedInterval = 10 * time.Millisecond
	manager := newAutoscalerManager(
		cfg,
		newFakeScaleSetServiceFactory(),
		newFakeDockerClient(nil),
		&fakeClock{current: time.Now()},
		testLogger(),
		"instance",
	)
	var mu sync.Mutex
	calls := 0
	successfulState := make(chan observedState, 1)
	manager.writeObserved = func(_ string, value any) error {
		mu.Lock()
		defer mu.Unlock()
		calls++
		if calls <= 2 {
			return errors.New("state volume is temporarily unavailable")
		}
		state := value.(observedState)
		select {
		case successfulState <- state:
		default:
		}
		return nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() {
		result <- manager.run(ctx)
	}()
	var state observedState
	select {
	case state = <-successfulState:
	case err := <-result:
		t.Fatalf("manager stopped after observed-state failure: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatal("observed-state write was not retried")
	}
	if state.Autoscaling.LastError != nil {
		t.Fatalf("successful retry retained stale write error: %q", *state.Autoscaling.LastError)
	}
	select {
	case err := <-result:
		t.Fatalf("manager stopped before operator cancellation: %v", err)
	default:
	}
	cancel()
	select {
	case err := <-result:
		if err != nil {
			t.Fatalf("operator shutdown failed: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("manager did not stop after operator cancellation")
	}
}

func managerTestConfig(directory string) config {
	return config{
		accessToken:       "pat-value",
		profileID:         "profile-a",
		runnerImage:       "example/runner:latest",
		workerRevision:    testWorkerRevision,
		sessionOwner:      "pitcrew-profile-a",
		assumeUnversioned: true,
		scope:             "repo",
		namePrefix:        "pitcrew-runner",
		runnerGroup:       "default",
		stateDirectory:    directory,
		scaleDownDelay:    30 * time.Second,
		observedInterval:  time.Second,
		architectureLabel: "x64",
	}
}

func requestFullStop(t *testing.T, manager *autoscalerManager) {
	t.Helper()
	containerID, err := os.Hostname()
	if err != nil {
		t.Fatalf("resolve test manager container identity: %v", err)
	}
	request := shutdownRequest{
		SchemaVersion:      1,
		ManagerContainerID: containerID,
		RequestedAt:        time.Now().UTC().Format(time.RFC3339Nano),
	}
	if err := writeJSONAtomically(manager.paths.shutdownRequest, request); err != nil {
		t.Fatalf("write manager shutdown request: %v", err)
	}
}

func newCoherenceTestController(
	cfg config,
	target targetSpec,
) *targetController {
	ctx, cancel := context.WithCancel(context.Background())
	api := newFakeScaleSetService(nil)
	scaler := newRunnerScaler(
		ctx,
		cfg,
		target,
		api.ensureHandle.id,
		api,
		newFakeDockerClient(nil),
		&fakeClock{current: time.Now()},
		nil,
		nil,
	)
	controller := &targetController{
		target:     target,
		handle:     api.ensureHandle,
		api:        api,
		context:    ctx,
		scaler:     scaler,
		cancel:     cancel,
		done:       make(chan struct{}),
		instanceID: "instance",
		logger:     testLogger(),
		onError:    func(error) {},
		onListenerFailure: func(string, error) {
		},
	}
	controller.listenerScaler = &listenerScaler{
		scaler:  scaler,
		onError: func(error) {},
	}
	return controller
}

func parseDesiredForTest(
	t *testing.T,
	scope string,
	document string,
) parsedDesiredState {
	t.Helper()
	parsed, err := parseDesiredState([]byte(document), scope)
	if err != nil {
		t.Fatal(err)
	}
	return parsed
}

func fakeServiceForURL(
	t *testing.T,
	factory *fakeScaleSetServiceFactory,
	registrationURL string,
) *fakeScaleSetService {
	t.Helper()
	factory.mu.Lock()
	defer factory.mu.Unlock()
	service := factory.services[registrationURL]
	if service == nil {
		t.Fatalf("no fake service for %s", registrationURL)
	}
	return service
}

func closeControllersForTest(t *testing.T, manager *autoscalerManager) {
	t.Helper()
	for _, controller := range manager.controllers {
		closeControllerForTest(t, controller)
	}
	for _, controller := range manager.retiring {
		closeControllerForTest(t, controller)
	}
}

func closeControllerForTest(t *testing.T, controller *targetController) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := controller.closeSession(ctx); err != nil {
		t.Errorf("close test controller: %v", err)
	}
}

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}
