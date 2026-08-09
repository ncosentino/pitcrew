package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/actions/scaleset"
	"github.com/ncosentino/pitcrew/manager/admission"
)

// fakeHostAdmissionClient is a deterministic, in-memory stand-in for
// *admission.Client. It models a synthetic host-wide unit budget so tests can
// prove the autoscaler never admits more concurrent leases than the budget
// allows, without a real coordinator socket.
type fakeHostAdmissionClient struct {
	mu sync.Mutex

	budget      int
	leases      map[string]admission.Lease
	nextLeaseID int

	// acquireErr, when set, is returned for every Acquire call that does not
	// already hold a lease for its slot, regardless of budget. It models a
	// coordinator/socket outage distinct from a budget deny.
	acquireErr error

	activateErrs map[string]error
	renewErrs    map[string]error
	releaseErrs  map[string]error

	setDemandCalls []int
	acquireCalls   []string
	renewCalls     []string
	activateCalls  []string
	releaseCalls   []string
}

func newFakeHostAdmissionClient(budget int) *fakeHostAdmissionClient {
	return &fakeHostAdmissionClient{
		budget:       budget,
		leases:       make(map[string]admission.Lease),
		activateErrs: make(map[string]error),
		renewErrs:    make(map[string]error),
		releaseErrs:  make(map[string]error),
	}
}

func leaseSlotKey(profileID, slotKey string) string {
	return profileID + "/" + slotKey
}

func (c *fakeHostAdmissionClient) SetDemand(_ string, pending int) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.setDemandCalls = append(c.setDemandCalls, pending)
	return nil
}

func (c *fakeHostAdmissionClient) Acquire(
	profileID, slotKey string,
	_ int,
) (admission.Lease, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	key := leaseSlotKey(profileID, slotKey)
	c.acquireCalls = append(c.acquireCalls, key)
	if existing, ok := c.leases[key]; ok {
		return existing, admission.ErrDuplicateLease
	}
	if c.acquireErr != nil {
		return admission.Lease{}, c.acquireErr
	}
	if c.budget <= 0 {
		return admission.Lease{}, admission.ErrBudgetExceeded
	}
	c.budget--
	c.nextLeaseID++
	lease := admission.Lease{
		ProfileID: profileID,
		SlotKey:   slotKey,
		LeaseID:   fmt.Sprintf("lease-%d", c.nextLeaseID),
		Units:     1,
		Status:    admission.LeaseProvisional,
	}
	c.leases[key] = lease
	return lease, nil
}

func (c *fakeHostAdmissionClient) Renew(profileID, slotKey string) (admission.Lease, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	key := leaseSlotKey(profileID, slotKey)
	c.renewCalls = append(c.renewCalls, key)
	if err, ok := c.renewErrs[key]; ok {
		delete(c.renewErrs, key)
		if err != nil {
			return admission.Lease{}, err
		}
	}
	lease, ok := c.leases[key]
	if !ok {
		return admission.Lease{}, admission.ErrLeaseNotFound
	}
	return lease, nil
}

func (c *fakeHostAdmissionClient) Activate(profileID, slotKey string) (admission.Lease, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	key := leaseSlotKey(profileID, slotKey)
	c.activateCalls = append(c.activateCalls, key)
	if err, ok := c.activateErrs[key]; ok {
		delete(c.activateErrs, key)
		if err != nil {
			return admission.Lease{}, err
		}
	}
	lease, ok := c.leases[key]
	if !ok {
		return admission.Lease{}, admission.ErrLeaseNotFound
	}
	lease.Status = admission.LeaseActive
	c.leases[key] = lease
	return lease, nil
}

func (c *fakeHostAdmissionClient) Release(profileID, slotKey string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	key := leaseSlotKey(profileID, slotKey)
	c.releaseCalls = append(c.releaseCalls, key)
	if err, ok := c.releaseErrs[key]; ok {
		delete(c.releaseErrs, key)
		if err != nil {
			return err
		}
	}
	if _, ok := c.leases[key]; !ok {
		return admission.ErrLeaseNotFound
	}
	delete(c.leases, key)
	c.budget++
	return nil
}

func (c *fakeHostAdmissionClient) Reconcile(profileID, slotKey, _ string) error {
	return c.Release(profileID, slotKey)
}

// preGrant seeds a lease directly, bypassing Acquire, so recovery tests can
// simulate a lease this coordinator (or a prior instance) already held
// before the manager process restarted.
func (c *fakeHostAdmissionClient) preGrant(profileID, slotKey string, active bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	status := admission.LeaseProvisional
	if active {
		status = admission.LeaseActive
	}
	c.nextLeaseID++
	c.leases[leaseSlotKey(profileID, slotKey)] = admission.Lease{
		ProfileID: profileID,
		SlotKey:   slotKey,
		LeaseID:   fmt.Sprintf("lease-%d", c.nextLeaseID),
		Units:     1,
		Status:    status,
	}
}

func (c *fakeHostAdmissionClient) leaseCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.leases)
}

func (c *fakeHostAdmissionClient) remainingBudget() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.budget
}

func newHostAdmissionTestScaler(
	t *testing.T,
	maximum int,
	client hostAdmissionLeaseClient,
) (
	*runnerScaler,
	*fakeScaleSetService,
	*fakeDockerClient,
	*fakeClock,
	*hostAdmissionCoordinator,
	context.CancelFunc,
) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	clock := &fakeClock{current: time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)}
	events := &eventRecorder{}
	api := newFakeScaleSetService(events)
	docker := newFakeDockerClient(events)
	cfg := config{
		profileID:         "profile-a",
		runnerImage:       "example/runner:latest",
		workerRevision:    testWorkerRevision,
		sessionOwner:      "pitcrew-profile-a",
		assumeUnversioned: true,
		namePrefix:        "pitcrew-runner",
		scaleDownDelay:    10 * time.Minute,
	}
	target := targetSpec{
		key:             "repo-1234",
		registrationURL: "https://github.com/example/repository",
		repository:      "https://github.com/example/repository",
		maximum:         maximum,
		scaleSetName:    "pitcrew-profile-a-deadbeef",
	}
	hostAdmission := newHostAdmissionCoordinatorWithClient(client, cfg.profileID)
	scaler := newRunnerScaler(
		ctx,
		cfg,
		target,
		42,
		api,
		docker,
		clock,
		newAdmissionController(0),
		hostAdmission,
		newDiagnosticsRecorder("", "manager-instance", clock),
		testLogger(),
		nil,
		func(err error) {
			if err != nil && !errors.Is(err, context.Canceled) {
				t.Logf("scaler background error: %v", err)
			}
		},
	)
	suffix := 0
	scaler.nameSuffix = func() (string, error) {
		suffix++
		return fmt.Sprintf("suffix%02d", suffix), nil
	}
	return scaler, api, docker, clock, hostAdmission, cancel
}

