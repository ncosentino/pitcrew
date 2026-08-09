package admission

import (
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

// Clock supplies the coordinator's monotonic notion of time. Production
// callers use SystemClock; tests supply a deterministic implementation so
// provisional expiry, renewal, and activation rejection are exercised
// without real sleeps.
type Clock interface {
	Now() time.Time
}

// SystemClock is the production Clock backed by the wall clock.
type SystemClock struct{}

// Now returns the current wall-clock time.
func (SystemClock) Now() time.Time { return time.Now() }

// DefaultProvisionalLeaseTTL is the fallback provisional lease lifetime used
// when a coordinator is constructed without an explicit TTL. Later setup
// wiring may configure a different value; this package does not treat this
// constant as a measured host default.
const DefaultProvisionalLeaseTTL = 30 * time.Second

// maxEvidenceBytes bounds Reconcile evidence to a strict, sanitized format:
// a short, single-line, UTF-8 operator audit note rather than free-form or
// arbitrarily large text.
const maxEvidenceBytes = 512

// Coordinator is the single, mutex-serialized owner of atomic allocation,
// per-profile reservations, borrowing, fairness, the durable decision
// sequence, and durable epochs for one Docker daemon's admission namespace.
// It has no Docker, GitHub, or transport dependency; server.go and client.go
// expose it over a Unix domain socket for use by shell and Go managers.
type Coordinator struct {
	mu             sync.Mutex
	store          store
	clock          Clock
	provisionalTTL time.Duration
	state          durableState
	demand         map[string]int
	rotation       int

	// provisionalDeadlines is the sole authority this package trusts for
	// deciding whether a provisional lease has expired. ADR-0003 requires
	// service-owned monotonic expiry; a durable, restartable timestamp
	// alone is not a monotonic clock reading from this process, so every
	// live provisional lease's deadline is tracked here, keyed by lease
	// key, and is populated only by Acquire and Renew in this process. It
	// is intentionally never persisted: Open discards every restored
	// provisional lease before serving any request (see
	// discardRestoredProvisionals), so a live provisional lease always has
	// an entry here for as long as it exists in c.state.Leases.
	provisionalDeadlines map[string]time.Time
}

// Open restores the coordinator from durable state, failing closed on any
// corrupt or unsupported document. A missing document is a legitimate fresh
// start with no policy and no leases; ApplyPolicy must be called before any
// Acquire will succeed.
//
// Every provisional lease found in a restored document is tombstoned before
// Open returns: a provisional lease's monotonic expiry lives only in the
// process memory of the coordinator that granted or last renewed it, so a
// restored provisional cannot be trusted across a restart and is discarded
// rather than assumed alive or silently re-timed. Only active leases, which
// never expire from time alone, survive a restart. The discard is persisted
// atomically before Open returns, so a crash immediately after restart can
// never re-introduce a stale provisional lease.
func Open(backing store, clock Clock, provisionalTTL time.Duration) (*Coordinator, error) {
	if clock == nil {
		clock = SystemClock{}
	}
	if provisionalTTL <= 0 {
		provisionalTTL = DefaultProvisionalLeaseTTL
	}
	state, exists, err := backing.Load()
	if err != nil {
		return nil, err
	}
	if !exists {
		state = newDurableState()
	} else if pruned, changed := discardRestoredProvisionals(state); changed {
		if err := backing.Save(pruned); err != nil {
			return nil, fmt.Errorf("persist restart-discarded provisional leases: %w", err)
		}
		state = pruned
	}
	return &Coordinator{
		store:                backing,
		clock:                clock,
		provisionalTTL:       provisionalTTL,
		state:                state,
		demand:               make(map[string]int),
		provisionalDeadlines: make(map[string]time.Time),
	}, nil
}

// discardRestoredProvisionals tombstones every provisional lease found in a
// freshly loaded document, bounding the resulting tombstone set the same
// way any other tombstoning operation does. It reports whether anything
// changed so Open can skip a redundant persist for a document with no
// restored provisional leases.
func discardRestoredProvisionals(state durableState) (durableState, bool) {
	next := state.clone()
	changed := false
	for key, lease := range next.Leases {
		if lease.Status != LeaseProvisional {
			continue
		}
		sequence := next.DecisionSequence + 1
		next.DecisionSequence = sequence
		delete(next.Leases, key)
		next.Tombstones[key] = Tombstone{
			ProfileID: lease.ProfileID,
			SlotKey:   lease.SlotKey,
			LeaseID:   lease.LeaseID,
			Reason:    TombstoneRestartDiscarded,
			Sequence:  sequence,
		}
		changed = true
	}
	if changed {
		next = compactTombstones(next)
	}
	return next, changed
}

// OpenFile restores or creates a coordinator backed by a durable JSON
// document at directory/admission-state.json.
func OpenFile(directory string, clock Clock, provisionalTTL time.Duration) (*Coordinator, error) {
	return Open(newFileStore(directory), clock, provisionalTTL)
}

// OpenMemory creates a coordinator backed by a non-durable in-memory store.
// It is used for tests and for standalone protocol exercises; it never
// fails, since there is no prior document to be corrupt.
func OpenMemory(clock Clock, provisionalTTL time.Duration) *Coordinator {
	coordinator, err := Open(newMemoryStore(), clock, provisionalTTL)
	if err != nil {
		// newMemoryStore never returns exists=true on first Load, so Open
		// cannot fail here; a panic would indicate a bug in this package.
		panic(fmt.Sprintf("admission: unexpected error opening memory store: %v", err))
	}
	return coordinator
}

// ApplyPolicy validates and durably applies a new host policy. It rejects a
// generation that does not strictly advance the currently applied
// generation, so a replayed or reordered publication can never move
// admission backward. Existing leases are never touched by a policy change;
// a profile removed from policy simply stops accepting new Acquire calls
// while its outstanding leases continue to occupy budget until explicitly
// released, draining naturally rather than being revoked.
func (c *Coordinator) ApplyPolicy(policy HostPolicy) error {
	if err := policy.validate(); err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if policy.Generation <= c.state.Policy.Generation {
		return ErrStalePolicy
	}
	next := c.state.clone()
	next.Policy = clonePolicy(policy)
	next.Epoch++
	if err := c.store.Save(next); err != nil {
		return err
	}
	c.state = next
	return nil
}

// SetDemand publishes one profile's current pending demand so the fair
// shared pool can be partitioned without waiting for that profile's own
// Acquire call to arrive. It does not itself grant or consume any unit.
func (c *Coordinator) SetDemand(profileID string, pending int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if pending < 0 {
		pending = 0
	}
	c.demand[profileID] = pending
}

// Acquire requests one provisional lease of exactly the requesting profile's
// configured unit cost for one exact profile and slot. pendingDemand is the
// caller's current total outstanding demand for this profile, including this
// request, and is used only to partition the fair shared pool; it does not
// change the size of the lease itself.
//
// A duplicate call for a profile/slot pair that already holds a live lease
// returns that lease unchanged alongside ErrDuplicateLease, so a safe retry
// after an ambiguous response never double-counts budget.
func (c *Coordinator) Acquire(profileID, slotKey string, pendingDemand int) (Lease, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.clock.Now()
	if _, err := c.sweepExpiredLocked(now); err != nil {
		return Lease{}, err
	}

	key := leaseKey{profileID: profileID, slotKey: slotKey}
	if existing, exists := c.state.Leases[key.String()]; exists {
		return existing, ErrDuplicateLease
	}
	profilePolicy, known := c.state.Policy.profile(profileID)
	if !known {
		return Lease{}, ErrUnknownProfile
	}
	if pendingDemand < 1 {
		pendingDemand = 1
	}
	c.demand[profileID] = pendingDemand

	unitCost := profilePolicy.UnitCost
	held := c.heldUnitsByProfileLocked()
	totalHeld := 0
	for _, units := range held {
		totalHeld += units
	}
	free := c.state.Policy.TotalUnits - totalHeld
	if free < unitCost {
		return Lease{}, ErrBudgetExceeded
	}

	ownRemaining := max(profilePolicy.ReservedUnits-held[profileID], 0)
	fromReservation := ownRemaining >= unitCost
	if !fromReservation {
		protected := c.protectedNonBorrowableLocked(profileID, held)
		available := free - protected
		if available < unitCost {
			return Lease{}, ErrBudgetExceeded
		}
		if !c.fairTurnLocked(profileID, held, available, unitCost) {
			return Lease{}, ErrBudgetExceeded
		}
	}

	sequence := c.state.DecisionSequence + 1
	deadline := now.Add(c.provisionalTTL)
	lease := Lease{
		ProfileID:         profileID,
		SlotKey:           slotKey,
		LeaseID:           fmt.Sprintf("%s#%d", key.String(), sequence),
		Units:             unitCost,
		Status:            LeaseProvisional,
		ExpiresAtUnixNano: deadline.UnixNano(),
		GrantedAtSequence: sequence,
	}
	next := c.state.clone()
	next.DecisionSequence = sequence
	// A slot's prior tombstone, if any, is superseded by this fresh grant:
	// a lease and a tombstone must never coexist for the same key.
	delete(next.Tombstones, key.String())
	next.Leases[key.String()] = lease
	if err := c.store.Save(next); err != nil {
		return Lease{}, err
	}
	c.state = next
	c.provisionalDeadlines[key.String()] = deadline
	return lease, nil
}

// Renew extends a provisional lease's monotonic expiry while bounded
// pre-launch work continues. It fails closed with ErrLeaseExpired if the
// lease already elapsed, and ErrLeaseNotProvisional if the lease was already
// activated; only a provisional lease has an expiry to extend.
func (c *Coordinator) Renew(profileID, slotKey string) (Lease, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.clock.Now()
	expired, err := c.sweepExpiredLocked(now)
	if err != nil {
		return Lease{}, err
	}
	key := leaseKey{profileID: profileID, slotKey: slotKey}.String()
	if expired[key] {
		return Lease{}, ErrLeaseExpired
	}
	lease, exists := c.state.Leases[key]
	if !exists {
		return Lease{}, ErrLeaseNotFound
	}
	if lease.Status != LeaseProvisional {
		return Lease{}, ErrLeaseNotProvisional
	}
	deadline := now.Add(c.provisionalTTL)
	lease.ExpiresAtUnixNano = deadline.UnixNano()
	next := c.state.clone()
	next.DecisionSequence++
	next.Leases[key] = lease
	if err := c.store.Save(next); err != nil {
		return Lease{}, err
	}
	c.state = next
	c.provisionalDeadlines[key] = deadline
	return lease, nil
}

// Activate promotes a provisional lease to active only if it has not
// expired. Activation of an already-active lease is idempotent, so a
// manager can safely retry after an ambiguous acknowledgement. A worker
// process must never be started before Activate succeeds.
func (c *Coordinator) Activate(profileID, slotKey string) (Lease, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.clock.Now()
	expired, err := c.sweepExpiredLocked(now)
	if err != nil {
		return Lease{}, err
	}
	key := leaseKey{profileID: profileID, slotKey: slotKey}.String()
	if expired[key] {
		return Lease{}, ErrLeaseExpired
	}
	lease, exists := c.state.Leases[key]
	if !exists {
		return Lease{}, ErrLeaseNotFound
	}
	if lease.Status == LeaseActive {
		return lease, nil
	}
	sequence := c.state.DecisionSequence + 1
	lease.Status = LeaseActive
	lease.ExpiresAtUnixNano = 0
	lease.ActivatedAtSequence = sequence
	next := c.state.clone()
	next.DecisionSequence = sequence
	next.Leases[key] = lease
	if err := c.store.Save(next); err != nil {
		return Lease{}, err
	}
	c.state = next
	delete(c.provisionalDeadlines, key)
	return lease, nil
}

// Release performs an exact, durable release of one lease, whether
// provisional or active, and records a tombstone. Releasing an
// already-tombstoned slot is a safe idempotent no-op. Releasing a slot that
// never existed and was never tombstoned returns ErrLeaseNotFound.
func (c *Coordinator) Release(profileID, slotKey string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.clock.Now()
	if _, err := c.sweepExpiredLocked(now); err != nil {
		return err
	}
	return c.tombstoneLocked(profileID, slotKey, TombstoneReleased, "")
}

// sanitizeEvidence enforces the strict format Reconcile requires: a
// trimmed, non-empty, single-line UTF-8 string no longer than
// maxEvidenceBytes. Evidence is a durable, operator-visible audit record,
// not free-form text, so this package rejects anything that cannot be
// stored and displayed unambiguously.
func sanitizeEvidence(evidence string) (string, error) {
	trimmed := strings.TrimSpace(evidence)
	if trimmed == "" {
		return "", ErrEvidenceRequired
	}
	if len(trimmed) > maxEvidenceBytes {
		return "", fmt.Errorf(
			"%w: evidence exceeds %d bytes",
			ErrEvidenceInvalid,
			maxEvidenceBytes,
		)
	}
	if !utf8.ValidString(trimmed) {
		return "", fmt.Errorf("%w: evidence must be valid UTF-8", ErrEvidenceInvalid)
	}
	for _, r := range trimmed {
		if r == '\n' || r == '\r' || unicode.IsControl(r) {
			return "", fmt.Errorf(
				"%w: evidence must not contain control characters or newlines",
				ErrEvidenceInvalid,
			)
		}
	}
	return trimmed, nil
}

// Reconcile is the fenced recovery path: a replacement manager that has
// proved, through exact retained evidence, that the previous worker and
// registration are absent may release a stranded active lease. Empty
// evidence is rejected outright; time alone never releases an active lease.
func (c *Coordinator) Reconcile(profileID, slotKey, evidence string) error {
	sanitized, err := sanitizeEvidence(evidence)
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.clock.Now()
	if _, err := c.sweepExpiredLocked(now); err != nil {
		return err
	}
	return c.tombstoneLocked(profileID, slotKey, TombstoneReconciledAbsent, sanitized)
}

func (c *Coordinator) tombstoneLocked(
	profileID, slotKey string,
	reason TombstoneReason,
	evidence string,
) error {
	key := leaseKey{profileID: profileID, slotKey: slotKey}.String()
	lease, exists := c.state.Leases[key]
	if !exists {
		if _, tombstoned := c.state.Tombstones[key]; tombstoned {
			return nil
		}
		return ErrLeaseNotFound
	}
	sequence := c.state.DecisionSequence + 1
	next := c.state.clone()
	next.DecisionSequence = sequence
	delete(next.Leases, key)
	next.Tombstones[key] = Tombstone{
		ProfileID: profileID,
		SlotKey:   slotKey,
		LeaseID:   lease.LeaseID,
		Reason:    reason,
		Evidence:  evidence,
		Sequence:  sequence,
	}
	next = compactTombstones(next)
	if err := c.store.Save(next); err != nil {
		return err
	}
	c.state = next
	delete(c.provisionalDeadlines, key)
	return nil
}

// Snapshot is a read-only, deterministically ordered view of the
// coordinator's durable state, suitable for the CLI status subcommand and
// for tests.
type Snapshot struct {
	Epoch            int64       `json:"epoch"`
	DecisionSequence int64       `json:"decisionSequence"`
	Policy           HostPolicy  `json:"policy"`
	Leases           []Lease     `json:"leases"`
	Tombstones       []Tombstone `json:"tombstones"`
}

// Status returns a deterministic snapshot of the current durable state.
func (c *Coordinator) Status() Snapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	snapshot := Snapshot{
		Epoch:            c.state.Epoch,
		DecisionSequence: c.state.DecisionSequence,
		Policy:           clonePolicy(c.state.Policy),
	}
	for _, key := range sortedStateKeys(c.state.Leases) {
		snapshot.Leases = append(snapshot.Leases, c.state.Leases[key])
	}
	for _, key := range sortedStateKeys(c.state.Tombstones) {
		snapshot.Tombstones = append(snapshot.Tombstones, c.state.Tombstones[key])
	}
	return snapshot
}

