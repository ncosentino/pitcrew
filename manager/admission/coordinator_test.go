package admission

import (
	"errors"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// manualClock is a deterministic Clock the tests advance explicitly, so
// provisional expiry and renewal never depend on real sleeps.
type manualClock struct {
	mu      sync.Mutex
	current time.Time
}

func newManualClock() *manualClock {
	return &manualClock{current: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)}
}

func (c *manualClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.current
}

func (c *manualClock) advance(d time.Duration) {
	c.mu.Lock()
	c.current = c.current.Add(d)
	c.mu.Unlock()
}

func singleProfilePolicy(profileID string, totalUnits, unitCost, reserved int, borrowable bool) HostPolicy {
	return HostPolicy{
		Generation: 1,
		TotalUnits: totalUnits,
		Profiles: []ProfilePolicy{
			{ProfileID: profileID, UnitCost: unitCost, ReservedUnits: reserved, Borrowable: borrowable},
		},
	}
}

func singleProfilePolicyGeneration(
	generation int,
	profileID string,
	totalUnits, unitCost, reserved int,
	borrowable bool,
) HostPolicy {
	policy := singleProfilePolicy(profileID, totalUnits, unitCost, reserved, borrowable)
	policy.Generation = generation
	return policy
}

func mustApplyPolicy(t *testing.T, coordinator *Coordinator, policy HostPolicy) {
	t.Helper()
	if err := coordinator.ApplyPolicy(policy); err != nil {
		t.Fatalf("apply policy: %v", err)
	}
}

func mustStatus(t *testing.T, coordinator *Coordinator) Snapshot {
	t.Helper()
	snapshot, err := coordinator.Status()
	if err != nil {
		t.Fatalf("read coordinator status: %v", err)
	}
	return snapshot
}

func mustInt(t *testing.T, value *int, name string) int {
	t.Helper()
	if value == nil {
		t.Fatalf("%s was unavailable", name)
	}
	return *value
}

// --- Budget and concurrency -------------------------------------------------

func TestAcquireNeverExceedsBudget(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, HostPolicy{
		Generation: 1,
		TotalUnits: 5,
		Profiles: []ProfilePolicy{
			{ProfileID: "alpha", UnitCost: 1},
		},
	})

	const attempts = 50
	results := make(chan error, attempts)
	var wg sync.WaitGroup
	for index := 0; index < attempts; index++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, err := coordinator.Acquire("alpha", slotName(i), 1)
			results <- err
		}(index)
	}
	wg.Wait()
	close(results)

	granted := 0
	for err := range results {
		if err == nil {
			granted++
		}
	}
	if granted != 5 {
		t.Fatalf("expected exactly 5 grants against a budget of 5, got %d", granted)
	}
	snapshot := mustStatus(t, coordinator)
	if len(snapshot.Leases) != 5 {
		t.Fatalf("expected 5 durable leases, got %d", len(snapshot.Leases))
	}
}

func TestConcurrentAcquireReleaseNeverOverAdmits(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, HostPolicy{
		Generation: 1,
		TotalUnits: 3,
		Profiles: []ProfilePolicy{
			{ProfileID: "alpha", UnitCost: 1},
			{ProfileID: "beta", UnitCost: 1},
		},
	})

	const rounds = 200
	var wg sync.WaitGroup
	var mu sync.Mutex
	maxObservedHeld := 0
	worker := func(profileID string, start int) {
		defer wg.Done()
		for i := 0; i < rounds; i++ {
			slot := slotName(start + i)
			if _, err := coordinator.Acquire(profileID, slot, 1); err == nil {
				snapshot := mustStatus(t, coordinator)
				mu.Lock()
				if len(snapshot.Leases) > maxObservedHeld {
					maxObservedHeld = len(snapshot.Leases)
				}
				mu.Unlock()
				_ = coordinator.Release(profileID, slot)
			}
		}
	}
	wg.Add(2)
	go worker("alpha", 0)
	go worker("beta", 1_000_000)
	wg.Wait()

	if maxObservedHeld > 3 {
		t.Fatalf("observed %d simultaneously held leases against a budget of 3", maxObservedHeld)
	}
}

func slotName(i int) string {
	return "slot-" + itoa(i)
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	negative := i < 0
	if negative {
		i = -i
	}
	digits := make([]byte, 0, 12)
	for i > 0 {
		digits = append([]byte{byte('0' + i%10)}, digits...)
		i /= 10
	}
	if negative {
		return "-" + string(digits)
	}
	return string(digits)
}

// --- Reservations and borrowing ---------------------------------------------

func TestNonBorrowableReservationIsProtectedFromOtherProfiles(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, HostPolicy{
		Generation: 1,
		TotalUnits: 4,
		Profiles: []ProfilePolicy{
			{ProfileID: "protected", UnitCost: 1, ReservedUnits: 2, Borrowable: false},
			{ProfileID: "opportunistic", UnitCost: 1},
		},
	})

	// The opportunistic profile can only ever reach the 2 unreserved units;
	// protected's non-borrowable reservation must remain idle headroom.
	for i := 0; i < 2; i++ {
		if _, err := coordinator.Acquire("opportunistic", slotName(i), 2); err != nil {
			t.Fatalf("expected unreserved unit %d to be admitted: %v", i, err)
		}
	}
	if _, err := coordinator.Acquire("opportunistic", slotName(99), 2); err != ErrBudgetExceeded {
		t.Fatalf("expected non-borrowable reservation to block further admission, got %v", err)
	}

	// The reservation owner can still claim its protected units.
	for i := 0; i < 2; i++ {
		if _, err := coordinator.Acquire("protected", "protected-"+slotName(i), 2); err != nil {
			t.Fatalf("expected protected reservation unit %d to be admitted: %v", i, err)
		}
	}
}

func TestBorrowableReservationParticipatesInSharedPoolButIsNeverPreempted(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, HostPolicy{
		Generation: 1,
		TotalUnits: 4,
		Profiles: []ProfilePolicy{
			{ProfileID: "lender", UnitCost: 1, ReservedUnits: 2, Borrowable: true},
			{ProfileID: "borrower", UnitCost: 1},
		},
	})

	// Lender's unused, borrowable reservation is available to the shared
	// pool: the borrower can claim all 4 units when the lender is idle.
	for i := 0; i < 4; i++ {
		if _, err := coordinator.Acquire("borrower", slotName(i), 1); err != nil {
			t.Fatalf("expected borrower unit %d to be admitted from the shared pool: %v", i, err)
		}
	}
	if _, err := coordinator.Acquire("borrower", slotName(99), 1); err != ErrBudgetExceeded {
		t.Fatalf("expected budget exhaustion, got %v", err)
	}

	// The lender's active leases are never preempted even though the lender
	// now wants its reservation back; it must wait for natural release.
	if _, err := coordinator.Acquire("lender", "lender-0", 1); err != ErrBudgetExceeded {
		t.Fatalf("expected lender to be blocked without preemption, got %v", err)
	}
	for i := 0; i < 4; i++ {
		if err := coordinator.Release("borrower", slotName(i)); err != nil {
			t.Fatalf("release borrower unit %d: %v", i, err)
		}
	}
	if _, err := coordinator.Acquire("lender", "lender-0", 1); err != nil {
		t.Fatalf("expected lender to reclaim its reservation after natural release: %v", err)
	}
}

// --- Fairness ---------------------------------------------------------------

func TestFairnessAvoidsStarvationAcrossRepeatedDecisions(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, HostPolicy{
		Generation: 1,
		TotalUnits: 1,
		Profiles: []ProfilePolicy{
			{ProfileID: "alpha", UnitCost: 1},
			{ProfileID: "beta", UnitCost: 1},
		},
	})

	grants := map[string]int{"alpha": 0, "beta": 0}
	for round := 0; round < 20; round++ {
		for _, profileID := range []string{"alpha", "beta"} {
			slot := profileID + "-" + itoa(round)
			if _, err := coordinator.Acquire(profileID, slot, 1); err == nil {
				grants[profileID]++
				if err := coordinator.Release(profileID, slot); err != nil {
					t.Fatalf("release %s: %v", profileID, err)
				}
			}
		}
	}
	if grants["alpha"] == 0 || grants["beta"] == 0 {
		t.Fatalf("expected both profiles to be admitted at least once, got %#v", grants)
	}
	difference := grants["alpha"] - grants["beta"]
	if difference > 2 || difference < -2 {
		t.Fatalf("expected roughly even admission across rounds, got %#v", grants)
	}
}

func TestFairnessGuaranteesShareWhenBothProfilesContendSimultaneously(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, HostPolicy{
		Generation: 1,
		TotalUnits: 2,
		Profiles: []ProfilePolicy{
			{ProfileID: "alpha", UnitCost: 1},
			{ProfileID: "beta", UnitCost: 1},
		},
	})
	coordinator.SetDemand("beta", 5)

	if _, err := coordinator.Acquire("alpha", "alpha-0", 5); err != nil {
		t.Fatalf("expected alpha to receive its guaranteed share: %v", err)
	}
	if _, err := coordinator.Acquire("beta", "beta-0", 5); err != nil {
		t.Fatalf("expected beta to receive its guaranteed share: %v", err)
	}
	if _, err := coordinator.Acquire("alpha", "alpha-1", 5); err != ErrBudgetExceeded {
		t.Fatalf("expected alpha's second request beyond its share to be rejected, got %v", err)
	}
}