// newHostAdmissionTestScalerInDirectory is the persistent-state counterpart
// of newHostAdmissionTestScaler: it backs both the registration cleanup and
// host lease cleanup ledgers with real files under stateDirectory, so tests
// can exercise durability across a simulated manager restart by building a
// second scaler instance pointed at the same directory.
func newHostAdmissionTestScalerInDirectory(
	t *testing.T,
	maximum int,
	client hostAdmissionLeaseClient,
	stateDirectory string,
) (
	*runnerScaler,
	*fakeScaleSetService,
	*fakeDockerClient,
	*fakeClock,
	*hostAdmissionCoordinator,
	context.CancelFunc,
) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	clock := &fakeClock{current: time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)}
	events := &eventRecorder{}
	api := newFakeScaleSetService(events)
	docker := newFakeDockerClient(events)
	cfg := config{
		profileID:         "profile-a",
		runnerImage:       "example/runner:latest",
		workerRevision:    testWorkerRevision,
		sessionOwner:      "pitcrew-profile-a",
		assumeUnversioned: true,
		namePrefix:        "pitcrew-runner",
		scaleDownDelay:    10 * time.Minute,
		stateDirectory:    stateDirectory,
	}
	target := targetSpec{
		key:             "repo-1234",
		registrationURL: "https://github.com/example/repository",
		repository:      "https://github.com/example/repository",
		maximum:         maximum,
		scaleSetName:    "pitcrew-profile-a-deadbeef",
	}
	hostAdmission := newHostAdmissionCoordinatorWithClient(client, cfg.profileID)
	scaler := newRunnerScaler(
		ctx,
		cfg,
		target,
		42,
		api,
		docker,
		clock,
		newAdmissionController(0),
		hostAdmission,
		newDiagnosticsRecorder(stateDirectory, "manager-instance", clock),
		testLogger(),
		nil,
		func(err error) {
			if err != nil && !errors.Is(err, context.Canceled) {
				t.Logf("scaler background error: %v", err)
			}
		},
	)
	suffix := 0
	scaler.nameSuffix = func() (string, error) {
		suffix++
		return fmt.Sprintf("suffix%02d", suffix), nil
	}
	return scaler, api, docker, clock, hostAdmission, cancel
}

// TestHostAdmissionDisabledCoordinatorIsExactNoOp proves a disabled
// coordinator (nil client, or a nil coordinator pointer) grants unconditionally
// and never touches a client, preserving "disabled/empty remains exact
// current behavior" at the coordinator layer itself.
func TestHostAdmissionDisabledCoordinatorIsExactNoOp(t *testing.T) {
	disabled := newHostAdmissionCoordinator(hostAdmissionConfig{}, "profile-a")
	if disabled.enabled() {
		t.Fatal("coordinator built from empty config reported enabled")
	}
	disabled.setTargetDemand("repo-one", 5)
	if got := disabled.currentDemand(); got != 0 {
		t.Fatalf("disabled coordinator reported nonzero demand: %d", got)
	}
	if _, outcome, err := disabled.acquire("slot", 5); err != nil || outcome != hostAdmissionGranted {
		t.Fatalf("disabled coordinator did not grant unconditionally: outcome=%v err=%v", outcome, err)
	}
	if err := disabled.renew("slot"); err != nil {
		t.Fatalf("disabled coordinator renew failed: %v", err)
	}
	if _, err := disabled.activate("slot"); err != nil {
		t.Fatalf("disabled coordinator activate failed: %v", err)
	}
	if err := disabled.release("slot"); err != nil {
		t.Fatalf("disabled coordinator release failed: %v", err)
	}

	var nilCoordinator *hostAdmissionCoordinator
	if nilCoordinator.enabled() {
		t.Fatal("nil coordinator pointer reported enabled")
	}
	nilCoordinator.setTargetDemand("repo-one", 5)
	if _, outcome, err := nilCoordinator.acquire("slot", 5); err != nil || outcome != hostAdmissionGranted {
		t.Fatalf("nil coordinator did not grant unconditionally: outcome=%v err=%v", outcome, err)
	}
}

// TestHostAdmissionBudgetDenyBlocksLaunchWithoutGitHubActivity proves a
// synthetic host budget of zero blocks a launch entirely before any GitHub
// JIT call is made, and leaves the capacity deficit visible through the
// existing admission-ceiling vocabulary.
func TestHostAdmissionBudgetDenyBlocksLaunchWithoutGitHubActivity(t *testing.T) {
	client := newFakeHostAdmissionClient(0)
	scaler, api, docker, _, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err == nil {
		t.Fatal("expected host budget deny to fail the launch")
	}
	if api.jitCalls != 0 {
		t.Fatalf("JIT was generated despite a denied host admission lease: %d calls", api.jitCalls)
	}
	if len(docker.launches) != 0 {
		t.Fatalf("a container was launched despite a denied host admission lease: %d", len(docker.launches))
	}
	snapshot := scaler.snapshot()
	if snapshot.blocking.reason != deficitAdmissionCeiling {
		t.Fatalf("unexpected blocking reason: %q", snapshot.blocking.reason)
	}
}

// TestHostAdmissionOutageBlocksOnlyNewLaunches proves a coordinator/socket
// outage withholds new launches while leaving an already-running worker and
// its registration untouched.
func TestHostAdmissionOutageBlocksOnlyNewLaunches(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, api, docker, _, _, cancel := newHostAdmissionTestScaler(t, 2, client)
	defer cancel()

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	if len(docker.launches) != 1 {
		t.Fatalf("expected one worker launched before the outage, got %d", len(docker.launches))
	}
	existingRunner := findRunner(t, scaler)

	client.acquireErr = errors.New("dial unix: connect: connection refused")
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 2); err == nil {
		t.Fatal("expected the host admission outage to fail the second launch")
	}
	if api.jitCalls != 1 {
		t.Fatalf("JIT was generated during the outage: %d calls", api.jitCalls)
	}
	if len(docker.stopRemove) != 0 {
		t.Fatal("the outage removed the existing worker")
	}
	if len(api.removeCalls) != 0 {
		t.Fatal("the outage removed the existing worker's registration")
	}
	snapshot := scaler.snapshot()
	if len(snapshot.runners) != 1 || snapshot.runners[0].containerID != existingRunner.containerID {
		t.Fatal("the existing worker did not survive the outage")
	}
}