// sweepExpiredLocked removes every provisional lease whose in-process
// monotonic deadline has elapsed as of now, tombstones each as expired, and
// persists the result if anything changed. It returns the set of lease keys
// expired by this exact call so callers can distinguish "just expired" from
// "never existed" when reporting ErrLeaseExpired.
//
// Expiry is decided solely from c.provisionalDeadlines, the in-process
// monotonic deadline set by Acquire or Renew; the durable
// Lease.ExpiresAtUnixNano field is never consulted here. A provisional
// lease with no tracked deadline is an invariant violation this package
// does not expect to occur (every live provisional lease's deadline is
// populated when the lease is granted or renewed, and restored provisional
// leases are discarded before Open returns), so it fails closed by treating
// the lease as already expired rather than assuming it is still alive.
func (c *Coordinator) sweepExpiredLocked(now time.Time) (map[string]bool, error) {
	expired := make(map[string]bool)
	next := c.state.clone()
	changed := false
	for key, lease := range next.Leases {
		if lease.Status != LeaseProvisional {
			continue
		}
		deadline, tracked := c.provisionalDeadlines[key]
		if tracked && now.Before(deadline) {
			continue
		}
		sequence := next.DecisionSequence + 1
		next.DecisionSequence = sequence
		delete(next.Leases, key)
		next.Tombstones[key] = Tombstone{
			ProfileID: lease.ProfileID,
			SlotKey:   lease.SlotKey,
			LeaseID:   lease.LeaseID,
			Reason:    TombstoneExpired,
			Sequence:  sequence,
		}
		expired[key] = true
		changed = true
	}
	if !changed {
		return expired, nil
	}
	next = compactTombstones(next)
	if err := c.store.Save(next); err != nil {
		return nil, err
	}
	c.state = next
	for key := range expired {
		delete(c.provisionalDeadlines, key)
	}
	return expired, nil
}

