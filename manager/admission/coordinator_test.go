package admission

import (
	"path/filepath"
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
	snapshot := coordinator.Status()
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
				snapshot := coordinator.Status()
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
	snapshot := coordinator.Status()
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
	snapshot := restarted.Status()
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
	snapshot := coordinator.Status()
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
	snapshot := coordinator.Status()
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
	snapshot := coordinator.Status()
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

	snapshot := coordinator.Status()
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