// TestHostAdmissionJITFailureReleasesLease proves a JIT generation failure
// after a lease is acquired releases that lease exactly, leaving no lease
// leaked against the synthetic budget.
func TestHostAdmissionJITFailureReleasesLease(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, api, _, _, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()
	api.generateErrors = []error{errors.New("jit generation failed")}

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err == nil {
		t.Fatal("expected JIT failure to fail the launch")
	}
	if client.leaseCount() != 0 {
		t.Fatalf("lease was not released after JIT failure: %d outstanding", client.leaseCount())
	}
	if client.remainingBudget() != 1 {
		t.Fatalf("host budget was not restored after JIT failure: %d", client.remainingBudget())
	}
	if len(client.releaseCalls) != 1 {
		t.Fatalf("expected exactly one release call, got %d", len(client.releaseCalls))
	}
}

// TestHostAdmissionCreateFailureReleasesRegistrationAndLease proves a Docker
// create failure removes the GitHub registration and releases the lease
// exactly, since no container was ever created to also remove.
func TestHostAdmissionCreateFailureReleasesRegistrationAndLease(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, api, docker, _, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()
	docker.createErrors = []error{errors.New("docker create failed")}

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err == nil {
		t.Fatal("expected docker create failure to fail the launch")
	}
	if len(api.removeCalls) != 1 {
		t.Fatalf("expected exact registration removal after create failure, got %d", len(api.removeCalls))
	}
	if len(docker.launches) != 0 {
		t.Fatal("a launch was recorded despite create failure")
	}
	if client.leaseCount() != 0 {
		t.Fatalf("lease was not released after create failure: %d outstanding", client.leaseCount())
	}
}

// TestHostAdmissionActivateFailureRemovesContainerRegistrationAndLease proves
// a lease-activation failure after a successful create triggers exact
// cleanup of the created container, the GitHub registration, and the lease.
func TestHostAdmissionActivateFailureRemovesContainerRegistrationAndLease(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, api, docker, _, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()

	activationBlocked := errors.New("activation failed")
	// Inject the activation failure keyed by the deterministic slot name the
	// test scaler's nameSuffix produces for the first launch attempt:
	// "<namePrefix>-<targetKey>-<suffix>" (see nextRunnerName).
	client.mu.Lock()
	client.activateErrs["profile-a/pitcrew-runner-repo-1234-suffix01"] = activationBlocked
	client.mu.Unlock()

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err == nil {
		t.Fatal("expected activation failure to fail the launch")
	}
	if len(docker.launches) != 1 {
		t.Fatalf("expected exactly one container create attempt, got %d", len(docker.launches))
	}
	if len(docker.stopRemove) != 1 {
		t.Fatalf("expected the created container to be removed exactly once, got %d", len(docker.stopRemove))
	}
	if len(api.removeCalls) != 1 {
		t.Fatalf("expected exact registration removal after activation failure, got %d", len(api.removeCalls))
	}
	if client.leaseCount() != 0 {
		t.Fatalf("lease was not released after activation failure: %d outstanding", client.leaseCount())
	}
}

// TestHostAdmissionStartFailureRemovesContainerRegistrationAndLease proves a
// Docker start failure after a successful create and activate triggers exact
// cleanup of the container, the GitHub registration, and the lease. A worker
// process must never be left running without an active lease, and here it
// never started at all.
func TestHostAdmissionStartFailureRemovesContainerRegistrationAndLease(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, api, docker, _, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()
	docker.startErrors = []error{errors.New("docker start failed")}

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err == nil {
		t.Fatal("expected docker start failure to fail the launch")
	}
	if len(docker.starts) != 1 {
		t.Fatalf("expected exactly one start attempt, got %d", len(docker.starts))
	}
	if len(docker.stopRemove) != 1 {
		t.Fatalf("expected the created container to be removed exactly once, got %d", len(docker.stopRemove))
	}
	if len(api.removeCalls) != 1 {
		t.Fatalf("expected exact registration removal after start failure, got %d", len(api.removeCalls))
	}
	if client.leaseCount() != 0 {
		t.Fatalf("lease was not released after start failure: %d outstanding", client.leaseCount())
	}
}

// TestHostAdmissionCreatedContainerRecoveryStartsWithActiveLease proves a
// container a prior manager process created but never started can be safely
// started on recovery when its recorded lease is still valid.
func TestHostAdmissionCreatedContainerRecoveryStartsWithActiveLease(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, _, docker, _, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()
	client.preGrant("profile-a", "slot-recovered", true)

	container := recoveredContainer{
		containerID: "container-recovered",
		name:        "runner-recovered",
		runnerName:  "runner-recovered",
		runnerID:    99,
		targetKey:   "repo-1234",
		slotKey:     "repo-1234-99",
		revision:    testWorkerRevision,
		createdAt:   time.Now().Add(-time.Minute),
		unstarted:   true,
		hostSlotKey: "slot-recovered",
	}
	if err := scaler.recover(container); err != nil {
		t.Fatalf("recovery of a created container with an active lease failed: %v", err)
	}
	if len(docker.starts) != 1 || docker.starts[0] != "container-recovered" {
		t.Fatalf("recovered created container was not started: %+v", docker.starts)
	}
	if len(docker.stopRemove) != 0 {
		t.Fatal("recovered created container with a valid lease was removed instead of started")
	}
	snapshot := scaler.snapshot()
	if len(snapshot.runners) != 1 {
		t.Fatalf("expected one recovered runner, got %d", len(snapshot.runners))
	}
}

// TestHostAdmissionCreatedContainerRecoveryRemovesRejectedLease proves a
// created-but-unstarted container whose lease cannot be reacquired (budget
// exhausted, so a restart-discarded provisional lease cannot be granted
// again) is removed exactly instead of being started, and its exact GitHub
// registration is removed alongside the container so no JIT registration is
// left orphaned.
func TestHostAdmissionCreatedContainerRecoveryRemovesRejectedLease(t *testing.T) {
	client := newFakeHostAdmissionClient(0)
	scaler, api, docker, _, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()
	// No lease pre-granted and zero budget: reacquisition of "slot-missing"
	// will fail with admission.ErrBudgetExceeded.

	container := recoveredContainer{
		containerID: "container-orphaned",
		name:        "runner-orphaned",
		runnerName:  "runner-orphaned",
		runnerID:    100,
		targetKey:   "repo-1234",
		slotKey:     "repo-1234-100",
		revision:    testWorkerRevision,
		createdAt:   time.Now().Add(-time.Minute),
		unstarted:   true,
		hostSlotKey: "slot-missing",
	}
	if err := scaler.recover(container); err == nil {
		t.Fatal("expected recovery to fail for a rejected lease")
	}
	if len(docker.starts) != 0 {
		t.Fatal("an unstarted container with a rejected lease was started")
	}
	if len(docker.stopRemove) != 1 || docker.stopRemove[0] != "container-orphaned" {
		t.Fatalf("orphaned created container was not removed exactly: %+v", docker.stopRemove)
	}
	if len(api.removeCalls) != 1 || api.removeCalls[0] != 100 {
		t.Fatalf("orphaned created container's registration was not removed exactly: %+v", api.removeCalls)
	}
	snapshot := scaler.snapshot()
	if len(snapshot.runners) != 0 {
		t.Fatal("a container with a rejected lease was recorded as a runner")
	}
}