// TestFairTurnLockedAccountsForRequestedUnitCostNotJustHeldUnits directly
// exercises fairTurnLocked with a synthetic held map that a real sequence of
// Acquire calls cannot easily reproduce (available shrinks in lockstep with
// held units for exact-multiple unit costs, masking the bug). It proves a
// profile whose shared-pool holdings are individually below its guarantee
// must still be rejected when its next request's unit cost would push it
// over that guarantee: the correct comparison is
// sharedHeld+unitCost<=guarantee, not sharedHeld<guarantee.
func TestFairTurnLockedAccountsForRequestedUnitCostNotJustHeldUnits(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, HostPolicy{
		Generation: 1,
		TotalUnits: 4,
		Profiles: []ProfilePolicy{
			{ProfileID: "alpha", UnitCost: 3},
			{ProfileID: "beta", UnitCost: 1},
		},
	})
	coordinator.SetDemand("alpha", 1)
	coordinator.SetDemand("beta", 1)

	coordinator.mu.Lock()
	held := map[string]int{"alpha": 1}
	// available=4 with two equal contenders yields guarantee=2 each; alpha
	// already holds 1 shared unit and requests 3 more, which must be
	// rejected because 1+3=4 > 2, even though 1 < 2 would have incorrectly
	// fast-tracked it under the old, cost-blind comparison.
	got, _ := coordinator.fairTurnLocked("alpha", held, 4, 3)
	coordinator.mu.Unlock()

	if got {
		t.Fatalf(
			"expected fairTurnLocked to reject a request whose cost would exceed the requester's guarantee",
		)
	}
}

// TestFairnessWithHeterogeneousUnitCostsAvoidsStarvation exercises the same
// starvation property as TestFairnessAvoidsStarvationAcrossRepeatedDecisions
// but with unequal unit costs across profiles and repeated contention with
// both profiles registered as pending demand simultaneously, so the
// cost-aware guarantee check governs every round rather than only the
// no-borrowable-headroom path.
func TestFairnessWithHeterogeneousUnitCostsAvoidsStarvation(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, HostPolicy{
		Generation: 1,
		TotalUnits: 6,
		Profiles: []ProfilePolicy{
			{ProfileID: "heavy", UnitCost: 3},
			{ProfileID: "light", UnitCost: 1},
		},
	})
	coordinator.SetDemand("heavy", 1)
	coordinator.SetDemand("light", 1)

	grants := map[string]int{"heavy": 0, "light": 0}
	for round := 0; round < 30; round++ {
		heavySlot := "heavy-" + itoa(round)
		if _, err := coordinator.Acquire("heavy", heavySlot, 1); err == nil {
			grants["heavy"]++
			if err := coordinator.Release("heavy", heavySlot); err != nil {
				t.Fatalf("release heavy: %v", err)
			}
		}
		lightSlot := "light-" + itoa(round)
		if _, err := coordinator.Acquire("light", lightSlot, 1); err == nil {
			grants["light"]++
			if err := coordinator.Release("light", lightSlot); err != nil {
				t.Fatalf("release light: %v", err)
			}
		}
	}
	if grants["heavy"] == 0 || grants["light"] == 0 {
		t.Fatalf("expected both profiles to be admitted at least once despite unequal unit costs, got %#v", grants)
	}
}

// --- Provisional lifecycle ---------------------------------------------------

func TestProvisionalExpiryAndRenewal(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, 10*time.Second)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 1, 1, 0, false))

	lease, err := coordinator.Acquire("alpha", "slot-a", 1)
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	if lease.Status != LeaseProvisional {
		t.Fatalf("expected provisional lease, got %q", lease.Status)
	}

	clock.advance(5 * time.Second)
	renewed, err := coordinator.Renew("alpha", "slot-a")
	if err != nil {
		t.Fatalf("renew before expiry: %v", err)
	}
	if renewed.ExpiresAtUnixNano <= lease.ExpiresAtUnixNano {
		t.Fatalf("expected renewal to extend expiry")
	}

	clock.advance(10 * time.Second)
	if _, err := coordinator.Renew("alpha", "slot-a"); err != ErrLeaseExpired {
		t.Fatalf("expected renewal after expiry to fail closed, got %v", err)
	}

	// The unit must be freed by expiry: a fresh acquisition for a new slot
	// succeeds even though the old slot was never explicitly released.
	if _, err := coordinator.Acquire("alpha", "slot-b", 1); err != nil {
		t.Fatalf("expected expired unit to be reclaimed: %v", err)
	}
}

func TestActivationRejectedAfterExpiry(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, 10*time.Second)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 1, 1, 0, false))

	if _, err := coordinator.Acquire("alpha", "slot-a", 1); err != nil {
		t.Fatalf("acquire: %v", err)
	}
	clock.advance(11 * time.Second)
	if _, err := coordinator.Activate("alpha", "slot-a"); err != ErrLeaseExpired {
		t.Fatalf("expected activation after expiry to be rejected, got %v", err)
	}

	// A worker process must never start against an expired lease; the
	// coordinator must not have silently produced an active lease.
	snapshot := mustStatus(t, coordinator)
	for _, lease := range snapshot.Leases {
		if lease.SlotKey == "slot-a" && lease.Status == LeaseActive {
			t.Fatalf("expired lease must never become active")
		}
	}
}

func TestActivationIsIdempotentBeforeExpiry(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 1, 1, 0, false))

	if _, err := coordinator.Acquire("alpha", "slot-a", 1); err != nil {
		t.Fatalf("acquire: %v", err)
	}
	first, err := coordinator.Activate("alpha", "slot-a")
	if err != nil {
		t.Fatalf("activate: %v", err)
	}
	second, err := coordinator.Activate("alpha", "slot-a")
	if err != nil {
		t.Fatalf("expected idempotent re-activation, got error: %v", err)
	}
	if first.LeaseID != second.LeaseID || second.Status != LeaseActive {
		t.Fatalf("expected identical active lease on retry, got %+v vs %+v", first, second)
	}
}

// --- Active lease durability and restart -------------------------------------

func TestActiveLeasePersistsAcrossRestart(t *testing.T) {
	directory := t.TempDir()
	clock := newManualClock()

	coordinator, err := OpenFile(directory, clock, time.Minute)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 1, 1, 0, false))
	if _, err := coordinator.Acquire("alpha", "slot-a", 1); err != nil {
		t.Fatalf("acquire: %v", err)
	}
	if _, err := coordinator.Activate("alpha", "slot-a"); err != nil {
		t.Fatalf("activate: %v", err)
	}

	// Simulate an unbounded manager outage: the active lease must never
	// expire from heartbeat loss alone, however long it takes to restart.
	clock.advance(365 * 24 * time.Hour)

	restarted, err := OpenFile(directory, clock, time.Minute)
	if err != nil {
		t.Fatalf("reopen after restart: %v", err)
	}
	snapshot := mustStatus(t, restarted)
	if snapshot.Policy.Generation != 1 || len(snapshot.Leases) != 1 {
		t.Fatalf("expected restored policy and lease, got %+v", snapshot)
	}
	if snapshot.Leases[0].Status != LeaseActive {
		t.Fatalf("expected restored lease to remain active, got %q", snapshot.Leases[0].Status)
	}
	if snapshot.DecisionSequence == 0 {
		t.Fatalf("expected restored decision sequence to be preserved")
	}

	// The budget is still fully consumed after restart: no double-admission.
	if _, err := restarted.Acquire("alpha", "slot-b", 1); err != ErrBudgetExceeded {
		t.Fatalf("expected budget to remain exhausted after restart, got %v", err)
	}
}

