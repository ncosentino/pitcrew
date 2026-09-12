package main

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/actions/scaleset"
	"github.com/ncosentino/pitcrew/manager/admission"
)

func newOrphanedHostLeaseRecoveryFixture(
	t *testing.T,
	bindRegistration bool,
) (*autoscalerManager, *admission.Coordinator, *fakeScaleSetService) {
	t.Helper()
	coordinator := admission.OpenMemory(admission.SystemClock{}, time.Minute)
	if err := coordinator.ApplyPolicy(admission.HostPolicy{
		Generation: 1,
		TotalUnits: 1,
		Profiles: []admission.ProfilePolicy{{
			ProfileID: "profile-a",
			UnitCost:  1,
		}},
	}); err != nil {
		t.Fatalf("apply policy: %v", err)
	}
	lease, err := coordinator.Acquire("profile-a", "runner-orphan", 1)
	if err != nil {
		t.Fatalf("seed lease: %v", err)
	}
	if bindRegistration {
		if _, err := coordinator.BindRegistration(
			"profile-a",
			lease.SlotKey,
			"runner-orphan",
		); err != nil {
			t.Fatalf("bind registration: %v", err)
		}
	}
	if _, err := coordinator.Activate("profile-a", lease.SlotKey); err != nil {
		t.Fatalf("activate lease: %v", err)
	}
	if err := coordinator.BeginAdoption("profile-a"); err != nil {
		t.Fatalf("begin adoption: %v", err)
	}

	api := newFakeScaleSetService(nil)
	recorder, _, _ := newTestRecorder(t)
	hostAdmission := newHostAdmissionCoordinatorWithClient(
		coordinatorLeaseClient{coordinator: coordinator},
		"profile-a",
	)
	manager := &autoscalerManager{
		hostAdmission:                hostAdmission,
		hostAdmissionAdoptionPending: true,
		diagnostics:                  recorder,
		controllers: map[string]*targetController{
			"target-a": {
				handle: scaleSetHandle{id: 42, name: "target-a"},
				api:    api,
				target: targetSpec{
					key:             "target-a",
					registrationURL: "https://github.com/example/repository",
				},
				scaler: &runnerScaler{
					hostAdmission: hostAdmission,
					runners:       make(map[string]*runnerRecord),
				},
			},
		},
		retiring:  make(map[string]*targetController),
		recovered: make(map[string][]recoveredContainer),
	}
	return manager, coordinator, api
}

func TestAutoscalerReconcilesOrphanedLeaseWithMissingRegistration(t *testing.T) {
	manager, coordinator, api := newOrphanedHostLeaseRecoveryFixture(t, true)

	if err := manager.completeHostAdmissionAdoptionIfReady(context.Background()); err != nil {
		t.Fatalf("complete recovery: %v", err)
	}
	if manager.hostAdmissionAdoptionPending {
		t.Fatal("successful orphan reconciliation left the adoption fence pending")
	}
	snapshot, err := coordinator.Status()
	if err != nil {
		t.Fatalf("read status: %v", err)
	}
	if len(snapshot.Leases) != 0 || len(snapshot.AdoptionFences) != 0 {
		t.Fatalf("orphaned lease did not reconcile: %+v", snapshot)
	}
	if len(api.removeCalls) != 0 {
		t.Fatalf("missing registration triggered a removal: %v", api.removeCalls)
	}
}

