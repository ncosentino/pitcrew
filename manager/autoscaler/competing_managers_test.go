package main

import (
	"errors"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/ncosentino/pitcrew/manager/admission"
)

type coordinatorLeaseClient struct {
	coordinator *admission.Coordinator
}

func (c coordinatorLeaseClient) SetDemand(profileID string, pending int) error {
	return c.coordinator.SetDemand(profileID, pending)
}

func (c coordinatorLeaseClient) Acquire(
	profileID, slotKey string,
	pendingDemand int,
) (admission.Lease, error) {
	return c.coordinator.Acquire(profileID, slotKey, pendingDemand)
}

func (c coordinatorLeaseClient) Adopt(profileID, slotKey string) (admission.Lease, error) {
	return c.coordinator.Adopt(profileID, slotKey)
}

func (c coordinatorLeaseClient) BeginAdoption(profileID string) error {
	return c.coordinator.BeginAdoption(profileID)
}

func (c coordinatorLeaseClient) CompleteAdoption(profileID string) error {
	return c.coordinator.CompleteAdoption(profileID)
}

func (c coordinatorLeaseClient) Renew(profileID, slotKey string) (admission.Lease, error) {
	return c.coordinator.Renew(profileID, slotKey)
}

func (c coordinatorLeaseClient) Activate(profileID, slotKey string) (admission.Lease, error) {
	return c.coordinator.Activate(profileID, slotKey)
}

func (c coordinatorLeaseClient) Release(profileID, slotKey string) error {
	return c.coordinator.Release(profileID, slotKey)
}

func (c coordinatorLeaseClient) Reconcile(profileID, slotKey, evidence string) error {
	return c.coordinator.Reconcile(profileID, slotKey, evidence)
}

func (c coordinatorLeaseClient) Status() (admission.Snapshot, error) {
	return c.coordinator.Status()
}

type competingManagerActor interface {
	setDemand(int) error
	acquire(string) error
	release(string) error
}

type fixedCompetingManager struct {
	coordinator *admission.Coordinator
	profileID   string

	mu     sync.Mutex
	demand int
}

func (m *fixedCompetingManager) setDemand(pending int) error {
	m.mu.Lock()
	m.demand = max(pending, 0)
	m.mu.Unlock()
	return m.coordinator.SetDemand(m.profileID, max(pending, 0))
}

func (m *fixedCompetingManager) acquire(slotKey string) error {
	m.mu.Lock()
	pending := max(m.demand, 1)
	m.mu.Unlock()
	if _, err := m.coordinator.Acquire(m.profileID, slotKey, pending); err != nil {
		m.mu.Lock()
		remaining := m.demand
		m.mu.Unlock()
		_ = m.coordinator.SetDemand(m.profileID, remaining)
		return err
	}
	if _, err := m.coordinator.Activate(m.profileID, slotKey); err != nil {
		return err
	}
	m.mu.Lock()
	m.demand = max(m.demand-1, 0)
	remaining := m.demand
	m.mu.Unlock()
	return m.coordinator.SetDemand(m.profileID, remaining)
}

func (m *fixedCompetingManager) release(slotKey string) error {
	return m.coordinator.Release(m.profileID, slotKey)
}

type autoscaledCompetingManager struct {
	coordinator *hostAdmissionCoordinator
	targetKey   string
}

func (m *autoscaledCompetingManager) setDemand(pending int) error {
	m.coordinator.setTargetDemand(m.targetKey, pending)
	return nil
}

func (m *autoscaledCompetingManager) acquire(slotKey string) error {
	if _, _, err := m.coordinator.acquire(m.targetKey, slotKey); err != nil {
		return err
	}
	_, err := m.coordinator.activate(slotKey)
	return err
}

func (m *autoscaledCompetingManager) release(slotKey string) error {
	return m.coordinator.release(slotKey)
}

func newCompetingManagerActor(
	mode string,
	coordinator *admission.Coordinator,
	profileID string,
) competingManagerActor {
	switch mode {
	case "fixed":
		return &fixedCompetingManager{
			coordinator: coordinator,
			profileID:   profileID,
		}
	case "autoscaled":
		return &autoscaledCompetingManager{
			coordinator: newHostAdmissionCoordinatorWithClient(
				coordinatorLeaseClient{coordinator: coordinator},
				profileID,
			),
			targetKey: "target-" + profileID,
		}
	default:
		panic("unsupported competing-manager mode " + mode)
	}
}