func TestRestartDiscardsProvisionalLeasesButPreservesActiveLeases(t *testing.T) {
	directory := t.TempDir()
	clock := newManualClock()

	coordinator, err := OpenFile(directory, clock, time.Minute)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mustApplyPolicy(t, coordinator, HostPolicy{
		Generation: 1,
		TotalUnits: 2,
		Profiles: []ProfilePolicy{
			{ProfileID: "alpha", UnitCost: 1},
		},
	})
	if _, err := coordinator.Acquire("alpha", "provisional-slot", 1); err != nil {
		t.Fatalf("acquire provisional: %v", err)
	}
	if _, err := coordinator.Acquire("alpha", "active-slot", 1); err != nil {
		t.Fatalf("acquire active: %v", err)
	}
	if _, err := coordinator.Activate("alpha", "active-slot"); err != nil {
		t.Fatalf("activate: %v", err)
	}

	// Restart immediately: the provisional lease's monotonic deadline lived
	// only in the crashed process's memory and can never be trusted again,
	// so ADR-0003's service-owned monotonic expiry requires it be discarded
	// even though no wall-clock time has passed.
	restarted, err := OpenFile(directory, clock, time.Minute)
	if err != nil {
		t.Fatalf("reopen after restart: %v", err)
	}
	snapshot := mustStatus(t, restarted)
	if len(snapshot.Leases) != 1 || snapshot.Leases[0].SlotKey != "active-slot" {
		t.Fatalf("expected only the active lease to survive restart, got %+v", snapshot.Leases)
	}

	foundTombstone := false
	for _, tombstone := range snapshot.Tombstones {
		if tombstone.SlotKey == "provisional-slot" {
			foundTombstone = true
			if tombstone.Reason != TombstoneRestartDiscarded {
				t.Fatalf("expected restart-discarded reason, got %q", tombstone.Reason)
			}
		}
	}
	if !foundTombstone {
		t.Fatalf("expected a restart-discarded tombstone for the provisional slot, got %+v", snapshot.Tombstones)
	}

	sequenceAfterFirstRestart := snapshot.DecisionSequence

	// Capture the pruned document as it stood immediately after the first
	// restart-discard, before this process's further mutations, so the
	// second-restart no-op check below is not confounded by new state.
	seedState, exists, err := newFileStore(directory).Load()
	if err != nil || !exists {
		t.Fatalf("reload pruned document for reseeding: exists=%v err=%v", exists, err)
	}

	// The provisional unit was reclaimed: a fresh acquisition succeeds.
	if _, err := restarted.Acquire("alpha", "new-slot", 1); err != nil {
		t.Fatalf("expected provisional unit to be reclaimed after restart: %v", err)
	}
	// The active unit is still held: budget is now exactly exhausted again
	// (active-slot + new-slot == TotalUnits).
	if _, err := restarted.Acquire("alpha", "third-slot", 1); err != ErrBudgetExceeded {
		t.Fatalf("expected budget to be exhausted by active + reclaimed slots, got %v", err)
	}

	// A second, independent restart of the state as it stood immediately
	// after the first restart-discard must be a no-op: no new tombstones,
	// no change to the surviving active lease, and an unchanged decision
	// sequence.
	secondDirectory := t.TempDir()
	if err := newFileStore(secondDirectory).Save(seedState); err != nil {
		t.Fatalf("seed second directory: %v", err)
	}
	restartedAgain, err := OpenFile(secondDirectory, clock, time.Minute)
	if err != nil {
		t.Fatalf("reopen an already-pruned document: %v", err)
	}
	secondSnapshot := mustStatus(t, restartedAgain)
	if secondSnapshot.DecisionSequence != sequenceAfterFirstRestart {
		t.Fatalf(
			"expected no-op restart to leave decision sequence unchanged, before=%d after=%d",
			sequenceAfterFirstRestart, secondSnapshot.DecisionSequence,
		)
	}
}

func TestRestartDiscardDoesNotTouchAnEmptyOrLeaselessDocument(t *testing.T) {
	directory := t.TempDir()
	clock := newManualClock()

	coordinator, err := OpenFile(directory, clock, time.Minute)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 1, 1, 0, false))

	restarted, err := OpenFile(directory, clock, time.Minute)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	snapshot := mustStatus(t, restarted)
	if len(snapshot.Leases) != 0 || len(snapshot.Tombstones) != 0 {
		t.Fatalf("expected a leaseless document to be untouched by restart discard, got %+v", snapshot)
	}
}

// --- Release and tombstones --------------------------------------------------

func TestExactReleaseProducesDurableTombstone(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 1, 1, 0, false))

	if _, err := coordinator.Acquire("alpha", "slot-a", 1); err != nil {
		t.Fatalf("acquire: %v", err)
	}
	if _, err := coordinator.Activate("alpha", "slot-a"); err != nil {
		t.Fatalf("activate: %v", err)
	}
	if err := coordinator.Release("alpha", "slot-a"); err != nil {
		t.Fatalf("release: %v", err)
	}
	snapshot := mustStatus(t, coordinator)
	if len(snapshot.Leases) != 0 {
		t.Fatalf("expected no remaining leases after release, got %+v", snapshot.Leases)
	}
	if len(snapshot.Tombstones) != 1 || snapshot.Tombstones[0].Reason != TombstoneReleased {
		t.Fatalf("expected exactly one release tombstone, got %+v", snapshot.Tombstones)
	}

	// A repeated release of the same slot is a safe idempotent no-op.
	if err := coordinator.Release("alpha", "slot-a"); err != nil {
		t.Fatalf("expected idempotent repeat release, got %v", err)
	}

	// A release of a slot that never existed is rejected, not fabricated.
	if err := coordinator.Release("alpha", "never-existed"); err != ErrLeaseNotFound {
		t.Fatalf("expected ErrLeaseNotFound for an unknown slot, got %v", err)
	}
}

func TestReconcileRequiresEvidenceAndProducesTombstone(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 1, 1, 0, false))

	if _, err := coordinator.Acquire("alpha", "slot-a", 1); err != nil {
		t.Fatalf("acquire: %v", err)
	}
	if _, err := coordinator.Activate("alpha", "slot-a"); err != nil {
		t.Fatalf("activate: %v", err)
	}

	if err := coordinator.Reconcile("alpha", "slot-a", ""); err != ErrEvidenceRequired {
		t.Fatalf("expected empty evidence to be rejected, got %v", err)
	}
	// Time alone must never release an active lease: no expiry applies.
	clock.advance(24 * time.Hour)
	if _, err := coordinator.Acquire("alpha", "slot-b", 1); err != ErrBudgetExceeded {
		t.Fatalf("expected active lease to remain durable after time alone, got %v", err)
	}

	if err := coordinator.Reconcile("alpha", "slot-a", "container absent; registration fenced"); err != nil {
		t.Fatalf("reconcile with evidence: %v", err)
	}
	snapshot := mustStatus(t, coordinator)
	if len(snapshot.Leases) != 0 {
		t.Fatalf("expected lease to be released by reconciliation, got %+v", snapshot.Leases)
	}
	if len(snapshot.Tombstones) != 1 ||
		snapshot.Tombstones[0].Reason != TombstoneReconciledAbsent ||
		snapshot.Tombstones[0].Evidence == "" {
		t.Fatalf("expected a fenced-recovery tombstone with evidence, got %+v", snapshot.Tombstones)
	}

	// Capacity is now free again.
	if _, err := coordinator.Acquire("alpha", "slot-b", 1); err != nil {
		t.Fatalf("expected reconciled unit to be reclaimed: %v", err)
	}
}

// --- Reconcile evidence sanitization ------------------------------------------

func TestReconcileEvidenceSanitization(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 1, 1, 0, false))

	setup := func(t *testing.T) {
		t.Helper()
		if _, err := coordinator.Acquire("alpha", "slot-a", 1); err != nil {
			t.Fatalf("acquire: %v", err)
		}
		if _, err := coordinator.Activate("alpha", "slot-a"); err != nil {
			t.Fatalf("activate: %v", err)
		}
	}
	teardown := func(t *testing.T) {
		t.Helper()
		if err := coordinator.Release("alpha", "slot-a"); err != nil {
			t.Fatalf("release: %v", err)
		}
	}

	t.Run("whitespace only is rejected as required, not invalid", func(t *testing.T) {
		setup(t)
		defer teardown(t)
		if err := coordinator.Reconcile("alpha", "slot-a", "   \t  "); err != ErrEvidenceRequired {
			t.Fatalf("expected whitespace-only evidence to be rejected as required, got %v", err)
		}
	})

	t.Run("oversized evidence is rejected", func(t *testing.T) {
		setup(t)
		defer teardown(t)
		oversized := strings.Repeat("a", maxEvidenceBytes+1)
		if err := coordinator.Reconcile("alpha", "slot-a", oversized); !errors.Is(err, ErrEvidenceInvalid) {
			t.Fatalf("expected oversized evidence to be rejected as invalid, got %v", err)
		}
	})

	t.Run("embedded newline is rejected", func(t *testing.T) {
		setup(t)
		defer teardown(t)
		if err := coordinator.Reconcile("alpha", "slot-a", "line one\nline two"); !errors.Is(err, ErrEvidenceInvalid) {
			t.Fatalf("expected embedded newline to be rejected as invalid, got %v", err)
		}
	})

	t.Run("embedded control character is rejected", func(t *testing.T) {
		setup(t)
		defer teardown(t)
		if err := coordinator.Reconcile("alpha", "slot-a", "evidence\x00tail"); !errors.Is(err, ErrEvidenceInvalid) {
			t.Fatalf("expected embedded control character to be rejected as invalid, got %v", err)
		}
	})

	t.Run("valid evidence is trimmed and accepted", func(t *testing.T) {
		setup(t)
		defer func() {
			// Reconcile releases the lease itself on success; no teardown.
		}()
		if err := coordinator.Reconcile("alpha", "slot-a", "  container absent  "); err != nil {
			t.Fatalf("expected valid evidence with surrounding whitespace to be accepted: %v", err)
		}
		snapshot := mustStatus(t, coordinator)
		found := false
		for _, tombstone := range snapshot.Tombstones {
			if tombstone.SlotKey == "slot-a" && tombstone.Reason == TombstoneReconciledAbsent {
				found = true
				if tombstone.Evidence != "container absent" {
					t.Fatalf("expected trimmed evidence, got %q", tombstone.Evidence)
				}
			}
		}
		if !found {
			t.Fatalf("expected a fenced-recovery tombstone with sanitized evidence")
		}
	})
}