func TestAutoscalerDockerRestartFixtureReconcilesDurableLease(t *testing.T) {
	directory := t.TempDir()
	coordinator, err := admission.OpenFile(
		directory,
		admission.SystemClock{},
		time.Minute,
	)
	if err != nil {
		t.Fatalf("open coordinator: %v", err)
	}
	if err := coordinator.ApplyPolicy(admission.HostPolicy{
		Generation: 1,
		TotalUnits: 1,
		Profiles: []admission.ProfilePolicy{{
			ProfileID: "profile-a",
			UnitCost:  1,
		}},
	}); err != nil {
		t.Fatalf("apply policy: %v", err)
	}
	if _, err := coordinator.Acquire("profile-a", "runner-orphan", 1); err != nil {
		t.Fatalf("acquire lease: %v", err)
	}
	if _, err := coordinator.BindRegistration(
		"profile-a",
		"runner-orphan",
		"runner-orphan",
	); err != nil {
		t.Fatalf("bind registration: %v", err)
	}
	if _, err := coordinator.Activate("profile-a", "runner-orphan"); err != nil {
		t.Fatalf("activate lease: %v", err)
	}

	coordinator, err = admission.OpenFile(
		directory,
		admission.SystemClock{},
		time.Minute,
	)
	if err != nil {
		t.Fatalf("restart coordinator: %v", err)
	}
	if err := coordinator.BeginAdoption("profile-a"); err != nil {
		t.Fatalf("begin replacement-manager adoption: %v", err)
	}
	api := newFakeScaleSetService(nil)
	hostAdmission := newHostAdmissionCoordinatorWithClient(
		coordinatorLeaseClient{coordinator: coordinator},
		"profile-a",
	)
	manager := &autoscalerManager{
		hostAdmission:                hostAdmission,
		hostAdmissionAdoptionPending: true,
		diagnostics:                  newDiagnosticsRecorder("", "replacement", nil),
		controllers: map[string]*targetController{
			"target-a": {
				handle: scaleSetHandle{id: 42, name: "target-a"},
				api:    api,
				target: targetSpec{
					key:             "target-a",
					registrationURL: "https://github.com/example/repository",
				},
				scaler: &runnerScaler{
					hostAdmission: hostAdmission,
					runners:       make(map[string]*runnerRecord),
				},
			},
		},
		retiring:  make(map[string]*targetController),
		recovered: make(map[string][]recoveredContainer),
	}
	if err := manager.completeHostAdmissionAdoptionIfReady(
		context.Background(),
	); err != nil {
		t.Fatalf("reconcile durable orphan: %v", err)
	}

	restarted, err := admission.OpenFile(
		directory,
		admission.SystemClock{},
		time.Minute,
	)
	if err != nil {
		t.Fatalf("reopen reconciled coordinator: %v", err)
	}
	snapshot, err := restarted.Status()
	if err != nil {
		t.Fatalf("read status: %v", err)
	}
	if len(snapshot.Leases) != 0 ||
		len(snapshot.AdoptionFences) != 0 ||
		len(snapshot.Tombstones) != 1 {
		t.Fatalf("durable orphan did not converge after restart: %+v", snapshot)
	}
}

func TestAutoscalerRemovesExactOrphanedRegistrationBeforeLease(t *testing.T) {
	manager, coordinator, api := newOrphanedHostLeaseRecoveryFixture(t, true)
	api.runnersByName["runner-orphan"] = runnerReference{
		id:         77,
		name:       "runner-orphan",
		scaleSetID: 42,
	}

	if err := manager.completeHostAdmissionAdoptionIfReady(context.Background()); err != nil {
		t.Fatalf("complete recovery: %v", err)
	}
	if len(api.removeCalls) != 1 || api.removeCalls[0] != 77 {
		t.Fatalf("exact registration was not removed: %v", api.removeCalls)
	}
	snapshot, err := coordinator.Status()
	if err != nil {
		t.Fatalf("read status: %v", err)
	}
	if len(snapshot.Leases) != 0 {
		t.Fatalf("lease remained after exact registration removal: %+v", snapshot)
	}
}

func TestAutoscalerPreservesLeaseWhenRegistrationLookupFails(t *testing.T) {
	manager, coordinator, api := newOrphanedHostLeaseRecoveryFixture(t, true)
	api.findRunnerErrors["runner-orphan"] = errors.New("registration lookup failed")

	if err := manager.completeHostAdmissionAdoptionIfReady(
		context.Background(),
	); err == nil {
		t.Fatal("registration lookup failure unexpectedly completed adoption")
	}
	if !manager.hostAdmissionAdoptionPending {
		t.Fatal("registration lookup failure cleared the adoption fence")
	}
	snapshot, err := coordinator.Status()
	if err != nil {
		t.Fatalf("read status: %v", err)
	}
	if len(snapshot.Leases) != 1 || len(snapshot.AdoptionFences) != 1 {
		t.Fatalf("ambiguous recovery changed durable lease state: %+v", snapshot)
	}
	if err := manager.completeHostAdmissionAdoptionIfReady(
		context.Background(),
	); err != nil {
		t.Fatalf("bounded retry interval returned a second immediate error: %v", err)
	}
	if api.findRunnerCalls["runner-orphan"] != 1 {
		t.Fatalf(
			"registration recovery retried before its bounded interval: %d",
			api.findRunnerCalls["runner-orphan"],
		)
	}
}