// TestHostAdmissionCreatedContainerRecoveryReacquiresDiscardedProvisional
// proves a created-but-unstarted container whose provisional lease was
// discarded by the host coordinator's own restart (e.g. the coordinator
// restarted independently of the manager) is successfully reacquired under
// the exact same slot key when budget is available, and the container is
// started rather than discarded.
func TestHostAdmissionCreatedContainerRecoveryReacquiresDiscardedProvisional(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, _, docker, _, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()
	// No lease pre-granted: the coordinator has no memory of this slot, as
	// if its own restart discarded the provisional lease. Budget is
	// available, so reacquisition under the same slot key must succeed.

	container := recoveredContainer{
		containerID: "container-reacquired",
		name:        "runner-reacquired",
		runnerName:  "runner-reacquired",
		runnerID:    104,
		targetKey:   "repo-1234",
		slotKey:     "repo-1234-104",
		revision:    testWorkerRevision,
		createdAt:   time.Now().Add(-time.Minute),
		unstarted:   true,
		hostSlotKey: "slot-discarded",
	}
	if err := scaler.recover(container); err != nil {
		t.Fatalf("recovery should reacquire a discarded provisional lease: %v", err)
	}
	if len(docker.starts) != 1 || docker.starts[0] != "container-reacquired" {
		t.Fatalf("reacquired created container was not started: %+v", docker.starts)
	}
	if len(docker.stopRemove) != 0 {
		t.Fatal("a container with a successfully reacquired lease was removed instead of started")
	}
	found := false
	for _, key := range client.acquireCalls {
		if key == "profile-a/slot-discarded" {
			found = true
		}
	}
	if !found {
		t.Fatal("recovery did not attempt to reacquire the discarded provisional lease")
	}
	snapshot := scaler.snapshot()
	if len(snapshot.runners) != 1 || snapshot.runners[0].hostSlotKey != "slot-discarded" {
		t.Fatalf("reacquired runner lost its lease identity: %+v", snapshot.runners)
	}
}

// TestHostAdmissionCreatedContainerRecoveryWithoutLeaseLabelIsRemoved proves a
// created-but-unstarted container that carries no host-admission slot label
// at all is treated as invalid and removed exactly, never started blind.
func TestHostAdmissionCreatedContainerRecoveryWithoutLeaseLabelIsRemoved(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, _, docker, _, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()

	container := recoveredContainer{
		containerID: "container-unlabeled",
		name:        "runner-unlabeled",
		runnerName:  "runner-unlabeled",
		runnerID:    101,
		targetKey:   "repo-1234",
		slotKey:     "repo-1234-101",
		revision:    testWorkerRevision,
		createdAt:   time.Now().Add(-time.Minute),
		unstarted:   true,
	}
	if err := scaler.recover(container); err == nil {
		t.Fatal("expected recovery to fail for a missing lease label")
	}
	if len(docker.starts) != 0 {
		t.Fatal("an unstarted, unlabeled container was started")
	}
	if len(docker.stopRemove) != 1 {
		t.Fatalf("unlabeled created container was not removed exactly: %+v", docker.stopRemove)
	}
}

// TestHostAdmissionActiveLeaseRestartAdoption proves an already-running
// container recovered across a manager restart re-confirms its lease and is
// adopted with the lease identity intact.
func TestHostAdmissionActiveLeaseRestartAdoption(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, _, _, _, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()
	client.preGrant("profile-a", "slot-running", true)

	container := recoveredContainer{
		containerID: "container-running",
		name:        "runner-running",
		runnerName:  "runner-running",
		runnerID:    102,
		targetKey:   "repo-1234",
		slotKey:     "repo-1234-102",
		revision:    testWorkerRevision,
		createdAt:   time.Now().Add(-time.Minute),
		hostSlotKey: "slot-running",
	}
	if err := scaler.recover(container); err != nil {
		t.Fatalf("recovery of an already-running container failed: %v", err)
	}
	snapshot := scaler.snapshot()
	if len(snapshot.runners) != 1 || snapshot.runners[0].hostSlotKey != "slot-running" {
		t.Fatalf("adopted runner lost its lease identity: %+v", snapshot.runners)
	}
	found := false
	for _, key := range client.activateCalls {
		if key == "profile-a/slot-running" {
			found = true
		}
	}
	if !found {
		t.Fatal("restart adoption did not re-confirm the lease via activate")
	}
}

// TestHostAdmissionActiveLeaseRestartAdoptionFailureSurvivesAsBusy proves that
// when a running container's lease cannot be re-confirmed across a restart,
// the worker is still adopted (busy-worker survival) and its lease identity
// is preserved rather than cleared, so a coordinator outage cannot erase the
// identity a later exit, scale-down, or shutdown needs to retry the release
// durably.
func TestHostAdmissionActiveLeaseRestartAdoptionFailureSurvivesAsBusy(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, _, docker, _, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()
	// No lease pre-granted: activation of "slot-unconfirmed" fails.

	container := recoveredContainer{
		containerID: "container-unconfirmed",
		name:        "runner-unconfirmed",
		runnerName:  "runner-unconfirmed",
		runnerID:    103,
		targetKey:   "repo-1234",
		slotKey:     "repo-1234-103",
		revision:    testWorkerRevision,
		createdAt:   time.Now().Add(-time.Minute),
		hostSlotKey: "slot-unconfirmed",
	}
	if err := scaler.recover(container); err != nil {
		t.Fatalf("running container recovery must survive an unconfirmed lease: %v", err)
	}
	if len(docker.stopRemove) != 0 {
		t.Fatal("a running worker was destroyed after an unconfirmed lease re-check")
	}
	snapshot := scaler.snapshot()
	if len(snapshot.runners) != 1 {
		t.Fatalf("expected the worker to survive, got %d runners", len(snapshot.runners))
	}
	if snapshot.runners[0].hostSlotKey != "slot-unconfirmed" {
		t.Fatalf("unconfirmed lease identity was incorrectly cleared: %+v", snapshot.runners[0])
	}
}