// --- Tombstone reuse and compaction -------------------------------------------

func TestTombstoneIsSupersededByAFreshLeaseForTheSameSlot(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 1, 1, 0, false))

	if _, err := coordinator.Acquire("alpha", "slot-a", 1); err != nil {
		t.Fatalf("acquire: %v", err)
	}
	if err := coordinator.Release("alpha", "slot-a"); err != nil {
		t.Fatalf("release: %v", err)
	}
	snapshot := mustStatus(t, coordinator)
	if len(snapshot.Tombstones) != 1 {
		t.Fatalf("expected exactly one tombstone after release, got %d", len(snapshot.Tombstones))
	}

	if _, err := coordinator.Acquire("alpha", "slot-a", 1); err != nil {
		t.Fatalf("expected reacquisition of a tombstoned slot to succeed: %v", err)
	}
	snapshot = mustStatus(t, coordinator)
	if len(snapshot.Tombstones) != 0 {
		t.Fatalf("expected the prior tombstone to be superseded by the fresh lease, got %+v", snapshot.Tombstones)
	}
	if len(snapshot.Leases) != 1 {
		t.Fatalf("expected exactly one live lease after reacquisition, got %d", len(snapshot.Leases))
	}
}

func TestTombstoneCompactionKeepsNewestBySequence(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 1, 1, 0, false))

	const total = maxTombstones + 10
	for i := 0; i < total; i++ {
		slot := "slot-" + itoa(i)
		if _, err := coordinator.Acquire("alpha", slot, 1); err != nil {
			t.Fatalf("acquire %s: %v", slot, err)
		}
		if err := coordinator.Release("alpha", slot); err != nil {
			t.Fatalf("release %s: %v", slot, err)
		}
	}
	snapshot := mustStatus(t, coordinator)
	if len(snapshot.Tombstones) != maxTombstones {
		t.Fatalf("expected tombstones to be bounded at %d, got %d", maxTombstones, len(snapshot.Tombstones))
	}

	// The oldest 10 releases (slot-0..slot-9) must have been evicted; the
	// newest maxTombstones releases must all be retained.
	present := make(map[string]bool, len(snapshot.Tombstones))
	for _, tombstone := range snapshot.Tombstones {
		present[tombstone.SlotKey] = true
	}
	for i := 0; i < total-maxTombstones; i++ {
		if present["slot-"+itoa(i)] {
			t.Fatalf("expected oldest tombstone slot-%d to be evicted by compaction", i)
		}
	}
	for i := total - maxTombstones; i < total; i++ {
		if !present["slot-"+itoa(i)] {
			t.Fatalf("expected newest tombstone slot-%d to be retained by compaction", i)
		}
	}
}

// --- Durable state internal consistency ---------------------------------------

func TestDurableStateValidationRejectsSimultaneousLeaseAndTombstoneForSameKey(t *testing.T) {
	key := leaseKey{profileID: "alpha", slotKey: "slot-a"}.String()
	state := newDurableState()
	state.SchemaVersion = stateSchemaVersion
	state.Leases[key] = Lease{
		ProfileID: "alpha",
		SlotKey:   "slot-a",
		LeaseID:   "alpha/slot-a#1",
		Units:     1,
		Status:    LeaseActive,
	}
	state.Tombstones[key] = Tombstone{
		ProfileID: "alpha",
		SlotKey:   "slot-a",
		LeaseID:   "alpha/slot-a#1",
		Reason:    TombstoneReleased,
		Sequence:  1,
	}
	if err := state.validate(); !errors.Is(err, ErrCorruptState) {
		t.Fatalf("expected a lease/tombstone key collision to fail validation as corrupt state, got %v", err)
	}
}

// --- Protocol version compatibility ------------------------------------------

func TestNegotiateProtocolVersionOverlapAndRejection(t *testing.T) {
	tests := []struct {
		name    string
		server  []int
		client  []int
		want    int
		overlap bool
	}{
		{name: "exact match", server: []int{1}, client: []int{1}, want: 1, overlap: true},
		{name: "server supports current and previous", server: []int{1, 2}, client: []int{1}, want: 1, overlap: true},
		{name: "client prefers newest overlap", server: []int{1, 2}, client: []int{2, 3}, want: 2, overlap: true},
		{name: "no overlap rejected", server: []int{2}, client: []int{1}, want: 0, overlap: false},
		{name: "empty client rejected", server: []int{1}, client: nil, want: 0, overlap: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			version, overlap := NegotiateProtocolVersion(test.server, test.client)
			if overlap != test.overlap || (overlap && version != test.want) {
				t.Fatalf(
					"NegotiateProtocolVersion(%v, %v) = (%d, %v), want (%d, %v)",
					test.server, test.client, version, overlap, test.want, test.overlap,
				)
			}
		})
	}
}

// --- Duplicate safety ---------------------------------------------------------

func TestDuplicateAcquireIsSafeAndDoesNotDoubleCountBudget(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 1, 1, 0, false))

	first, err := coordinator.Acquire("alpha", "slot-a", 1)
	if err != nil {
		t.Fatalf("first acquire: %v", err)
	}
	second, err := coordinator.Acquire("alpha", "slot-a", 1)
	if err != ErrDuplicateLease {
		t.Fatalf("expected ErrDuplicateLease on retry, got %v", err)
	}
	if second.LeaseID != first.LeaseID {
		t.Fatalf("expected duplicate acquire to return the existing lease unchanged")
	}
	snapshot := mustStatus(t, coordinator)
	if len(snapshot.Leases) != 1 {
		t.Fatalf("expected exactly one durable lease despite the duplicate call, got %d", len(snapshot.Leases))
	}
}

func TestDuplicateProfileInPolicyIsRejected(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	err := coordinator.ApplyPolicy(HostPolicy{
		Generation: 1,
		TotalUnits: 2,
		Profiles: []ProfilePolicy{
			{ProfileID: "alpha", UnitCost: 1},
			{ProfileID: "alpha", UnitCost: 1},
		},
	})
	if err == nil {
		t.Fatal("expected duplicate profile identity to be rejected")
	}
}

// --- Corrupt state fails closed -----------------------------------------------

func TestCorruptDurableStateFailsClosed(t *testing.T) {
	directory := t.TempDir()
	statePath := filepath.Join(directory, "admission-state.json")
	if err := writeFileAtomically(statePath, []byte("{not valid json")); err != nil {
		t.Fatalf("seed corrupt state: %v", err)
	}
	if _, err := OpenFile(directory, newManualClock(), time.Minute); err == nil {
		t.Fatal("expected corrupt durable state to fail closed")
	}
}

func TestUnsupportedSchemaVersionFailsClosed(t *testing.T) {
	directory := t.TempDir()
	statePath := filepath.Join(directory, "admission-state.json")
	document := `{"schemaVersion":999,"epoch":0,"decisionSequence":0,"policy":{"generation":0,"totalUnits":0,"profiles":null},"leases":{},"tombstones":{}}`
	if err := writeFileAtomically(statePath, []byte(document)); err != nil {
		t.Fatalf("seed unsupported state: %v", err)
	}
	_, err := OpenFile(directory, newManualClock(), time.Minute)
	if err == nil {
		t.Fatal("expected unsupported schema version to fail closed")
	}
}

// --- Reduced budget natural drain --------------------------------------------