func TestHostWideAdoptionFenceBlocksOtherManagersUntilEveryPassCompletes(t *testing.T) {
	coordinator := admission.OpenMemory(admission.SystemClock{}, time.Minute)
	if err := coordinator.ApplyPolicy(admission.HostPolicy{
		Generation: 1,
		TotalUnits: 2,
		Profiles: []admission.ProfilePolicy{
			{ProfileID: "alpha", UnitCost: 1},
			{ProfileID: "beta", UnitCost: 1},
		},
	}); err != nil {
		t.Fatal(err)
	}
	alpha := newHostAdmissionCoordinatorWithClient(
		coordinatorLeaseClient{coordinator: coordinator},
		"alpha",
	)
	beta := newHostAdmissionCoordinatorWithClient(
		coordinatorLeaseClient{coordinator: coordinator},
		"beta",
	)
	if err := alpha.beginAdoption(); err != nil {
		t.Fatal(err)
	}
	if err := beta.beginAdoption(); err != nil {
		t.Fatal(err)
	}
	if _, err := coordinator.Adopt("alpha", "target-one"); err != nil {
		t.Fatal(err)
	}
	if _, err := coordinator.Adopt("alpha", "target-two"); err != nil {
		t.Fatal(err)
	}
	beta.setTargetDemand("beta-target", 1)
	if _, _, err := beta.acquire("beta-target", "new-beta"); !errors.Is(err, errHostAdmissionWithheld) {
		t.Fatalf("another manager acquired while adoption was incomplete: %v", err)
	}
	if err := alpha.completeAdoption(); err != nil {
		t.Fatal(err)
	}
	if _, _, err := beta.acquire("beta-target", "new-beta"); !errors.Is(err, errHostAdmissionWithheld) {
		t.Fatalf("one manager completion cleared another manager's fence: %v", err)
	}
	if err := beta.completeAdoption(); err != nil {
		t.Fatal(err)
	}
	if _, _, err := beta.acquire("beta-target", "new-beta"); !errors.Is(err, errHostAdmissionWithheld) {
		t.Fatalf("above-budget adopted workers did not preserve ordinary budget enforcement: %v", err)
	}
}