// TestHostAdmissionReleaseOnNaturalExit proves a worker's natural container
// exit releases its host admission lease exactly once.
func TestHostAdmissionReleaseOnNaturalExit(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, _, docker, _, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	runner := findRunner(t, scaler)
	if runner.hostSlotKey == "" {
		t.Fatal("started runner has no host admission lease identity")
	}

	// Drop demand to zero first so the natural exit below is not immediately
	// replaced by the reconcile loop's own demand-driven relaunch, which
	// would otherwise mask an exactly-once release behind a fresh lease.
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 0); err != nil {
		t.Fatal(err)
	}

	scaler.handleContainerExit(runner.containerID, exitStatus(0))

	if client.leaseCount() != 0 {
		t.Fatalf("lease was not released after natural exit: %d outstanding", client.leaseCount())
	}
	if len(client.releaseCalls) != 1 {
		t.Fatalf("expected exactly one release call on natural exit, got %d", len(client.releaseCalls))
	}
	_ = docker
}

// TestHostAdmissionReleaseOnScaleDown proves scaling down releases the
// removed worker's lease exactly once while leaving a surviving worker's
// lease untouched.
func TestHostAdmissionReleaseOnScaleDown(t *testing.T) {
	client := newFakeHostAdmissionClient(2)
	scaler, _, _, clock, _, cancel := newHostAdmissionTestScaler(t, 2, client)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 2); err != nil {
		t.Fatal(err)
	}
	markAllRunnersIdle(scaler)

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	// The scale-down debounce delay must elapse before the reconcile loop
	// actually removes the surplus worker.
	clock.advance(11 * time.Minute)
	if _, err := scaler.reconcileLocked(context.Background()); err != nil {
		t.Fatal(err)
	}

	snapshot := scaler.snapshot()
	if len(snapshot.runners) != 1 {
		t.Fatalf("expected exactly one surviving runner, got %d", len(snapshot.runners))
	}
	if len(client.releaseCalls) != 1 {
		t.Fatalf("expected exactly one release call after scale-down, got %d", len(client.releaseCalls))
	}
	if client.leaseCount() != 1 {
		t.Fatalf("expected exactly one outstanding lease for the survivor, got %d", client.leaseCount())
	}
}

// TestHostAdmissionRetirementReleasesLeaseThroughScaleDown proves target
// retirement (which routes through the same scale-down path) releases the
// retired worker's lease exactly once.
func TestHostAdmissionRetirementReleasesLeaseThroughScaleDown(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, _, _, _, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	markAllRunnersIdle(scaler)

	if err := scaler.beginRetirement(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := scaler.reconcileLocked(context.Background()); err != nil {
		t.Fatal(err)
	}

	if client.leaseCount() != 0 {
		t.Fatalf("retirement did not release the outstanding lease: %d", client.leaseCount())
	}
	if len(client.releaseCalls) != 1 {
		t.Fatalf("expected exactly one release call for retirement, got %d", len(client.releaseCalls))
	}
}

func TestHostAdmissionStaleWorkerRetirementReleasesLease(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, _, _, _, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()

	const hostSlotKey = "stale-host-slot"
	if _, err := client.Acquire("profile-a", hostSlotKey, 1); err != nil {
		t.Fatalf("seed host lease: %v", err)
	}
	if _, err := client.Activate("profile-a", hostSlotKey); err != nil {
		t.Fatalf("activate host lease: %v", err)
	}
	now := scaler.clock.now().UTC()
	scaler.mu.Lock()
	scaler.runners["stale-slot"] = &runnerRecord{
		key:         "stale-slot",
		targetKey:   scaler.target.key,
		repository:  scaler.target.repository,
		runnerName:  "stale-runner",
		runnerID:    77,
		containerID: "stale-container",
		container:   "stale-container",
		state:       runnerIdle,
		revision:    "stale-revision",
		stale:       true,
		startedAt:   now.Add(-time.Minute),
		updatedAt:   now,
		idleSince:   timePointer(now.Add(-time.Minute)),
		hostSlotKey: hostSlotKey,
	}
	scaler.mu.Unlock()

	if err := scaler.retireStaleRunners(context.Background()); err != nil {
		t.Fatalf("retire stale runner: %v", err)
	}
	client.mu.Lock()
	releases := append([]string(nil), client.releaseCalls...)
	_, stillHeld := client.leases[leaseSlotKey("profile-a", hostSlotKey)]
	client.mu.Unlock()
	if !reflect.DeepEqual(releases, []string{leaseSlotKey("profile-a", hostSlotKey)}) {
		t.Fatalf("stale retirement did not release the exact host lease: %#v", releases)
	}
	if stillHeld {
		t.Fatal("stale retirement left the host lease allocated")
	}
}

// TestHostAdmissionNoReleaseForBusyWorkerDuringShutdown proves a busy worker
// surviving shutdown never has its lease released, since shutdown's busy
// loop only stops the container and never touches registrations or leases.
func TestHostAdmissionNoReleaseForBusyWorkerDuringShutdown(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, _, docker, _, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	runner := findRunner(t, scaler)
	if err := scaler.HandleJobStarted(context.Background(), &scaleset.JobStarted{
		RunnerID:   int(runner.runnerID),
		RunnerName: runner.runnerName,
	}); err != nil {
		t.Fatal(err)
	}

	if err := scaler.shutdown(context.Background()); err != nil {
		t.Fatal(err)
	}

	if len(client.releaseCalls) != 0 {
		t.Fatalf("busy worker's lease was released during shutdown: %d calls", len(client.releaseCalls))
	}
	if client.leaseCount() != 1 {
		t.Fatalf("busy worker's lease is no longer tracked as outstanding: %d", client.leaseCount())
	}
	found := false
	for _, id := range docker.stops {
		if id == runner.containerID {
			found = true
		}
	}
	if !found {
		t.Fatal("busy worker container was not stopped during shutdown")
	}
	for _, id := range docker.stopRemove {
		if id == runner.containerID {
			t.Fatal("busy worker container was removed instead of only stopped")
		}
	}
}

// TestHostAdmissionMultipleTargetsShareProfileFairness proves the coordinator
// aggregates pending demand across multiple targets in the same profile, so
// host-level fairness sees the whole profile's need rather than one target
// in isolation.
func TestHostAdmissionMultipleTargetsShareProfileFairness(t *testing.T) {
	client := newFakeHostAdmissionClient(10)
	coordinator := newHostAdmissionCoordinatorWithClient(client, "profile-a")

	coordinator.setTargetDemand("repo-one", 2)
	coordinator.setTargetDemand("repo-two", 3)
	if got := coordinator.currentDemand(); got != 5 {
		t.Fatalf("expected aggregate demand 5 across targets, got %d", got)
	}

	coordinator.setTargetDemand("repo-one", 0)
	if got := coordinator.currentDemand(); got != 3 {
		t.Fatalf("expected aggregate demand 3 after repo-one settled, got %d", got)
	}

	client.mu.Lock()
	lastPublished := client.setDemandCalls[len(client.setDemandCalls)-1]
	client.mu.Unlock()
	if lastPublished != 3 {
		t.Fatalf("expected the last published demand to be 3, got %d", lastPublished)
	}
}

// TestHostAdmissionConcurrentDemandCannotExceedSyntheticBudget proves
// concurrent acquire attempts across many goroutines never grant more leases
// than the synthetic host budget allows.
func TestHostAdmissionConcurrentDemandCannotExceedSyntheticBudget(t *testing.T) {
	const budget = 3
	const attempts = 20
	client := newFakeHostAdmissionClient(budget)
	coordinator := newHostAdmissionCoordinatorWithClient(client, "profile-a")

	var waitGroup sync.WaitGroup
	var mu sync.Mutex
	granted := 0
	denied := 0
	waitGroup.Add(attempts)
	for i := 0; i < attempts; i++ {
		index := i
		go func() {
			defer waitGroup.Done()
			_, outcome, _ := coordinator.acquire(fmt.Sprintf("slot-%d", index), 0)
			mu.Lock()
			defer mu.Unlock()
			if outcome == hostAdmissionGranted {
				granted++
			} else {
				denied++
			}
		}()
	}
	waitGroup.Wait()

	if granted != budget {
		t.Fatalf("expected exactly %d grants under the synthetic budget, got %d", budget, granted)
	}
	if denied != attempts-budget {
		t.Fatalf("expected %d denials, got %d", attempts-budget, denied)
	}
	if client.leaseCount() != budget {
		t.Fatalf("outstanding lease count diverged from the granted count: %d", client.leaseCount())
	}
}

// TestHostAdmissionScaleToZeroReleasesEveryLease proves scaling a target all
// the way down to zero releases every outstanding lease and restores the
// synthetic budget to its starting value.
func TestHostAdmissionScaleToZeroReleasesEveryLease(t *testing.T) {
	client := newFakeHostAdmissionClient(2)
	scaler, _, _, clock, _, cancel := newHostAdmissionTestScaler(t, 2, client)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 2); err != nil {
		t.Fatal(err)
	}
	markAllRunnersIdle(scaler)

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	// The scale-down debounce delay must elapse before the reconcile loop
	// actually drains every surplus worker down to zero.
	clock.advance(11 * time.Minute)
	if _, err := scaler.reconcileLocked(context.Background()); err != nil {
		t.Fatal(err)
	}

	snapshot := scaler.snapshot()
	if len(snapshot.runners) != 0 {
		t.Fatalf("expected zero runners after scale-to-zero, got %d", len(snapshot.runners))
	}
	if client.remainingBudget() != 2 {
		t.Fatalf("synthetic budget was not fully restored after scale-to-zero: %d", client.remainingBudget())
	}
	if client.leaseCount() != 0 {
		t.Fatalf("expected zero outstanding leases after scale-to-zero, got %d", client.leaseCount())
	}
}