func TestReducedBudgetDrainsNaturallyWithoutRevokingActiveLeases(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 3, 1, 0, false))

	slots := []string{"slot-a", "slot-b", "slot-c"}
	for _, slot := range slots {
		if _, err := coordinator.Acquire("alpha", slot, 1); err != nil {
			t.Fatalf("acquire %s: %v", slot, err)
		}
		if _, err := coordinator.Activate("alpha", slot); err != nil {
			t.Fatalf("activate %s: %v", slot, err)
		}
	}

	// Reduce the budget below the number of already-active leases.
	mustApplyPolicy(t, coordinator, singleProfilePolicyGeneration(2, "alpha", 1, 1, 0, false))

	snapshot := mustStatus(t, coordinator)
	if len(snapshot.Leases) != 3 {
		t.Fatalf("expected reduced budget to leave existing active leases untouched, got %+v", snapshot.Leases)
	}
	for _, lease := range snapshot.Leases {
		if lease.Status != LeaseActive {
			t.Fatalf("expected lease %q to remain active, got %q", lease.SlotKey, lease.Status)
		}
	}

	// New admission is blocked until the over-committed leases drain.
	if _, err := coordinator.Acquire("alpha", "slot-d", 1); err != ErrBudgetExceeded {
		t.Fatalf("expected new admission to be blocked under the reduced budget, got %v", err)
	}

	// Natural drain: releasing existing leases frees capacity under the new
	// budget without any active-lease revocation having occurred. The
	// remaining active lease still fully occupies the reduced budget, so a
	// new acquisition only succeeds once every over-committed lease has
	// drained.
	if err := coordinator.Release("alpha", "slot-a"); err != nil {
		t.Fatalf("release: %v", err)
	}
	if err := coordinator.Release("alpha", "slot-b"); err != nil {
		t.Fatalf("release: %v", err)
	}
	if _, err := coordinator.Acquire("alpha", "slot-d", 1); err != ErrBudgetExceeded {
		t.Fatalf("expected the still-active remaining lease to fully occupy the reduced budget, got %v", err)
	}
	if err := coordinator.Release("alpha", "slot-c"); err != nil {
		t.Fatalf("release: %v", err)
	}
	if _, err := coordinator.Acquire("alpha", "slot-d", 1); err != nil {
		t.Fatalf("expected admission to resume after natural drain: %v", err)
	}
}

// --- Stale and invalid policy -------------------------------------------------

func TestApplyPolicyRejectsStaleGenerationAndInvalidReservations(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 4, 1, 0, false))

	if err := coordinator.ApplyPolicy(singleProfilePolicy("alpha", 4, 1, 0, false)); err != ErrStalePolicy {
		t.Fatalf("expected a repeated generation to be rejected as stale, got %v", err)
	}
	stale := singleProfilePolicy("alpha", 8, 1, 0, false)
	stale.Generation = 0
	if err := coordinator.ApplyPolicy(stale); err == nil {
		t.Fatal("expected generation 0 to be rejected")
	}

	overReserved := HostPolicy{
		Generation: 2,
		TotalUnits: 2,
		Profiles: []ProfilePolicy{
			{ProfileID: "alpha", UnitCost: 1, ReservedUnits: 3},
		},
	}
	if err := coordinator.ApplyPolicy(overReserved); err == nil {
		t.Fatal("expected reservations exceeding the total budget to be rejected")
	}
}

func TestAcquireRejectsUnknownProfile(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 4, 1, 0, false))
	if _, err := coordinator.Acquire("ghost", "slot-a", 1); err != ErrUnknownProfile {
		t.Fatalf("expected ErrUnknownProfile, got %v", err)
	}
}

// --- Policy validation bounds -------------------------------------------------

func TestPolicyValidationRejectsZeroOrNegativeTotalUnits(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	zero := singleProfilePolicy("alpha", 0, 1, 0, false)
	if err := coordinator.ApplyPolicy(zero); err == nil {
		t.Fatal("expected a zero total-unit budget to be rejected once a policy is applied")
	}
}

func TestPolicyValidationRejectsUnitCostExceedingTotalUnits(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	policy := HostPolicy{
		Generation: 1,
		TotalUnits: 2,
		Profiles: []ProfilePolicy{
			{ProfileID: "alpha", UnitCost: 3},
		},
	}
	if err := coordinator.ApplyPolicy(policy); err == nil {
		t.Fatal("expected a unit cost exceeding total units to be rejected")
	}
}

func TestPolicyValidationRejectsReservedUnitsExceedingTotalUnits(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	policy := HostPolicy{
		Generation: 1,
		TotalUnits: 2,
		Profiles: []ProfilePolicy{
			{ProfileID: "alpha", UnitCost: 1, ReservedUnits: 3},
		},
	}
	if err := coordinator.ApplyPolicy(policy); err == nil {
		t.Fatal("expected a single profile's reserved units exceeding total units to be rejected")
	}
}

// TestPolicyValidationAllowsPartialReservationsAcrossProfiles confirms
// partial, per-profile reservations remain fully supported: each profile's
// own ReservedUnits/UnitCost individually fits within TotalUnits, and the
// aggregate reservation legitimately leaves shared headroom for
// unreserved, fair-pool acquisition. Held units are always subtracted from
// the total budget, so partial reservations combined with shared units
// never oversubscribe; a request is only ever admitted while
// held+requested<=TotalUnits.
func TestPolicyValidationAllowsPartialReservationsAcrossProfiles(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	policy := HostPolicy{
		Generation: 1,
		TotalUnits: 10,
		Profiles: []ProfilePolicy{
			{ProfileID: "alpha", UnitCost: 2, ReservedUnits: 4, Borrowable: false},
			{ProfileID: "beta", UnitCost: 1},
		},
	}
	if err := coordinator.ApplyPolicy(policy); err != nil {
		t.Fatalf("expected partial per-profile reservations to be accepted: %v", err)
	}
	// alpha's reservation (4) plus beta's full claim on the remaining
	// shared pool (6) together exactly exhaust TotalUnits (10), proving no
	// oversubscription: held is always subtracted from the budget.
	for i := 0; i < 6; i++ {
		if _, err := coordinator.Acquire("beta", slotName(i), 1); err != nil {
			t.Fatalf("expected shared-pool unit %d to be admitted: %v", i, err)
		}
	}
	if _, err := coordinator.Acquire("beta", slotName(99), 1); err != ErrBudgetExceeded {
		t.Fatalf("expected the shared pool to be exhausted once alpha's reservation is protected, got %v", err)
	}
	for i := 0; i < 2; i++ {
		if _, err := coordinator.Acquire("alpha", "alpha-"+slotName(i), 1); err != nil {
			t.Fatalf("expected alpha to still claim its own reservation: %v", err)
		}
	}
}

// --- Identity validation -------------------------------------------------

// TestProfileIDValidationRejectsSyntaxViolations exercises the public
// profile identity contract at policy-application time: empty, oversized
// (>32 characters), uppercase, a leading digit or hyphen, and an embedded
// separator must all be rejected before a policy can be applied.
func TestProfileIDValidationRejectsSyntaxViolations(t *testing.T) {
	invalidProfileIDs := []string{
		"",
		strings.Repeat("a", 33),
		"Alpha",
		"1alpha",
		"-alpha",
		"al/pha",
		"al pha",
	}
	for _, profileID := range invalidProfileIDs {
		clock := newManualClock()
		coordinator := OpenMemory(clock, time.Minute)
		err := coordinator.ApplyPolicy(singleProfilePolicy(profileID, 1, 1, 0, false))
		if !errors.Is(err, ErrInvalidIdentity) {
			t.Fatalf("profile id %q: expected ErrInvalidIdentity, got %v", profileID, err)
		}
	}
}

// TestSlotKeyValidationRejectsSyntaxViolations exercises the bounded opaque
// slot key contract at every slot operation: empty, oversized (>128
// characters), an embedded separator, and control characters must all be
// rejected before the identity ever reaches map-key formation.
func TestSlotKeyValidationRejectsSyntaxViolations(t *testing.T) {
	invalidSlotKeys := []string{
		"",
		strings.Repeat("a", 129),
		"slot/a",
		"slot\ta",
		"slot\na",
		" slot-a",
	}
	for _, slotKey := range invalidSlotKeys {
		clock := newManualClock()
		coordinator := OpenMemory(clock, time.Minute)
		mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 1, 1, 0, false))
		if _, err := coordinator.Acquire("alpha", slotKey, 1); !errors.Is(err, ErrInvalidIdentity) {
			t.Fatalf("slot key %q: expected ErrInvalidIdentity from Acquire, got %v", slotKey, err)
		}
		if _, err := coordinator.Renew("alpha", slotKey); !errors.Is(err, ErrInvalidIdentity) {
			t.Fatalf("slot key %q: expected ErrInvalidIdentity from Renew, got %v", slotKey, err)
		}
		if _, err := coordinator.Activate("alpha", slotKey); !errors.Is(err, ErrInvalidIdentity) {
			t.Fatalf("slot key %q: expected ErrInvalidIdentity from Activate, got %v", slotKey, err)
		}
		if err := coordinator.Release("alpha", slotKey); !errors.Is(err, ErrInvalidIdentity) {
			t.Fatalf("slot key %q: expected ErrInvalidIdentity from Release, got %v", slotKey, err)
		}
		if err := coordinator.Reconcile("alpha", slotKey, "evidence"); !errors.Is(err, ErrInvalidIdentity) {
			t.Fatalf("slot key %q: expected ErrInvalidIdentity from Reconcile, got %v", slotKey, err)
		}
	}
}