func TestOrphanRegistrationLookupFailureDegradesGitHubEvidence(t *testing.T) {
	api := newFakeScaleSetService(nil)
	api.findRunnerErrors["runner-orphan"] = errors.New("registration lookup failed")
	recorder, _, _ := newTestRecorder(t)
	service := instrumentScaleSetService(api, recorder)

	if _, _, err := service.findRunnerByName(
		context.Background(),
		"runner-orphan",
	); err == nil {
		t.Fatal("registration lookup failure was not returned")
	}
	health := recorder.subsystemHealth()
	if health.GitHub.State != subsystemDegraded ||
		health.GitHub.LastFailure == nil ||
		health.GitHub.LastFailure.Operation != operationRegistrationCleanup {
		t.Fatalf("registration lookup failure did not degrade GitHub evidence: %+v", health.GitHub)
	}
}

func TestAutoscalerPreservesLeaseUntilEveryVerificationTargetIsReady(t *testing.T) {
	manager, coordinator, api := newOrphanedHostLeaseRecoveryFixture(t, true)
	current := parseDesiredForTest(t, "repo", `{
	  "schemaVersion":1,
	  "generation":1,
	  "scope":"repo",
	  "repositories":[{"url":"https://github.com/example/unavailable","workers":1}],
	  "replicas":null
	}`)
	manager.current = &current

	if err := manager.completeHostAdmissionAdoptionIfReady(
		context.Background(),
	); err != nil {
		t.Fatalf("incomplete verification inventory returned an error: %v", err)
	}
	if len(api.removeCalls) != 0 {
		t.Fatalf("partial verification inventory removed a registration: %v", api.removeCalls)
	}
	snapshot, err := coordinator.Status()
	if err != nil {
		t.Fatalf("read status: %v", err)
	}
	if len(snapshot.Leases) != 1 || len(snapshot.AdoptionFences) != 1 {
		t.Fatalf("partial verification inventory changed durable state: %+v", snapshot)
	}
}

func TestAutoscalerClearsEmptyFenceWithoutVerificationTargets(t *testing.T) {
	coordinator := admission.OpenMemory(admission.SystemClock{}, time.Minute)
	if err := coordinator.ApplyPolicy(admission.HostPolicy{
		Generation: 1,
		TotalUnits: 1,
		Profiles: []admission.ProfilePolicy{{
			ProfileID: "profile-a",
			UnitCost:  1,
		}},
	}); err != nil {
		t.Fatalf("apply policy: %v", err)
	}
	if err := coordinator.BeginAdoption("profile-a"); err != nil {
		t.Fatalf("begin adoption: %v", err)
	}
	hostAdmission := newHostAdmissionCoordinatorWithClient(
		coordinatorLeaseClient{coordinator: coordinator},
		"profile-a",
	)
	current := parseDesiredForTest(t, "repo", `{
	  "schemaVersion":1,
	  "generation":1,
	  "scope":"repo",
	  "repositories":[{"url":"https://github.com/example/unavailable","workers":1}],
	  "replicas":null
	}`)
	manager := &autoscalerManager{
		current:                      &current,
		hostAdmission:                hostAdmission,
		hostAdmissionAdoptionPending: true,
		controllers:                  make(map[string]*targetController),
		retiring:                     make(map[string]*targetController),
		recovered:                    make(map[string][]recoveredContainer),
		retirementRecords:            make(map[string]retirementRecord),
		orphanRecoveryTargets:        make(map[string]hostAdmissionRecoveryTarget),
	}

	if err := manager.completeHostAdmissionAdoptionIfReady(
		context.Background(),
	); err != nil {
		t.Fatalf("complete empty adoption fence: %v", err)
	}
	if manager.hostAdmissionAdoptionPending {
		t.Fatal("empty adoption fence remained pending")
	}
	snapshot, err := coordinator.Status()
	if err != nil {
		t.Fatalf("read status: %v", err)
	}
	if len(snapshot.AdoptionFences) != 0 {
		t.Fatalf("empty adoption fence was not cleared: %+v", snapshot)
	}
}