// TestHostAdmissionNoLeakedLeaseAfterRepeatedFailures proves that a sequence
// of induced failures at every launch stage never leaves a net outstanding
// lease against the synthetic budget.
func TestHostAdmissionNoLeakedLeaseAfterRepeatedFailures(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, api, docker, _, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()

	api.generateErrors = []error{errors.New("jit failed")}
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err == nil {
		t.Fatal("expected JIT failure")
	}
	if client.leaseCount() != 0 {
		t.Fatalf("lease leaked after JIT failure: %d", client.leaseCount())
	}

	docker.createErrors = []error{errors.New("create failed")}
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err == nil {
		t.Fatal("expected create failure")
	}
	if client.leaseCount() != 0 {
		t.Fatalf("lease leaked after create failure: %d", client.leaseCount())
	}

	docker.startErrors = []error{errors.New("start failed")}
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err == nil {
		t.Fatal("expected start failure")
	}
	if client.leaseCount() != 0 {
		t.Fatalf("lease leaked after start failure: %d", client.leaseCount())
	}
	if client.remainingBudget() != 1 {
		t.Fatalf("synthetic budget was not fully restored after failures: %d", client.remainingBudget())
	}
}

// TestHostAdmissionReleaseFailureOnNaturalExitIsRetried proves a transient
// coordinator failure releasing a lease after a natural container exit
// durably enqueues a pending release record rather than stranding the
// lease, and that the next reconcile cycle's retry resolves it exactly.
func TestHostAdmissionReleaseFailureOnNaturalExitIsRetried(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, _, _, clock, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	runner := findRunner(t, scaler)
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	client.releaseErrs[leaseSlotKey("profile-a", runner.hostSlotKey)] = errors.New("coordinator unavailable")

	scaler.handleContainerExit(runner.containerID, exitStatus(0))

	if scaler.pendingHostLeaseReleaseCount() != 1 {
		t.Fatalf("expected a durable pending release record after a transient failure, got %d", scaler.pendingHostLeaseReleaseCount())
	}
	if client.leaseCount() != 1 {
		t.Fatalf("lease was released despite a failed release call: %d outstanding", client.leaseCount())
	}

	clock.advance(hostLeaseReleaseRetryDelay)
	if _, err := scaler.reconcileLocked(context.Background()); err != nil {
		t.Fatal(err)
	}
	if scaler.pendingHostLeaseReleaseCount() != 0 {
		t.Fatalf("pending release record was not resolved by the retry, got %d", scaler.pendingHostLeaseReleaseCount())
	}
	if client.leaseCount() != 0 {
		t.Fatalf("lease was not eventually released, %d outstanding", client.leaseCount())
	}
}

// TestHostAdmissionReleaseFailureOnScaleDownIsRetried proves a transient
// coordinator failure releasing a lease during scale-down durably enqueues
// a pending release record and that a later reconcile resolves it exactly.
func TestHostAdmissionReleaseFailureOnScaleDownIsRetried(t *testing.T) {
	client := newFakeHostAdmissionClient(2)
	scaler, _, _, clock, _, cancel := newHostAdmissionTestScaler(t, 2, client)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 2); err != nil {
		t.Fatal(err)
	}
	markAllRunnersIdle(scaler)
	snapshot := scaler.snapshot()
	if len(snapshot.runners) != 2 {
		t.Fatalf("expected two runners, got %d", len(snapshot.runners))
	}
	client.releaseErrs[leaseSlotKey("profile-a", snapshot.runners[0].hostSlotKey)] = errors.New("coordinator unavailable")
	client.releaseErrs[leaseSlotKey("profile-a", snapshot.runners[1].hostSlotKey)] = errors.New("coordinator unavailable")

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	clock.advance(11 * time.Minute)
	if _, err := scaler.reconcileLocked(context.Background()); err == nil {
		t.Fatal("expected the scale-down reconcile to surface the transient release failure")
	}

	if scaler.pendingHostLeaseReleaseCount() != 1 {
		t.Fatalf("expected exactly one durable pending release record, got %d", scaler.pendingHostLeaseReleaseCount())
	}
	after := scaler.snapshot()
	if len(after.runners) != 1 {
		t.Fatalf("expected exactly one surviving runner after scale-down, got %d", len(after.runners))
	}

	clock.advance(hostLeaseReleaseRetryDelay)
	if _, err := scaler.reconcileLocked(context.Background()); err != nil {
		t.Fatal(err)
	}
	if scaler.pendingHostLeaseReleaseCount() != 0 {
		t.Fatalf("pending release record was not resolved by the retry, got %d", scaler.pendingHostLeaseReleaseCount())
	}
}