// TestIdentityValidationPreventsLeaseKeyCollisions proves the exclusion of
// "/" from both patterns makes the profile/slot join used to form a durable
// lease key unambiguous: two different (profileID, slotKey) pairs whose
// naive string concatenation would collide (e.g. "a" + "/" + "b/c" versus
// "a/b" + "/" + "c") can never both be valid, so at most one of the two
// candidate leases can ever be acquired at a time and there is no path by
// which a legitimate pair is misattributed to another pair's key.
func TestIdentityValidationPreventsLeaseKeyCollisions(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 4, 1, 0, false))

	// Neither half of a collision-prone pair can pass identity validation,
	// since "/" is excluded from both the ProfileID and SlotKey patterns.
	if _, err := coordinator.Acquire("a/b", "c", 1); !errors.Is(err, ErrInvalidIdentity) {
		t.Fatalf("expected a profile id containing \"/\" to be rejected, got %v", err)
	}
	if _, err := coordinator.Acquire("alpha", "b/c", 1); !errors.Is(err, ErrInvalidIdentity) {
		t.Fatalf("expected a slot key containing \"/\" to be rejected, got %v", err)
	}
}

// --- SetDemand validation --------------------------------------------------

// TestSetDemandRejectsUnknownAndInvalidProfiles confirms SetDemand rejects
// a syntactically invalid profile identity and a profile not present in the
// currently applied policy, in both cases without mutating the demand map.
func TestSetDemandRejectsUnknownAndInvalidProfiles(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 4, 1, 0, false))

	if err := coordinator.SetDemand("Not-Valid", 1); !errors.Is(err, ErrInvalidIdentity) {
		t.Fatalf("expected ErrInvalidIdentity for a syntactically invalid profile id, got %v", err)
	}
	if err := coordinator.SetDemand("never-registered", 1); !errors.Is(err, ErrUnknownProfile) {
		t.Fatalf("expected ErrUnknownProfile for a profile absent from policy, got %v", err)
	}
}

// TestSetDemandRejectsNegativeDemand confirms SetDemand returns an error
// for negative pending demand rather than silently clamping it to zero.
func TestSetDemandRejectsNegativeDemand(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 4, 1, 0, false))

	if err := coordinator.SetDemand("alpha", -1); err == nil {
		t.Fatal("expected negative pending demand to be rejected")
	}
}

// TestSetDemandDeletesEntryOnZeroDemand confirms a zero pending demand
// deletes the profile's map entry rather than storing an explicit zero, so
// an arbitrary stream of one-off profile identities cannot grow the demand
// map without bound.
func TestSetDemandDeletesEntryOnZeroDemand(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, HostPolicy{
		Generation: 1,
		TotalUnits: 4,
		Profiles: []ProfilePolicy{
			{ProfileID: "alpha", UnitCost: 1},
		},
	})

	if err := coordinator.SetDemand("alpha", 3); err != nil {
		t.Fatalf("set demand: %v", err)
	}
	coordinator.mu.Lock()
	_, present := coordinator.demand["alpha"]
	coordinator.mu.Unlock()
	if !present {
		t.Fatal("expected a positive pending demand to be recorded")
	}

	if err := coordinator.SetDemand("alpha", 0); err != nil {
		t.Fatalf("set demand to zero: %v", err)
	}
	coordinator.mu.Lock()
	_, present = coordinator.demand["alpha"]
	coordinator.mu.Unlock()
	if present {
		t.Fatal("expected a zero pending demand to delete the map entry rather than store a zero")
	}
}

// --- Fairness rotation seeding across restart ------------------------------

// TestFairnessRotationIsSeededFromDurableDecisionSequenceAcrossRestart
// proves a restart does not always reset fairness priority to the first
// sorted profile. A fresh coordinator with no prior history breaks a tie
// between two equally-costed contenders in favor of the alphabetically
// first profile (rotation defaults to zero); this test seeds a durable
// document with a nonzero DecisionSequence before Open and confirms the
// restarted coordinator's rotation cursor instead favors the second
// profile for the single contested unit, matching the seeded value's
// effect on the guarantee-remainder distribution.
func TestFairnessRotationIsSeededFromDurableDecisionSequenceAcrossRestart(t *testing.T) {
	directory := t.TempDir()
	seed := newDurableState()
	seed.DecisionSequence = 1
	seed.Policy = HostPolicy{
		Generation: 1,
		TotalUnits: 1,
		Profiles: []ProfilePolicy{
			{ProfileID: "alpha", UnitCost: 1},
			{ProfileID: "beta", UnitCost: 1},
		},
	}
	if err := newFileStore(directory).Save(seed); err != nil {
		t.Fatalf("seed durable state: %v", err)
	}

	clock := newManualClock()
	coordinator, err := OpenFile(directory, clock, time.Minute)
	if err != nil {
		t.Fatalf("open seeded state: %v", err)
	}

	if err := coordinator.SetDemand("alpha", 1); err != nil {
		t.Fatalf("set demand alpha: %v", err)
	}
	if err := coordinator.SetDemand("beta", 1); err != nil {
		t.Fatalf("set demand beta: %v", err)
	}

	// With rotation seeded from DecisionSequence=1 and both profiles
	// contending for the single available unit, beta (sorted index 1)
	// wins the tie rather than alpha (sorted index 0): a fresh, unseeded
	// coordinator would always favor alpha instead.
	if _, err := coordinator.Acquire("beta", "beta-slot", 1); err != nil {
		t.Fatalf("expected beta to win the seeded rotation's tie, got %v", err)
	}
	if _, err := coordinator.Acquire("alpha", "alpha-slot", 1); !errors.Is(err, ErrBudgetExceeded) {
		t.Fatalf("expected alpha to lose the seeded rotation's tie, got %v", err)
	}
}

// --- Accounting semantics ---------------------------------------------------

// TestStatusAccountingSemanticsAcrossActiveProvisionalBorrowedPendingWithheld
// exercises the exact accounting definitions documented on Snapshot:
// activeUnits, provisionalUnits, heldUnits, reservedUnits,
// borrowedUnits=max(heldUnits-reservedUnits,0), pendingUnits, and
// withheldUnits, for two profiles in one policy, including a profile that
// borrows shared-pool capacity beyond its own reservation.
func TestStatusAccountingSemanticsAcrossActiveProvisionalBorrowedPendingWithheld(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, HostPolicy{
		Generation: 1,
		TotalUnits: 6,
		Profiles: []ProfilePolicy{
			{ProfileID: "alpha", UnitCost: 1, ReservedUnits: 2, Borrowable: false},
			{ProfileID: "beta", UnitCost: 1, ReservedUnits: 1, Borrowable: true},
		},
	})

	if _, err := coordinator.Acquire("alpha", "a1", 1); err != nil {
		t.Fatalf("acquire alpha a1: %v", err)
	}
	if _, err := coordinator.Acquire("alpha", "a2", 2); err != nil {
		t.Fatalf("acquire alpha a2: %v", err)
	}
	if _, err := coordinator.Activate("alpha", "a1"); err != nil {
		t.Fatalf("activate alpha a1: %v", err)
	}
	if _, err := coordinator.Acquire("beta", "b1", 1); err != nil {
		t.Fatalf("acquire beta b1 (own reservation): %v", err)
	}
	// beta's own reservation is now fully held (1/1); this second beta
	// lease must be granted from the shared pool instead, so beta ends up
	// holding one unit beyond its own reservation (a borrowed unit).
	if _, err := coordinator.Acquire("beta", "b2", 4); err != nil {
		t.Fatalf("acquire beta b2 (shared pool): %v", err)
	}
	if err := coordinator.SetDemand("alpha", 5); err != nil {
		t.Fatalf("set demand alpha: %v", err)
	}

	snapshot := mustStatus(t, coordinator)
	accounting := make(map[string]ProfileAccounting, len(snapshot.Accounting))
	for _, entry := range snapshot.Accounting {
		accounting[entry.ProfileID] = entry
	}

	alpha, ok := accounting["alpha"]
	if !ok {
		t.Fatal("expected alpha accounting to be present")
	}
	if alpha.ActiveUnits != 1 || alpha.ProvisionalUnits != 1 || alpha.HeldUnits != 2 {
		t.Fatalf("expected alpha active=1 provisional=1 held=2, got %#v", alpha)
	}
	if alpha.ReservedUnits != 2 || alpha.BorrowedUnits != 0 {
		t.Fatalf("expected alpha fully within its own reservation (borrowed=0), got %#v", alpha)
	}
	if pending := mustInt(t, alpha.PendingUnits, "alpha pending units"); pending != 5 {
		t.Fatalf("expected alpha pending=5, got %#v", alpha)
	}
	if withheld := mustInt(t, alpha.WithheldUnits, "alpha withheld units"); withheld != 5 {
		t.Fatalf("expected alpha withheld=5, got %#v", alpha)
	}

	beta, ok := accounting["beta"]
	if !ok {
		t.Fatal("expected beta accounting to be present")
	}
	if beta.ActiveUnits != 0 || beta.ProvisionalUnits != 2 || beta.HeldUnits != 2 {
		t.Fatalf("expected beta active=0 provisional=2 held=2, got %#v", beta)
	}
	if beta.ReservedUnits != 1 || beta.BorrowedUnits != 1 {
		t.Fatalf("expected beta reserved=1 borrowed=max(2-1,0)=1, got %#v", beta)
	}
	if pending := mustInt(t, beta.PendingUnits, "beta pending units"); pending != 3 {
		t.Fatalf("expected beta pending=3 after one successful grant, got %#v", beta)
	}
	if withheld := mustInt(t, beta.WithheldUnits, "beta withheld units"); withheld != 3 {
		t.Fatalf("expected beta withheld=3, got %#v", beta)
	}

	if snapshot.EffectiveTotalUnits != 6 {
		t.Fatalf("expected effective total units 6, got %d", snapshot.EffectiveTotalUnits)
	}
	if snapshot.AvailableUnits != 2 {
		t.Fatalf("expected available units 6-4=2, got %d", snapshot.AvailableUnits)
	}
}