func TestCompetingManagerModeMatrixNeverExceedsBudget(t *testing.T) {
	modePairs := [][2]string{
		{"fixed", "fixed"},
		{"fixed", "autoscaled"},
		{"autoscaled", "autoscaled"},
	}
	for _, pair := range modePairs {
		t.Run(pair[0]+"-"+pair[1], func(t *testing.T) {
			coordinator := admission.OpenMemory(admission.SystemClock{}, time.Minute)
			if err := coordinator.ApplyPolicy(admission.HostPolicy{
				Generation: 1,
				TotalUnits: 2,
				Profiles: []admission.ProfilePolicy{
					{
						ProfileID:     "alpha",
						UnitCost:      1,
						ReservedUnits: 1,
						Borrowable:    false,
					},
					{
						ProfileID:     "beta",
						UnitCost:      1,
						ReservedUnits: 1,
						Borrowable:    false,
					},
				},
			}); err != nil {
				t.Fatalf("apply synthetic policy: %v", err)
			}
			actors := map[string]competingManagerActor{
				"alpha": newCompetingManagerActor(pair[0], coordinator, "alpha"),
				"beta":  newCompetingManagerActor(pair[1], coordinator, "beta"),
			}
			for _, actor := range actors {
				if err := actor.setDemand(2); err != nil {
					t.Fatalf("publish demand: %v", err)
				}
			}

			type attempt struct {
				profileID string
				slotKey   string
				err       error
			}
			attempts := make(chan attempt, 4)
			var waitGroup sync.WaitGroup
			for _, profileID := range []string{"alpha", "beta"} {
				for index := 0; index < 2; index++ {
					waitGroup.Add(1)
					go func(profileID string, index int) {
						defer waitGroup.Done()
						slotKey := profileID + "-" + strconv.Itoa(index)
						attempts <- attempt{
							profileID: profileID,
							slotKey:   slotKey,
							err:       actors[profileID].acquire(slotKey),
						}
					}(profileID, index)
				}
			}
			waitGroup.Wait()
			close(attempts)

			successfulSlots := make(map[string]string, 2)
			denials := 0
			for attempt := range attempts {
				if attempt.err == nil {
					successfulSlots[attempt.profileID] = attempt.slotKey
					continue
				}
				if !errors.Is(attempt.err, admission.ErrBudgetExceeded) {
					t.Fatalf("unexpected acquisition error: %v", attempt.err)
				}
				denials++
			}
			if len(successfulSlots) != 2 || denials != 2 {
				t.Fatalf(
					"expected one admitted slot per profile and two denials, got slots=%v denials=%d",
					successfulSlots,
					denials,
				)
			}
			snapshot, err := coordinator.Status()
			if err != nil {
				t.Fatalf("read synthetic status: %v", err)
			}
			if len(snapshot.Leases) != 2 || snapshot.AvailableUnits != 0 {
				t.Fatalf("synthetic budget was oversubscribed: %+v", snapshot)
			}

			if err := actors["alpha"].release(successfulSlots["alpha"]); err != nil {
				t.Fatalf("release alpha: %v", err)
			}
			if err := actors["alpha"].setDemand(1); err != nil {
				t.Fatalf("republish alpha demand: %v", err)
			}
			if err := actors["alpha"].acquire("alpha-replacement"); err != nil {
				t.Fatalf("released units did not become eligible: %v", err)
			}

			if err := coordinator.ApplyPolicy(admission.HostPolicy{
				Generation: 2,
				TotalUnits: 1,
				Profiles: []admission.ProfilePolicy{
					{ProfileID: "alpha", UnitCost: 1},
					{ProfileID: "beta", UnitCost: 1},
				},
			}); err != nil {
				t.Fatalf("reduce synthetic budget: %v", err)
			}
			snapshot, err = coordinator.Status()
			if err != nil {
				t.Fatalf("read reduced-budget status: %v", err)
			}
			if len(snapshot.Leases) != 2 {
				t.Fatalf("reduced budget revoked active leases: %+v", snapshot.Leases)
			}
			if err := actors["alpha"].acquire("alpha-over-budget"); !errors.Is(
				err,
				admission.ErrBudgetExceeded,
			) {
				t.Fatalf("reduced budget admitted new work: %v", err)
			}

			if err := actors["alpha"].release("alpha-replacement"); err != nil {
				t.Fatalf("release alpha replacement: %v", err)
			}
			if err := actors["beta"].release(successfulSlots["beta"]); err != nil {
				t.Fatalf("release beta: %v", err)
			}
			if err := actors["alpha"].setDemand(0); err != nil {
				t.Fatalf("clear alpha demand: %v", err)
			}
			if err := actors["beta"].setDemand(0); err != nil {
				t.Fatalf("clear beta demand: %v", err)
			}
			snapshot, err = coordinator.Status()
			if err != nil {
				t.Fatalf("read drained status: %v", err)
			}
			if len(snapshot.Leases) != 0 {
				t.Fatalf("scale-to-zero left active leases: %+v", snapshot.Leases)
			}
		})
	}
}