// TestHostAdmissionReleaseFailureOnDelayedCleanupIsRetried proves a
// transient coordinator failure releasing a lease during delayed container
// cleanup (docker.stopAndRemove initially failing during scale-down, then
// succeeding on retry) durably enqueues a pending release record and that a
// later reconcile resolves it exactly.
func TestHostAdmissionReleaseFailureOnDelayedCleanupIsRetried(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, _, docker, clock, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	runner := findRunner(t, scaler)
	markAllRunnersIdle(scaler)

	docker.stopRemoveErrors[runner.containerID] = []error{errors.New("stop failed")}
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	clock.advance(11 * time.Minute)
	if _, err := scaler.reconcileLocked(context.Background()); err == nil {
		t.Fatal("expected the scale-down reconcile to surface the transient stop failure")
	}

	snapshot := scaler.snapshot()
	if len(snapshot.runners) != 1 || snapshot.runners[0].state != runnerCleanupPending {
		t.Fatalf("expected the runner to be pending delayed cleanup, got %+v", snapshot.runners)
	}

	client.releaseErrs[leaseSlotKey("profile-a", runner.hostSlotKey)] = errors.New("coordinator unavailable")
	if err := scaler.retryCleanupPending(context.Background()); err == nil {
		t.Fatal("expected delayed cleanup to surface the transient release failure")
	}
	if scaler.pendingHostLeaseReleaseCount() != 1 {
		t.Fatalf("expected a durable pending release record after a transient failure, got %d", scaler.pendingHostLeaseReleaseCount())
	}
	if client.leaseCount() != 1 {
		t.Fatalf("lease was released despite a failed release call: %d outstanding", client.leaseCount())
	}

	clock.advance(hostLeaseReleaseRetryDelay)
	if _, err := scaler.reconcileLocked(context.Background()); err != nil {
		t.Fatal(err)
	}
	if scaler.pendingHostLeaseReleaseCount() != 0 {
		t.Fatalf("pending release record was not resolved by the retry, got %d", scaler.pendingHostLeaseReleaseCount())
	}
	if client.leaseCount() != 0 {
		t.Fatalf("lease was not eventually released, %d outstanding", client.leaseCount())
	}
}

// TestHostAdmissionReleaseFailureOnShutdownIsRetried proves a transient
// coordinator failure releasing an idle worker's lease during shutdown
// durably enqueues a pending release record, and that retrying releases
// (independent of shutdown) resolves it exactly without needing to remove
// or stop any additional worker.
func TestHostAdmissionReleaseFailureOnShutdownIsRetried(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, _, _, clock, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	runner := findRunner(t, scaler)
	markAllRunnersIdle(scaler)
	client.releaseErrs[leaseSlotKey("profile-a", runner.hostSlotKey)] = errors.New("coordinator unavailable")

	if err := scaler.shutdown(context.Background()); err == nil {
		t.Fatal("expected shutdown to surface the transient release failure")
	}

	if scaler.pendingHostLeaseReleaseCount() != 1 {
		t.Fatalf("expected a durable pending release record after a transient failure, got %d", scaler.pendingHostLeaseReleaseCount())
	}
	if client.leaseCount() != 1 {
		t.Fatalf("lease was released despite a failed release call: %d outstanding", client.leaseCount())
	}

	clock.advance(hostLeaseReleaseRetryDelay)
	if err := scaler.retryPendingHostLeaseReleases(); err != nil {
		t.Fatal(err)
	}
	if scaler.pendingHostLeaseReleaseCount() != 0 {
		t.Fatalf("pending release record was not resolved by the retry, got %d", scaler.pendingHostLeaseReleaseCount())
	}
	if client.leaseCount() != 0 {
		t.Fatalf("lease was not eventually released, %d outstanding", client.leaseCount())
	}
}

// TestHostAdmissionReleaseFailureOnAbandonLaunchIsRetried proves a transient
// coordinator failure releasing a lease while abandoning a launch after
// container create failure durably enqueues a pending release record
// instead of leaking the lease, and that a later retry resolves it exactly.
func TestHostAdmissionReleaseFailureOnAbandonLaunchIsRetried(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, _, docker, clock, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()

	docker.createErrors = []error{errors.New("create failed")}
	client.releaseErrs[leaseSlotKey("profile-a", "pitcrew-runner-repo-1234-suffix01")] = errors.New("coordinator unavailable")

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err == nil {
		t.Fatal("expected create failure")
	}

	if scaler.pendingHostLeaseReleaseCount() != 1 {
		t.Fatalf("expected a durable pending release record after an abandoned launch, got %d", scaler.pendingHostLeaseReleaseCount())
	}
	if client.leaseCount() != 1 {
		t.Fatalf("lease was released despite a failed release call: %d outstanding", client.leaseCount())
	}

	clock.advance(hostLeaseReleaseRetryDelay)
	if err := scaler.retryPendingHostLeaseReleases(); err != nil {
		t.Fatal(err)
	}
	if scaler.pendingHostLeaseReleaseCount() != 0 {
		t.Fatalf("pending release record was not resolved by the retry, got %d", scaler.pendingHostLeaseReleaseCount())
	}
	if client.leaseCount() != 0 {
		t.Fatalf("lease was not eventually released, %d outstanding", client.leaseCount())
	}
}