func TestAutoscalerPreservesLeaseWhenRegistrationRemovalFails(t *testing.T) {
	manager, coordinator, api := newOrphanedHostLeaseRecoveryFixture(t, true)
	api.runnersByName["runner-orphan"] = runnerReference{
		id:         77,
		name:       "runner-orphan",
		scaleSetID: 42,
	}
	api.removeErrors[77] = errors.New("registration removal failed")

	if err := manager.completeHostAdmissionAdoptionIfReady(
		context.Background(),
	); err == nil {
		t.Fatal("registration removal failure unexpectedly completed adoption")
	}
	if !manager.hostAdmissionAdoptionPending {
		t.Fatal("registration removal failure cleared the adoption fence")
	}
	snapshot, err := coordinator.Status()
	if err != nil {
		t.Fatalf("read status: %v", err)
	}
	if len(snapshot.Leases) != 1 || len(snapshot.AdoptionFences) != 1 {
		t.Fatalf("failed registration removal changed durable lease state: %+v", snapshot)
	}
}

func TestAutoscalerTreatsConcurrentRegistrationAbsenceAsReconciled(t *testing.T) {
	manager, coordinator, api := newOrphanedHostLeaseRecoveryFixture(t, true)
	api.runnersByName["runner-orphan"] = runnerReference{
		id:         77,
		name:       "runner-orphan",
		scaleSetID: 42,
	}
	api.removeErrors[77] = scaleset.RunnerNotFoundError

	if err := manager.completeHostAdmissionAdoptionIfReady(
		context.Background(),
	); err != nil {
		t.Fatalf("concurrent registration absence did not reconcile: %v", err)
	}
	snapshot, err := coordinator.Status()
	if err != nil {
		t.Fatalf("read status: %v", err)
	}
	if len(snapshot.Leases) != 0 || len(snapshot.AdoptionFences) != 0 {
		t.Fatalf("concurrently absent registration retained the lease: %+v", snapshot)
	}
}

func TestAutoscalerPreservesLeaseForUnknownScaleSetRegistration(t *testing.T) {
	manager, coordinator, api := newOrphanedHostLeaseRecoveryFixture(t, true)
	api.runnersByName["runner-orphan"] = runnerReference{
		id:         77,
		name:       "runner-orphan",
		scaleSetID: 99,
	}

	if err := manager.completeHostAdmissionAdoptionIfReady(
		context.Background(),
	); err == nil {
		t.Fatal("unknown scale-set registration unexpectedly completed adoption")
	}
	if len(api.removeCalls) != 0 {
		t.Fatalf("unknown scale-set registration was removed: %v", api.removeCalls)
	}
	snapshot, err := coordinator.Status()
	if err != nil {
		t.Fatalf("read status: %v", err)
	}
	if len(snapshot.Leases) != 1 || len(snapshot.AdoptionFences) != 1 {
		t.Fatalf("unknown registration identity changed durable lease state: %+v", snapshot)
	}
}

func TestAutoscalerPreservesLeaseForMismatchedLookupIdentity(t *testing.T) {
	manager, coordinator, api := newOrphanedHostLeaseRecoveryFixture(t, true)
	api.runnersByName["runner-orphan"] = runnerReference{
		id:         77,
		name:       "different-runner",
		scaleSetID: 42,
	}

	if err := manager.completeHostAdmissionAdoptionIfReady(
		context.Background(),
	); err == nil {
		t.Fatal("mismatched registration identity unexpectedly completed adoption")
	}
	if len(api.removeCalls) != 0 {
		t.Fatalf("mismatched registration identity was removed: %v", api.removeCalls)
	}
	snapshot, err := coordinator.Status()
	if err != nil {
		t.Fatalf("read status: %v", err)
	}
	if len(snapshot.Leases) != 1 || len(snapshot.AdoptionFences) != 1 {
		t.Fatalf("mismatched registration changed durable state: %+v", snapshot)
	}
}