func TestStatusConvertsPendingWorkersToPolicyUnits(t *testing.T) {
	coordinator := OpenMemory(newManualClock(), time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 12, 3, 0, false))
	if err := coordinator.SetDemand("alpha", 2); err != nil {
		t.Fatalf("set demand: %v", err)
	}

	accounting := mustStatus(t, coordinator).Accounting[0]
	if pending := mustInt(t, accounting.PendingUnits, "pending units"); pending != 6 {
		t.Fatalf("expected two workers at three units each to report six pending units, got %d", pending)
	}
	if withheld := mustInt(t, accounting.WithheldUnits, "withheld units"); withheld != 6 {
		t.Fatalf("expected all outstanding demand to remain withheld, got %d", withheld)
	}
}

func TestStatusReportsDemandUnknownAfterRestart(t *testing.T) {
	backing := newMemoryStore()
	clock := newManualClock()
	coordinator, err := Open(backing, clock, time.Minute)
	if err != nil {
		t.Fatalf("open coordinator: %v", err)
	}
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 4, 2, 0, false))
	if err := coordinator.SetDemand("alpha", 0); err != nil {
		t.Fatalf("publish known zero demand: %v", err)
	}
	if pending := mustInt(t, mustStatus(t, coordinator).Accounting[0].PendingUnits, "pending units"); pending != 0 {
		t.Fatalf("expected known zero demand before restart, got %d", pending)
	}

	restarted, err := Open(backing, clock, time.Minute)
	if err != nil {
		t.Fatalf("restart coordinator: %v", err)
	}
	accounting := mustStatus(t, restarted).Accounting[0]
	if accounting.PendingUnits != nil || accounting.WithheldUnits != nil {
		t.Fatalf("restart fabricated current demand from an empty in-memory ledger: %#v", accounting)
	}
}

func TestStatusSweepsExpiredProvisionals(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 2, 2, 0, false))
	if _, err := coordinator.Acquire("alpha", "slot-1", 1); err != nil {
		t.Fatalf("acquire provisional lease: %v", err)
	}
	clock.advance(2 * time.Minute)

	snapshot := mustStatus(t, coordinator)
	if len(snapshot.Leases) != 0 {
		t.Fatalf("status retained an expired provisional lease: %#v", snapshot.Leases)
	}
	if snapshot.AvailableUnits != 2 {
		t.Fatalf("expired provisional lease still consumed budget: %d", snapshot.AvailableUnits)
	}
	if snapshot.Accounting[0].PendingUnits != nil ||
		snapshot.Accounting[0].WithheldUnits != nil {
		t.Fatalf("expired provisional lease retained stale demand: %#v", snapshot.Accounting[0])
	}
}

// TestStatusReportsNamespaceCapacitySafetyMarginAndFingerprints proves the
// additive host-wide policy fields (Namespace, CapacityUnits,
// SafetyMarginUnits, EffectiveTotalUnits, HostPolicyFingerprint) and each
// profile's ProfilePolicyFingerprint round-trip unchanged from ApplyPolicy
// through Status.
func TestStatusReportsNamespaceCapacitySafetyMarginAndFingerprints(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, HostPolicy{
		Generation:            1,
		TotalUnits:            8,
		Namespace:             "ns-a",
		CapacityUnits:         10,
		SafetyMarginUnits:     2,
		HostPolicyFingerprint: "host-fingerprint-abc123",
		Profiles: []ProfilePolicy{
			{
				ProfileID:                "alpha",
				UnitCost:                 1,
				ProfilePolicyFingerprint: "profile-fingerprint-xyz789",
			},
		},
	})

	snapshot := mustStatus(t, coordinator)
	if snapshot.Namespace != "ns-a" {
		t.Fatalf("expected namespace ns-a, got %q", snapshot.Namespace)
	}
	if snapshot.CapacityUnits != 10 || snapshot.SafetyMarginUnits != 2 {
		t.Fatalf("expected capacity=10 safetyMargin=2, got capacity=%d safetyMargin=%d",
			snapshot.CapacityUnits, snapshot.SafetyMarginUnits)
	}
	if snapshot.EffectiveTotalUnits != 8 {
		t.Fatalf("expected effective total units 8, got %d", snapshot.EffectiveTotalUnits)
	}
	if snapshot.HostPolicyFingerprint != "host-fingerprint-abc123" {
		t.Fatalf("expected host fingerprint to round-trip, got %q", snapshot.HostPolicyFingerprint)
	}
	if len(snapshot.Accounting) != 1 || snapshot.Accounting[0].ProfilePolicyFingerprint != "profile-fingerprint-xyz789" {
		t.Fatalf("expected profile fingerprint to round-trip, got %#v", snapshot.Accounting)
	}
}

// --- Capacity/safety-margin/fingerprint/namespace validation ---------------

func TestPolicyValidationRejectsCapacitySafetyMarginTotalMismatch(t *testing.T) {
	policy := singleProfilePolicy("alpha", 7, 1, 0, false)
	policy.CapacityUnits = 10
	policy.SafetyMarginUnits = 2
	if err := policy.validate(); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("expected total units 7 to be rejected against capacity 10 minus margin 2 (=8), got %v", err)
	}
}

func TestPolicyValidationAcceptsMatchingCapacitySafetyMarginTotal(t *testing.T) {
	policy := singleProfilePolicy("alpha", 8, 1, 0, false)
	policy.CapacityUnits = 10
	policy.SafetyMarginUnits = 2
	if err := policy.validate(); err != nil {
		t.Fatalf("expected total units 8 to match capacity 10 minus margin 2, got %v", err)
	}
}

func TestPolicyValidationRejectsSafetyMarginWithoutCapacity(t *testing.T) {
	policy := singleProfilePolicy("alpha", 5, 1, 0, false)
	policy.SafetyMarginUnits = 1
	if err := policy.validate(); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("expected safety margin without capacity to be rejected, got %v", err)
	}
}

func TestPolicyValidationRejectsSafetyMarginAtOrAboveCapacity(t *testing.T) {
	policy := singleProfilePolicy("alpha", 5, 1, 0, false)
	policy.CapacityUnits = 5
	policy.SafetyMarginUnits = 5
	if err := policy.validate(); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("expected safety margin equal to capacity to be rejected, got %v", err)
	}
}

func TestPolicyValidationRejectsMalformedNamespace(t *testing.T) {
	policy := singleProfilePolicy("alpha", 5, 1, 0, false)
	policy.Namespace = "Bad_Namespace!"
	if err := policy.validate(); err == nil {
		t.Fatal("expected a malformed namespace to be rejected")
	}
}

func TestPolicyValidationAcceptsWellFormedNamespace(t *testing.T) {
	policy := singleProfilePolicy("alpha", 5, 1, 0, false)
	policy.Namespace = "ns-a"
	if err := policy.validate(); err != nil {
		t.Fatalf("expected a well-formed namespace to be accepted, got %v", err)
	}
}

func TestPolicyValidationRejectsMalformedHostPolicyFingerprint(t *testing.T) {
	policy := singleProfilePolicy("alpha", 5, 1, 0, false)
	policy.HostPolicyFingerprint = "not a valid fingerprint!"
	if err := policy.validate(); err == nil {
		t.Fatal("expected a malformed host policy fingerprint to be rejected")
	}
}

func TestPolicyValidationRejectsMalformedProfilePolicyFingerprint(t *testing.T) {
	policy := singleProfilePolicy("alpha", 5, 1, 0, false)
	policy.Profiles[0].ProfilePolicyFingerprint = "not a valid fingerprint!"
	if err := policy.validate(); err == nil {
		t.Fatal("expected a malformed profile policy fingerprint to be rejected")
	}
}

func TestPolicyValidationRejectsOversizedFingerprint(t *testing.T) {
	policy := singleProfilePolicy("alpha", 5, 1, 0, false)
	policy.HostPolicyFingerprint = strings.Repeat("a", maxFingerprintBytes+1)
	if err := policy.validate(); err == nil {
		t.Fatal("expected an oversized host policy fingerprint to be rejected")
	}
}

// --- LastDecision bounds -----------------------------------------------------