func TestBorrowableReservationNeverPreemptsActiveAutoscaledWorker(t *testing.T) {
	coordinator := admission.OpenMemory(admission.SystemClock{}, time.Minute)
	if err := coordinator.ApplyPolicy(admission.HostPolicy{
		Generation: 1,
		TotalUnits: 2,
		Profiles: []admission.ProfilePolicy{
			{
				ProfileID:     "fixed-owner",
				UnitCost:      1,
				ReservedUnits: 1,
				Borrowable:    true,
			},
			{ProfileID: "autoscaled-borrower", UnitCost: 1},
		},
	}); err != nil {
		t.Fatalf("apply borrowing policy: %v", err)
	}
	owner := newCompetingManagerActor("fixed", coordinator, "fixed-owner")
	borrower := newCompetingManagerActor(
		"autoscaled",
		coordinator,
		"autoscaled-borrower",
	)
	if err := owner.setDemand(0); err != nil {
		t.Fatalf("clear owner demand: %v", err)
	}
	if err := borrower.setDemand(2); err != nil {
		t.Fatalf("publish borrower demand: %v", err)
	}
	for _, slotKey := range []string{"borrower-0", "borrower-1"} {
		if err := borrower.acquire(slotKey); err != nil {
			t.Fatalf("borrow unused reservation: %v", err)
		}
	}
	if err := owner.setDemand(1); err != nil {
		t.Fatalf("publish owner demand: %v", err)
	}
	if err := owner.acquire("owner-0"); !errors.Is(err, admission.ErrBudgetExceeded) {
		t.Fatalf("active borrowed lease was preempted: %v", err)
	}
	if err := borrower.release("borrower-0"); err != nil {
		t.Fatalf("release borrowed unit: %v", err)
	}
	if err := owner.acquire("owner-0"); err != nil {
		t.Fatalf("owner did not receive naturally released unit: %v", err)
	}
	snapshot, err := coordinator.Status()
	if err != nil {
		t.Fatalf("read borrowing status: %v", err)
	}
	if len(snapshot.Leases) != 2 {
		t.Fatalf("borrowing handoff removed an unrelated active lease: %+v", snapshot.Leases)
	}
}

func TestCoordinatorRestartAndProfileRemovalPreserveActiveLease(t *testing.T) {
	stateDirectory := t.TempDir()
	coordinator, err := admission.OpenFile(
		stateDirectory,
		admission.SystemClock{},
		time.Minute,
	)
	if err != nil {
		t.Fatalf("open coordinator: %v", err)
	}
	if err := coordinator.ApplyPolicy(admission.HostPolicy{
		Generation: 1,
		TotalUnits: 2,
		Profiles: []admission.ProfilePolicy{
			{ProfileID: "fixed-a", UnitCost: 1},
			{ProfileID: "autoscaled-b", UnitCost: 1},
		},
	}); err != nil {
		t.Fatalf("apply restart policy: %v", err)
	}
	if _, err := coordinator.Acquire("fixed-a", "active-slot", 1); err != nil {
		t.Fatalf("acquire active lease: %v", err)
	}
	if _, err := coordinator.Activate("fixed-a", "active-slot"); err != nil {
		t.Fatalf("activate lease: %v", err)
	}
	if _, err := coordinator.Acquire("autoscaled-b", "provisional-slot", 1); err != nil {
		t.Fatalf("acquire provisional lease: %v", err)
	}

	restarted, err := admission.OpenFile(
		stateDirectory,
		admission.SystemClock{},
		time.Minute,
	)
	if err != nil {
		t.Fatalf("restart coordinator: %v", err)
	}
	snapshot, err := restarted.Status()
	if err != nil {
		t.Fatalf("read restarted status: %v", err)
	}
	if len(snapshot.Leases) != 1 ||
		snapshot.Leases[0].ProfileID != "fixed-a" ||
		snapshot.Leases[0].Status != admission.LeaseActive {
		t.Fatalf("restart did not preserve only the active lease: %+v", snapshot.Leases)
	}

	if err := restarted.ApplyPolicy(admission.HostPolicy{
		Generation: 2,
		TotalUnits: 1,
		Profiles: []admission.ProfilePolicy{
			{ProfileID: "autoscaled-b", UnitCost: 1},
		},
	}); err != nil {
		t.Fatalf("remove fixed profile from policy: %v", err)
	}
	snapshot, err = restarted.Status()
	if err != nil {
		t.Fatalf("read removed-profile status: %v", err)
	}
	if len(snapshot.Leases) != 1 || snapshot.Leases[0].ProfileID != "fixed-a" {
		t.Fatalf("profile removal revoked an active lease: %+v", snapshot.Leases)
	}
	if _, err := restarted.Acquire("fixed-a", "new-slot", 1); !errors.Is(
		err,
		admission.ErrUnknownProfile,
	) {
		t.Fatalf("removed profile admitted new work: %v", err)
	}
	if err := restarted.Release("fixed-a", "active-slot"); err != nil {
		t.Fatalf("release removed profile's active lease: %v", err)
	}
	if _, err := restarted.Acquire("autoscaled-b", "replacement-slot", 1); err != nil {
		t.Fatalf("released removed-profile unit stayed stranded: %v", err)
	}
}