func TestAutoscalerPreservesLeaseForAmbiguousRegistrationScopes(t *testing.T) {
	manager, coordinator, firstAPI := newOrphanedHostLeaseRecoveryFixture(t, true)
	firstAPI.runnersByName["runner-orphan"] = runnerReference{
		id:         77,
		name:       "runner-orphan",
		scaleSetID: 42,
	}
	secondAPI := newFakeScaleSetService(nil)
	secondAPI.runnersByName["runner-orphan"] = runnerReference{
		id:         88,
		name:       "runner-orphan",
		scaleSetID: 43,
	}
	manager.controllers["target-b"] = &targetController{
		handle: scaleSetHandle{id: 43, name: "target-b"},
		api:    secondAPI,
		target: targetSpec{
			key:             "target-b",
			registrationURL: "https://github.com/example/other",
		},
		scaler: &runnerScaler{
			hostAdmission: manager.hostAdmission,
			runners:       make(map[string]*runnerRecord),
		},
	}

	if err := manager.completeHostAdmissionAdoptionIfReady(
		context.Background(),
	); err == nil {
		t.Fatal("ambiguous registration scopes unexpectedly completed adoption")
	}
	if len(firstAPI.removeCalls) != 0 || len(secondAPI.removeCalls) != 0 {
		t.Fatalf(
			"ambiguous registration was removed: first=%v second=%v",
			firstAPI.removeCalls,
			secondAPI.removeCalls,
		)
	}
	snapshot, err := coordinator.Status()
	if err != nil {
		t.Fatalf("read status: %v", err)
	}
	if len(snapshot.Leases) != 1 || len(snapshot.AdoptionFences) != 1 {
		t.Fatalf("ambiguous registration changed durable state: %+v", snapshot)
	}
}

func TestAutoscalerSupportsLegacyNameBasedLeaseKey(t *testing.T) {
	manager, coordinator, _ := newOrphanedHostLeaseRecoveryFixture(t, false)

	if err := manager.completeHostAdmissionAdoptionIfReady(context.Background()); err != nil {
		t.Fatalf("legacy autoscaler lease key did not reconcile: %v", err)
	}
	snapshot, err := coordinator.Status()
	if err != nil {
		t.Fatalf("read status: %v", err)
	}
	if len(snapshot.Leases) != 0 {
		t.Fatalf("legacy name-based lease remained: %+v", snapshot)
	}
}

func TestAutoscalerAdoptsRecoveredWorkerBeforeCompletingFence(t *testing.T) {
	directory := projectTestDirectory(t)
	cfg := managerTestConfig(directory)
	current := parseDesiredForTest(t, "repo", `{
	  "schemaVersion":1,
	  "generation":1,
	  "scope":"repo",
	  "repositories":[{"url":"https://github.com/example/repository","workers":1}],
	  "replicas":null
	}`)
	targets, err := buildTargetSpecs(current.state, cfg)
	if err != nil {
		t.Fatalf("build target: %v", err)
	}
	target := targets[0]

	coordinator := admission.OpenMemory(admission.SystemClock{}, time.Minute)
	if err := coordinator.ApplyPolicy(admission.HostPolicy{
		Generation: 1,
		TotalUnits: 1,
		Profiles: []admission.ProfilePolicy{{
			ProfileID: "profile-a",
			UnitCost:  1,
		}},
	}); err != nil {
		t.Fatalf("apply policy: %v", err)
	}
	if _, err := coordinator.Adopt("profile-a", "runner-survivor"); err != nil {
		t.Fatalf("seed active lease: %v", err)
	}
	if err := coordinator.BeginAdoption("profile-a"); err != nil {
		t.Fatalf("begin adoption: %v", err)
	}

	factory := newFakeScaleSetServiceFactory()
	docker := newFakeDockerClient(nil)
	docker.logs["container-survivor"] = []string{"Listening for Jobs"}
	docker.running["container-survivor"] = true
	manager := newAutoscalerManager(
		cfg,
		factory,
		docker,
		&fakeClock{current: time.Now()},
		testLogger(),
		"instance",
	)
	manager.hostAdmission = newHostAdmissionCoordinatorWithClient(
		coordinatorLeaseClient{coordinator: coordinator},
		"profile-a",
	)
	manager.hostAdmissionAdoptionPending = true
	manager.current = &current
	manager.applied = &current
	manager.retirementGeneration = current.state.Generation
	manager.recovered[target.key] = []recoveredContainer{{
		containerID: "container-survivor",
		name:        "container-survivor",
		runnerName:  "runner-survivor",
		runnerID:    77,
		targetKey:   target.key,
		slotKey:     target.key + "-77",
		hostSlotKey: "runner-survivor",
		revision:    testWorkerRevision,
		createdAt:   time.Now().Add(-time.Minute),
	}}

	manager.runReconciliationCycle(context.Background())
	defer closeControllersForTest(t, manager)

	if manager.hostAdmissionAdoptionPending {
		t.Fatal("surviving worker did not clear the adoption fence")
	}
	snapshot, err := coordinator.Status()
	if err != nil {
		t.Fatalf("read status: %v", err)
	}
	if len(snapshot.AdoptionFences) != 0 ||
		len(snapshot.Leases) != 1 ||
		snapshot.Leases[0].RegistrationName != "runner-survivor" {
		t.Fatalf("surviving worker was not adopted exactly: %+v", snapshot)
	}
}