func (c *Coordinator) heldUnitsByProfileLocked() map[string]int {
	held := make(map[string]int, len(c.state.Policy.Profiles))
	for _, lease := range c.state.Leases {
		held[lease.ProfileID] += lease.Units
	}
	return held
}

// protectedNonBorrowableLocked sums every other profile's currently unused
// non-borrowable reservation. Those units must never be handed to the
// shared/fair pool: a non-borrowable reservation stays protected headroom
// even while idle.
func (c *Coordinator) protectedNonBorrowableLocked(requester string, held map[string]int) int {
	protected := 0
	for _, other := range c.state.Policy.Profiles {
		if other.ProfileID == requester || other.Borrowable {
			continue
		}
		protected += max(other.ReservedUnits-held[other.ProfileID], 0)
	}
	return protected
}

// fairTurnLocked decides whether profileID wins this round of access to the
// available shared-pool units. Available is first partitioned into an equal,
// rotating guaranteed share among every profile with registered pending
// demand; a profile whose shared-pool holdings plus this exact request
// still fit within its guarantee is admitted immediately, and a profile that
// would exceed its guarantee is admitted only if capacity remains after
// every other demanding profile's own guarantee is protected. The rotation
// cursor advances on every shared-pool grant so repeated contention cannot
// always favor the same profile.
func (c *Coordinator) fairTurnLocked(
	profileID string,
	held map[string]int,
	available int,
	unitCost int,
) bool {
	contenders := c.contendersLocked()
	count := len(contenders)
	if count == 0 {
		return available >= unitCost
	}
	index := sort.SearchStrings(contenders, profileID)
	isContender := index < count && contenders[index] == profileID

	if isContender {
		guarantee := c.guaranteedShareLocked(contenders, index, available)
		sharedHeld := max(held[profileID]-c.reservedUnitsLocked(profileID), 0)
		if sharedHeld+unitCost <= guarantee {
			c.advanceRotationLocked(count)
			return true
		}
	}

	protected := 0
	for otherIndex, id := range contenders {
		if id == profileID {
			continue
		}
		otherGuarantee := c.guaranteedShareLocked(contenders, otherIndex, available)
		otherShared := max(held[id]-c.reservedUnitsLocked(id), 0)
		if otherShared < otherGuarantee {
			protected += otherGuarantee - otherShared
		}
	}
	if available-protected >= unitCost {
		c.advanceRotationLocked(count)
		return true
	}
	return false
}

// contendersLocked returns every policy-known profile with registered
// pending demand, sorted for deterministic guarantee assignment.
func (c *Coordinator) contendersLocked() []string {
	ids := make([]string, 0, len(c.demand))
	for id, pending := range c.demand {
		if pending <= 0 {
			continue
		}
		if _, known := c.state.Policy.profile(id); !known {
			continue
		}
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

// guaranteedShareLocked splits available evenly across contenders, rotating
// which contenders receive the integer-division remainder so no single
// profile is permanently favored by rounding.
func (c *Coordinator) guaranteedShareLocked(contenders []string, index, available int) int {
	count := len(contenders)
	if count == 0 {
		return available
	}
	base := available / count
	remainder := available % count
	if (index-c.rotation+count)%count < remainder {
		return base + 1
	}
	return base
}

func (c *Coordinator) advanceRotationLocked(contenderCount int) {
	if contenderCount == 0 {
		return
	}
	c.rotation = (c.rotation + 1) % contenderCount
}

func (c *Coordinator) reservedUnitsLocked(profileID string) int {
	if profile, ok := c.state.Policy.profile(profileID); ok {
		return profile.ReservedUnits
	}
	return 0
}