// TestHostAdmissionPendingReleaseRetrySurvivesManagerRestart proves a
// pending host lease release record persists across a simulated manager
// restart (a fresh scaler instance backed by the same state directory) and
// that it is eventually resolved without ever touching Docker or GitHub
// demand.
func TestHostAdmissionPendingReleaseRetrySurvivesManagerRestart(t *testing.T) {
	directory := projectTestDirectory(t)
	client := newFakeHostAdmissionClient(1)
	scaler, _, _, _, _, cancel := newHostAdmissionTestScalerInDirectory(t, 1, client, directory)
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	runner := findRunner(t, scaler)
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	client.releaseErrs[leaseSlotKey("profile-a", runner.hostSlotKey)] = errors.New("coordinator unavailable")

	scaler.handleContainerExit(runner.containerID, exitStatus(0))
	if scaler.pendingHostLeaseReleaseCount() != 1 {
		t.Fatal("failed lease release was not retained as pending before restart")
	}
	cancel()

	path := hostLeaseCleanupPath(directory, runner.targetKey)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read persisted host lease cleanup: %v", err)
	}
	document, err := parseHostLeaseCleanupDocument(data, runner.targetKey)
	if err != nil {
		t.Fatalf("persisted host lease cleanup is invalid: %v", err)
	}
	if len(document.Records) != 1 ||
		document.Records[0].HostSlotKey != runner.hostSlotKey ||
		document.Records[0].RunnerKey != runner.key {
		t.Fatalf("persisted host lease cleanup lost the lease identity: %#v", document.Records)
	}

	restarted, _, restartedDocker, restartedClock, _, restartedCancel := newHostAdmissionTestScalerInDirectory(
		t, 1, client, directory,
	)
	defer restartedCancel()
	if restarted.pendingHostLeaseReleaseCount() != 1 {
		t.Fatal("restarted scaler lost the pending host lease release")
	}

	restartedClock.advance(hostLeaseReleaseRetryDelay)
	if err := restarted.retryPendingHostLeaseReleases(); err != nil {
		t.Fatal(err)
	}
	if restarted.pendingHostLeaseReleaseCount() != 0 {
		t.Fatalf("restarted retry did not resolve the pending release, got %d", restarted.pendingHostLeaseReleaseCount())
	}
	if client.leaseCount() != 0 {
		t.Fatalf("lease was not eventually released after restart, %d outstanding", client.leaseCount())
	}
	if len(restartedDocker.stops) != 0 || len(restartedDocker.stopRemove) != 0 {
		t.Fatal("pending release retry touched Docker, which it must never do")
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("resolved pending host lease cleanup state was not cleared")
	}
}

// TestHostAdmissionRunningRecoveryOutagePreservesKeyForLaterRelease proves
// that when recoverRunning cannot re-confirm a lease across a restart
// (coordinator outage), the worker's exact lease identity is preserved
// rather than cleared, so a later natural exit can still durably release
// (or enqueue) it.
func TestHostAdmissionRunningRecoveryOutagePreservesKeyForLaterRelease(t *testing.T) {
	client := newFakeHostAdmissionClient(1)
	scaler, _, docker, _, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()
	// No lease pre-granted: activation of "slot-outage" fails, simulating a
	// coordinator outage across a manager restart.

	container := recoveredContainer{
		containerID: "container-outage",
		name:        "runner-outage",
		runnerName:  "runner-outage",
		runnerID:    200,
		targetKey:   "repo-1234",
		slotKey:     "repo-1234-200",
		revision:    testWorkerRevision,
		createdAt:   time.Now().Add(-time.Minute),
		hostSlotKey: "slot-outage",
	}
	if err := scaler.recover(container); err != nil {
		t.Fatalf("running container recovery must survive a coordinator outage: %v", err)
	}
	runner := findRunner(t, scaler)
	if runner.hostSlotKey != "slot-outage" {
		t.Fatalf("recovered running worker lost its lease identity: %+v", runner)
	}

	// Now grant the lease so a later exit's release attempt can succeed
	// exactly, proving the preserved identity is usable.
	client.preGrant("profile-a", "slot-outage", true)
	scaler.handleContainerExit(runner.containerID, exitStatus(0))

	if len(client.releaseCalls) != 1 || client.releaseCalls[0] != "profile-a/slot-outage" {
		t.Fatalf("preserved lease identity was not used for exact release on exit: %#v", client.releaseCalls)
	}
	if client.leaseCount() != 0 {
		t.Fatalf("lease was not released using the preserved identity: %d outstanding", client.leaseCount())
	}
	_ = docker
}

// TestHostAdmissionCreatedRecoveryDiscardRemovesRegistration proves a
// created-but-unstarted container discarded during recovery (lease cannot
// be reacquired) also has its exact GitHub registration removed, so no JIT
// registration is left orphaned.
func TestHostAdmissionCreatedRecoveryDiscardRemovesRegistration(t *testing.T) {
	client := newFakeHostAdmissionClient(0)
	scaler, api, docker, _, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()

	container := recoveredContainer{
		containerID: "container-discard",
		name:        "runner-discard",
		runnerName:  "runner-discard",
		runnerID:    201,
		targetKey:   "repo-1234",
		slotKey:     "repo-1234-201",
		revision:    testWorkerRevision,
		createdAt:   time.Now().Add(-time.Minute),
		unstarted:   true,
		hostSlotKey: "slot-discard",
	}
	if err := scaler.recover(container); err == nil {
		t.Fatal("expected recovery to fail when the lease cannot be reacquired")
	}
	if len(docker.stopRemove) != 1 || docker.stopRemove[0] != "container-discard" {
		t.Fatalf("discarded container was not removed exactly: %+v", docker.stopRemove)
	}
	if len(api.removeCalls) != 1 || api.removeCalls[0] != 201 {
		t.Fatalf("discarded container's registration was not removed exactly: %#v", api.removeCalls)
	}
}

// TestHostAdmissionCreatedRecoveryDiscardRegistrationFailureIsRetried
// proves a registration removal failure while discarding an unstartable
// recovered container is retried durably through the same pending
// registration cleanup ledger used for exited workers, never left orphaned.
func TestHostAdmissionCreatedRecoveryDiscardRegistrationFailureIsRetried(t *testing.T) {
	client := newFakeHostAdmissionClient(0)
	scaler, api, _, clock, _, cancel := newHostAdmissionTestScaler(t, 1, client)
	defer cancel()
	api.removeErrors[202] = errors.New("registration removal failed")

	container := recoveredContainer{
		containerID: "container-discard-retry",
		name:        "runner-discard-retry",
		runnerName:  "runner-discard-retry",
		runnerID:    202,
		targetKey:   "repo-1234",
		slotKey:     "repo-1234-202",
		revision:    testWorkerRevision,
		createdAt:   time.Now().Add(-time.Minute),
		unstarted:   true,
		hostSlotKey: "slot-discard-retry",
	}
	if err := scaler.recover(container); err == nil {
		t.Fatal("expected recovery to fail when the lease cannot be reacquired")
	}
	if scaler.pendingRegistrationCount() != 1 {
		t.Fatalf("expected the failed registration removal to be retained as pending, got %d", scaler.pendingRegistrationCount())
	}

	clock.advance(registrationCleanupRetryDelay)
	delete(api.removeErrors, 202)
	if err := scaler.retryPendingRegistrations(context.Background()); err != nil {
		t.Fatal(err)
	}
	if scaler.pendingRegistrationCount() != 0 {
		t.Fatalf("pending registration removal was not resolved by the retry, got %d", scaler.pendingRegistrationCount())
	}
	if !reflect.DeepEqual(api.removeCalls, []int64{202, 202}) {
		t.Fatalf("expected exactly two registration removal attempts, got %#v", api.removeCalls)
	}
}