func TestAutoscalerDoesNotScaleUpWhileOrphanRecoveryIsUnresolved(t *testing.T) {
	directory := projectTestDirectory(t)
	cfg := managerTestConfig(directory)
	current := parseDesiredForTest(t, "repo", `{
	  "schemaVersion":1,
	  "generation":1,
	  "scope":"repo",
	  "repositories":[{"url":"https://github.com/example/repository","workers":1}],
	  "replicas":null
	}`)
	targets, err := buildTargetSpecs(current.state, cfg)
	if err != nil {
		t.Fatalf("build target: %v", err)
	}

	coordinator := admission.OpenMemory(admission.SystemClock{}, time.Minute)
	if err := coordinator.ApplyPolicy(admission.HostPolicy{
		Generation: 1,
		TotalUnits: 2,
		Profiles: []admission.ProfilePolicy{{
			ProfileID: "profile-a",
			UnitCost:  1,
		}},
	}); err != nil {
		t.Fatalf("apply policy: %v", err)
	}
	if _, err := coordinator.Adopt("profile-a", "runner-orphan"); err != nil {
		t.Fatalf("seed active lease: %v", err)
	}
	if err := coordinator.BeginAdoption("profile-a"); err != nil {
		t.Fatalf("begin adoption: %v", err)
	}

	factory := newFakeScaleSetServiceFactory()
	api := newFakeScaleSetService(nil)
	api.findRunnerErrors["runner-orphan"] = errors.New("registration lookup failed")
	factory.services[targets[0].registrationURL] = api
	manager := newAutoscalerManager(
		cfg,
		factory,
		newFakeDockerClient(nil),
		&fakeClock{current: time.Now()},
		testLogger(),
		"instance",
	)
	manager.hostAdmission = newHostAdmissionCoordinatorWithClient(
		coordinatorLeaseClient{coordinator: coordinator},
		"profile-a",
	)
	manager.hostAdmissionAdoptionPending = true
	manager.current = &current
	manager.applied = &current
	manager.retirementGeneration = current.state.Generation

	manager.runReconciliationCycle(context.Background())
	defer closeControllersForTest(t, manager)

	controller := manager.controllers[targets[0].key]
	if controller == nil {
		t.Fatal("desired controller was not started for recovery")
	}
	if _, err := controller.scaler.HandleDesiredRunnerCount(
		context.Background(),
		1,
	); err == nil {
		t.Fatal("scale-up unexpectedly succeeded while recovery remained fenced")
	}
	if api.jitCallCount() != 0 {
		t.Fatalf("scale-up generated JIT registration while fenced: %d", api.jitCallCount())
	}
	if !manager.hostAdmissionAdoptionPending {
		t.Fatal("unresolved orphan recovery cleared the manager fence")
	}
	if manager.hostAdmissionRecoveryError == nil ||
		manager.hostAdmissionRecoveryError.Error() !=
			"orphaned host admission lease reconciliation is pending" {
		t.Fatalf(
			"observed recovery condition was not retained: %v",
			manager.hostAdmissionRecoveryError,
		)
	}
	recoveryEventFound := false
	for _, event := range manager.diagnostics.journal().Events {
		if event.Subsystem == subsystemRecovery &&
			event.Outcome == outcomeBlocked {
			recoveryEventFound = true
			break
		}
	}
	if !recoveryEventFound {
		t.Fatal("unresolved orphan recovery was not journaled")
	}
}