func TestLastDecisionRecordsGrantedAcquire(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 4, 1, 0, false))

	if _, err := coordinator.Acquire("alpha", "slot-1", 1); err != nil {
		t.Fatalf("acquire: %v", err)
	}
	snapshot := mustStatus(t, coordinator)
	decision := snapshot.LastDecision
	if decision == nil {
		t.Fatal("expected a last decision to be recorded")
	}
	if decision.Command != CommandAcquire || !decision.Granted {
		t.Fatalf("expected a granted acquire decision, got %#v", decision)
	}
	if decision.ProfileID != "alpha" {
		t.Fatalf("expected the decision to carry only the profile identity, got %#v", decision)
	}
	if decision.FailureCategory != "" {
		t.Fatalf("expected no failure category on a granted decision, got %q", decision.FailureCategory)
	}
	if decision.Sequence != snapshot.DecisionSequence {
		t.Fatalf("expected a granted decision's sequence to match the new decision sequence, got %d want %d",
			decision.Sequence, snapshot.DecisionSequence)
	}
}

func TestLastDecisionRecordsDeniedAcquireWithBoundedFailureCategory(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 1, 1, 0, false))

	if _, err := coordinator.Acquire("alpha", "slot-1", 1); err != nil {
		t.Fatalf("first acquire: %v", err)
	}
	sequenceBeforeDenial := mustStatus(t, coordinator).DecisionSequence

	if _, err := coordinator.Acquire("alpha", "slot-2", 1); !errors.Is(err, ErrBudgetExceeded) {
		t.Fatalf("expected the second acquire to be denied by budget, got %v", err)
	}

	snapshot := mustStatus(t, coordinator)
	decision := snapshot.LastDecision
	if decision == nil {
		t.Fatal("expected a last decision to be recorded for the denial")
	}
	if decision.Granted {
		t.Fatal("expected the denied acquire to be recorded as not granted")
	}
	if decision.FailureCategory != ErrorCodeBudgetExceeded {
		t.Fatalf("expected failure category %q, got %q", ErrorCodeBudgetExceeded, decision.FailureCategory)
	}
	if decision.Sequence != sequenceBeforeDenial {
		t.Fatalf("expected a denial to leave the decision sequence unchanged, got %d want %d",
			decision.Sequence, sequenceBeforeDenial)
	}
}

func TestLastDecisionTreatsDuplicateAcquireAsGranted(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 4, 1, 0, false))

	if _, err := coordinator.Acquire("alpha", "slot-1", 1); err != nil {
		t.Fatalf("first acquire: %v", err)
	}
	if _, err := coordinator.Acquire("alpha", "slot-1", 1); !errors.Is(err, ErrDuplicateLease) {
		t.Fatalf("expected a duplicate acquire, got %v", err)
	}

	decision := mustStatus(t, coordinator).LastDecision
	if decision == nil || !decision.Granted {
		t.Fatalf("expected a duplicate acquire to be recorded as granted, got %#v", decision)
	}
	if decision.FailureCategory != "" {
		t.Fatalf("expected no failure category on a duplicate-lease decision, got %q", decision.FailureCategory)
	}
}

func TestLastDecisionRecordsRelease(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 4, 1, 0, false))

	if _, err := coordinator.Acquire("alpha", "slot-1", 1); err != nil {
		t.Fatalf("acquire: %v", err)
	}
	if err := coordinator.Release("alpha", "slot-1"); err != nil {
		t.Fatalf("release: %v", err)
	}

	decision := mustStatus(t, coordinator).LastDecision
	if decision == nil || decision.Command != CommandRelease || !decision.Granted {
		t.Fatalf("expected a granted release decision, got %#v", decision)
	}
}

// TestLastDecisionNeverRecordedForNonLeaseCommands proves ApplyPolicy,
// SetDemand, and Status never produce a Decision: only Acquire, Renew,
// Activate, Release, and Reconcile are lease decisions.
func TestLastDecisionNeverRecordedForNonLeaseCommands(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 4, 1, 0, false))
	if err := coordinator.SetDemand("alpha", 2); err != nil {
		t.Fatalf("set demand: %v", err)
	}
	_ = mustStatus(t, coordinator)

	if decision := mustStatus(t, coordinator).LastDecision; decision != nil {
		t.Fatalf("expected no last decision from policy/demand/status calls alone, got %#v", decision)
	}
}

func TestCommandIsLeaseDecisionClosedVocabulary(t *testing.T) {
	cases := map[Command]bool{
		CommandAcquire:     true,
		CommandRenew:       true,
		CommandActivate:    true,
		CommandRelease:     true,
		CommandReconcile:   true,
		CommandApplyPolicy: false,
		CommandSetDemand:   false,
		CommandStatus:      false,
	}
	for command, expected := range cases {
		if got := command.isLeaseDecision(); got != expected {
			t.Fatalf("isLeaseDecision(%q) = %v, want %v", command, got, expected)
		}
	}
}

// TestLastDecisionPersistsAcrossRestart proves the bounded last decision
// survives a restart, including when the underlying lease was a
// provisional lease that Open discards on restart (ADR-0003): the decision
// record itself is independent durable bookkeeping, not tied to the
// lease's continued existence.
func TestLastDecisionPersistsAcrossRestart(t *testing.T) {
	directory := t.TempDir()
	clock := newManualClock()
	coordinator, err := OpenFile(directory, clock, time.Minute)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 4, 1, 0, false))
	if _, err := coordinator.Acquire("alpha", "slot-1", 1); err != nil {
		t.Fatalf("acquire: %v", err)
	}
	before := mustStatus(t, coordinator).LastDecision
	if before == nil {
		t.Fatal("expected a last decision before restart")
	}

	restarted, err := OpenFile(directory, clock, time.Minute)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	after := mustStatus(t, restarted).LastDecision
	if after == nil {
		t.Fatal("expected the last decision to survive a restart")
	}
	if after.Sequence != before.Sequence || after.Command != before.Command ||
		after.ProfileID != before.ProfileID || after.Granted != before.Granted {
		t.Fatalf("expected the last decision to be unchanged across restart, before=%#v after=%#v", before, after)
	}
}

// TestDurableStateValidationRejectsNonLeaseDecisionCommand proves a
// hand-crafted durable document whose lastDecision.command is not one of
// the five lease commands fails closed as corrupt state, rather than being
// silently accepted.
func TestDurableStateValidationRejectsNonLeaseDecisionCommand(t *testing.T) {
	directory := t.TempDir()
	statePath := filepath.Join(directory, "admission-state.json")
	document := `{"schemaVersion":1,"epoch":0,"decisionSequence":1,` +
		`"policy":{"generation":0,"totalUnits":0,"profiles":null},"leases":{},"tombstones":{},` +
		`"lastDecision":{"sequence":1,"command":"status","granted":true,"decidedAtUnixNano":1}}`
	if err := writeFileAtomically(statePath, []byte(document)); err != nil {
		t.Fatalf("seed state: %v", err)
	}
	if _, err := OpenFile(directory, newManualClock(), time.Minute); !errors.Is(err, ErrCorruptState) {
		t.Fatalf("expected a non-lease decision command to fail closed as corrupt state, got %v", err)
	}
}

// TestDurableStateValidationRejectsNegativeLastDecisionSequence proves a
// hand-crafted durable document whose lastDecision.sequence is negative
// fails closed as corrupt state.
func TestDurableStateValidationRejectsNegativeLastDecisionSequence(t *testing.T) {
	directory := t.TempDir()
	statePath := filepath.Join(directory, "admission-state.json")
	document := `{"schemaVersion":1,"epoch":0,"decisionSequence":1,` +
		`"policy":{"generation":0,"totalUnits":0,"profiles":null},"leases":{},"tombstones":{},` +
		`"lastDecision":{"sequence":-1,"command":"acquire","granted":true,"decidedAtUnixNano":1}}`
	if err := writeFileAtomically(statePath, []byte(document)); err != nil {
		t.Fatalf("seed state: %v", err)
	}
	if _, err := OpenFile(directory, newManualClock(), time.Minute); !errors.Is(err, ErrCorruptState) {
		t.Fatalf("expected a negative last decision sequence to fail closed as corrupt state, got %v", err)
	}
}

// TestAbsentLastDecisionRemainsValidForOlderDocuments proves a durable
// document written before lastDecision existed (schema-compatible but
// missing the field) decodes with a nil LastDecision and remains valid,
// rather than being treated as corrupt.
func TestAbsentLastDecisionRemainsValidForOlderDocuments(t *testing.T) {
	directory := t.TempDir()
	statePath := filepath.Join(directory, "admission-state.json")
	document := `{"schemaVersion":1,"epoch":0,"decisionSequence":0,` +
		`"policy":{"generation":0,"totalUnits":0,"profiles":null},"leases":{},"tombstones":{}}`
	if err := writeFileAtomically(statePath, []byte(document)); err != nil {
		t.Fatalf("seed state: %v", err)
	}
	coordinator, err := OpenFile(directory, newManualClock(), time.Minute)
	if err != nil {
		t.Fatalf("expected an absent lastDecision field to remain valid, got %v", err)
	}
	if decision := mustStatus(t, coordinator).LastDecision; decision != nil {
		t.Fatalf("expected a nil last decision for a document that predates it, got %#v", decision)
	}
}