func TestAutoscalerDefersRetirementUntilOrphanRegistrationIsReconciled(t *testing.T) {
	directory := projectTestDirectory(t)
	cfg := managerTestConfig(directory)
	previous := parseDesiredForTest(t, "repo", `{
	  "schemaVersion":1,
	  "generation":1,
	  "scope":"repo",
	  "repositories":[{"url":"https://github.com/example/retired","workers":1}],
	  "replicas":null
	}`)
	current := parseDesiredForTest(t, "repo", `{
	  "schemaVersion":1,
	  "generation":2,
	  "scope":"repo",
	  "repositories":[{"url":"https://github.com/example/current","workers":1}],
	  "replicas":null
	}`)
	previousTargets, err := buildTargetSpecs(previous.state, cfg)
	if err != nil {
		t.Fatalf("build previous target: %v", err)
	}
	retiredTarget := previousTargets[0]

	coordinator := admission.OpenMemory(admission.SystemClock{}, time.Minute)
	if err := coordinator.ApplyPolicy(admission.HostPolicy{
		Generation: 1,
		TotalUnits: 1,
		Profiles: []admission.ProfilePolicy{{
			ProfileID: "profile-a",
			UnitCost:  1,
		}},
	}); err != nil {
		t.Fatalf("apply policy: %v", err)
	}
	if _, err := coordinator.Adopt("profile-a", "runner-retired"); err != nil {
		t.Fatalf("seed active lease: %v", err)
	}
	if _, err := coordinator.BindRegistration(
		"profile-a",
		"runner-retired",
		"runner-retired",
	); err != nil {
		t.Fatalf("bind registration: %v", err)
	}
	if err := coordinator.BeginAdoption("profile-a"); err != nil {
		t.Fatalf("begin adoption: %v", err)
	}

	factory := newFakeScaleSetServiceFactory()
	retiredAPI := newFakeScaleSetService(nil)
	retiredAPI.ensureHandle = scaleSetHandle{
		id:   42,
		name: retiredTarget.scaleSetName,
	}
	retiredAPI.runnersByName["runner-retired"] = runnerReference{
		id:         77,
		name:       "runner-retired",
		scaleSetID: 42,
	}
	factory.services[retiredTarget.registrationURL] = retiredAPI
	manager := newAutoscalerManager(
		cfg,
		factory,
		newFakeDockerClient(nil),
		&fakeClock{current: time.Now()},
		testLogger(),
		"instance",
	)
	manager.hostAdmission = newHostAdmissionCoordinatorWithClient(
		coordinatorLeaseClient{coordinator: coordinator},
		"profile-a",
	)
	manager.hostAdmissionAdoptionPending = true
	manager.current = &current
	manager.applied = &current
	manager.retirementRecords[retiredTarget.key] = retirementRecordFor(
		retiredTarget,
		current.state.Generation,
	)
	manager.retirementGeneration = current.state.Generation

	manager.runReconciliationCycle(context.Background())
	defer closeControllersForTest(t, manager)

	if len(retiredAPI.removeCalls) != 1 || retiredAPI.removeCalls[0] != 77 {
		t.Fatalf("retired target registration was not removed exactly: %v", retiredAPI.removeCalls)
	}
	if len(retiredAPI.deletedScaleSet) != 1 ||
		retiredAPI.deletedScaleSet[0] != 42 {
		t.Fatalf(
			"retired scale set was not finalized after recovery: %v",
			retiredAPI.deletedScaleSet,
		)
	}
	if _, exists := manager.retirementRecords[retiredTarget.key]; exists {
		t.Fatal("retirement record remained after fenced recovery completed")
	}
	snapshot, err := coordinator.Status()
	if err != nil {
		t.Fatalf("read status: %v", err)
	}
	if len(snapshot.Leases) != 0 || len(snapshot.AdoptionFences) != 0 {
		t.Fatalf("retired target orphan was not reconciled: %+v", snapshot)
	}
}
