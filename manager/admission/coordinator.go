package admission

import (
	"errors"
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

// DefaultDemandTTL bounds how long one positive pending-demand publication
// participates in shared-pool fairness without a SetDemand or Acquire refresh.
// Active and provisional leases use their own lifecycle and are never released
// by demand expiry.
const DefaultDemandTTL = 30 * time.Second

// maxEvidenceBytes bounds Reconcile evidence to a strict, sanitized format:
// a short, single-line, UTF-8 operator audit note rather than free-form or
// arbitrarily large text.
const maxEvidenceBytes = 512

// rotationSeedModulus bounds the durable decision sequence before it is
// cast to the in-memory rotation cursor's int type. Its value is an
// arbitrary large prime with no functional significance beyond keeping the
// cast well-behaved across platforms: rotation is always subsequently used
// modulo the much smaller live contender count.
const rotationSeedModulus = 1_000_000_007

// Coordinator is the single, mutex-serialized owner of atomic allocation,
// per-profile reservations, borrowing, fairness, the durable decision
// sequence, and durable epochs for one Docker daemon's admission namespace.
// It has no Docker, GitHub, or transport dependency; server.go and client.go
// expose it over a Unix domain socket for use by shell and Go managers.
type Coordinator struct {
	mu              sync.Mutex
	store           store
	clock           Clock
	provisionalTTL  time.Duration
	state           durableState
	demand          map[string]int
	demandKnown     map[string]bool
	demandDeadlines map[string]time.Time
	rotation        int

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
		store:           backing,
		clock:           clock,
		provisionalTTL:  provisionalTTL,
		state:           state,
		demand:          make(map[string]int),
		demandKnown:     make(map[string]bool),
		demandDeadlines: make(map[string]time.Time),
		// Seeding rotation from the durable decision sequence, rather than
		// always starting at zero, prevents a restart from always
		// re-favoring the first sorted profile in a fairness tie: the
		// exact modulus has no measured significance since rotation is
		// always used modulo the much smaller live contender count.
		rotation:             int(state.DecisionSequence % rotationSeedModulus),
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
	for profileID := range next.AdoptionFences {
		if _, retained := policy.profile(profileID); !retained {
			delete(next.AdoptionFences, profileID)
		}
	}
	if err := c.store.Save(next); err != nil {
		return err
	}
	c.state = next
	c.demand = make(map[string]int)
	c.demandKnown = make(map[string]bool)
	c.demandDeadlines = make(map[string]time.Time)
	return nil
}

// SetDemand publishes one profile's current pending worker count so the fair
// shared pool can be partitioned without waiting for that profile's own
// Acquire call to arrive. It does not itself grant or consume any unit.
//
// profileID must match the public profile identity syntax and must be
// known to the currently applied policy; pending must not be negative. A
// positive demand expires unless SetDemand or Acquire refreshes it. A pending
// value of zero deletes the profile's demand entry rather than storing a zero,
// so an arbitrary stream of stale or one-off profile identities can never grow
// this map without bound.
func (c *Coordinator) SetDemand(profileID string, pending int) error {
	if err := validateProfileID(profileID); err != nil {
		return err
	}
	if pending < 0 {
		return fmt.Errorf("admission: pending demand cannot be negative, got %d", pending)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, known := c.state.Policy.profile(profileID); !known {
		return ErrUnknownProfile
	}
	now := c.clock.Now()
	c.expireStaleDemandLocked(now)
	c.demandKnown[profileID] = true
	if pending == 0 {
		delete(c.demand, profileID)
		delete(c.demandDeadlines, profileID)
		return nil
	}
	c.demand[profileID] = pending
	c.demandDeadlines[profileID] = now.Add(DefaultDemandTTL)
	return nil
}

// BeginAdoption durably fences ordinary host admission while one profile
// manager reconciles workers left running by its predecessor. The operation
// is idempotent so Setup and the replacement manager can both establish the
// same fence before recovery begins.
func (c *Coordinator) BeginAdoption(profileID string) error {
	if err := validateProfileID(profileID); err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, known := c.state.Policy.profile(profileID); !known {
		return ErrUnknownProfile
	}
	if _, exists := c.state.AdoptionFences[profileID]; exists {
		return nil
	}
	next := c.state.clone()
	next.Epoch++
	next.AdoptionFences[profileID] = AdoptionFence{
		ProfileID:        profileID,
		PendingLeaseKeys: activeLeaseSlotKeys(next.Leases, profileID),
	}
	if err := c.store.Save(next); err != nil {
		return err
	}
	c.state = next
	return nil
}

// CompleteAdoption clears one profile manager's recovery fence. It is
// idempotent because a manager may retry after an ambiguous acknowledgement.
func (c *Coordinator) CompleteAdoption(profileID string) error {
	if err := validateProfileID(profileID); err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	fence, exists := c.state.AdoptionFences[profileID]
	if !exists {
		return nil
	}
	if len(fence.PendingLeaseKeys) > 0 {
		return fmt.Errorf(
			"%w: %d active lease(s) remain unaccounted",
			ErrAdoptionPending,
			len(fence.PendingLeaseKeys),
		)
	}
	next := c.state.clone()
	next.Epoch++
	delete(next.AdoptionFences, profileID)
	if err := c.store.Save(next); err != nil {
		return err
	}
	c.state = next
	return nil
}

// Acquire requests one provisional lease of exactly the requesting profile's
// configured unit cost for one exact profile and slot. pendingDemand is the
// caller's current total outstanding worker count for this profile, including
// this request. It is used only to partition the fair shared pool and is
// converted to policy units only for status reporting.
//
// A duplicate call for a profile/slot pair that already holds a live lease
// returns that lease unchanged alongside ErrDuplicateLease, so a safe retry
// after an ambiguous response never double-counts budget.
func (c *Coordinator) Acquire(profileID, slotKey string, pendingDemand int) (lease Lease, err error) {
	if err = validateLeaseIdentity(profileID, slotKey); err != nil {
		return Lease{}, err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.clock.Now()
	defer func() {
		granted := err == nil || errors.Is(err, ErrDuplicateLease)
		c.recordDecisionLocked(CommandAcquire, profileID, granted, err, now)
	}()
	if _, err = c.sweepExpiredLocked(now); err != nil {
		return Lease{}, err
	}
	c.expireStaleDemandLocked(now)
	if len(c.state.AdoptionFences) > 0 {
		return Lease{}, ErrAdoptionPending
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
	c.demandKnown[profileID] = true
	c.demandDeadlines[profileID] = now.Add(DefaultDemandTTL)

	unitCost := profilePolicy.UnitCost
	held := c.heldUnitsByProfileLocked()
	sharedPoolContenders, err := c.evaluateAcquireLocked(
		profileID,
		profilePolicy,
		held,
	)
	if err != nil {
		return Lease{}, err
	}

	sequence := c.state.DecisionSequence + 1
	deadline := now.Add(c.provisionalTTL)
	granted := Lease{
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
	next.Leases[key.String()] = granted
	if err = c.store.Save(next); err != nil {
		return Lease{}, err
	}
	c.state = next
	c.provisionalDeadlines[key.String()] = deadline
	if pendingDemand == 1 {
		delete(c.demand, profileID)
		delete(c.demandDeadlines, profileID)
	} else {
		c.demand[profileID] = pendingDemand - 1
	}
	// The rotation cursor advances only once this grant is durably saved:
	// a save failure must never move fairness priority for a request that
	// was not actually admitted.
	if sharedPoolContenders > 0 {
		c.advanceRotationLocked(sharedPoolContenders)
	}
	return granted, nil
}

func (c *Coordinator) evaluateAcquireLocked(
	profileID string,
	profilePolicy ProfilePolicy,
	held map[string]int,
) (int, error) {
	totalHeld := 0
	for _, units := range held {
		totalHeld += units
	}
	free := c.state.Policy.TotalUnits - totalHeld
	if free < profilePolicy.UnitCost {
		return 0, ErrBudgetExhausted
	}

	ownRemaining := max(profilePolicy.ReservedUnits-held[profileID], 0)
	if ownRemaining >= profilePolicy.UnitCost {
		return 0, nil
	}

	protected := c.protectedNonBorrowableLocked(profileID, held)
	available := free - protected
	if available < profilePolicy.UnitCost {
		return 0, ErrProtectedReservation
	}
	granted, contenders := c.fairTurnLocked(
		profileID,
		held,
		available,
		profilePolicy.UnitCost,
	)
	if !granted {
		return 0, ErrFairShareContention
	}
	return contenders, nil
}

// BindRegistration stores the exact bounded GitHub runner name associated
// with a live lease. It changes no capacity and is idempotent for the same
// binding; conflicting rebinding fails closed.
func (c *Coordinator) BindRegistration(
	profileID,
	slotKey,
	registrationName string,
) (Lease, error) {
	if err := validateLeaseIdentity(profileID, slotKey); err != nil {
		return Lease{}, err
	}
	if err := validateRegistrationName(registrationName); err != nil {
		return Lease{}, fmt.Errorf("%w: registration name is invalid", err)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, err := c.sweepExpiredLocked(c.clock.Now()); err != nil {
		return Lease{}, err
	}
	key := leaseKey{profileID: profileID, slotKey: slotKey}.String()
	existing, exists := c.state.Leases[key]
	if !exists {
		return Lease{}, ErrLeaseNotFound
	}
	if existing.RegistrationName == registrationName {
		return existing, nil
	}
	if existing.RegistrationName != "" {
		return Lease{}, fmt.Errorf(
			"%w: lease registration name is already bound",
			ErrInvalidIdentity,
		)
	}
	existing.RegistrationName = registrationName
	next := c.state.clone()
	next.DecisionSequence++
	next.Leases[key] = existing
	if err := c.store.Save(next); err != nil {
		return Lease{}, err
	}
	c.state = next
	return existing, nil
}

// Adopt records an already-running worker as an active lease. Unlike Acquire,
// it never rejects the worker for lack of budget because that host usage
// already exists. Existing active leases are returned unchanged, while an
// existing provisional lease is promoted because the exact worker is running.
func (c *Coordinator) Adopt(profileID, slotKey string) (lease Lease, err error) {
	if err = validateLeaseIdentity(profileID, slotKey); err != nil {
		return Lease{}, err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.clock.Now()
	defer func() {
		c.recordDecisionLocked(CommandAdopt, profileID, err == nil, err, now)
	}()
	if _, err = c.sweepExpiredLocked(now); err != nil {
		return Lease{}, err
	}

	profilePolicy, known := c.state.Policy.profile(profileID)
	if !known {
		return Lease{}, ErrUnknownProfile
	}
	key := leaseKey{profileID: profileID, slotKey: slotKey}
	existing, exists := c.state.Leases[key.String()]
	if exists && existing.Status == LeaseActive {
		next := c.state.clone()
		if markLeaseAccountedForAdoption(&next, profileID, slotKey) {
			if err = c.store.Save(next); err != nil {
				return Lease{}, err
			}
			c.state = next
		}
		return existing, nil
	}

	sequence := c.state.DecisionSequence + 1
	if exists {
		existing.Status = LeaseActive
		existing.ExpiresAtUnixNano = 0
		existing.ActivatedAtSequence = sequence
		lease = existing
	} else {
		lease = Lease{
			ProfileID:           profileID,
			SlotKey:             slotKey,
			LeaseID:             fmt.Sprintf("%s#%d", key.String(), sequence),
			Units:               profilePolicy.UnitCost,
			Status:              LeaseActive,
			GrantedAtSequence:   sequence,
			ActivatedAtSequence: sequence,
		}
	}
	next := c.state.clone()
	next.DecisionSequence = sequence
	delete(next.Tombstones, key.String())
	next.Leases[key.String()] = lease
	markLeaseAccountedForAdoption(&next, profileID, slotKey)
	if err = c.store.Save(next); err != nil {
		return Lease{}, err
	}
	c.state = next
	delete(c.provisionalDeadlines, key.String())
	return lease, nil
}

// Renew extends a provisional lease's monotonic expiry while bounded
// pre-launch work continues. It fails closed with ErrLeaseExpired if the
// lease already elapsed, and ErrLeaseNotProvisional if the lease was already
// activated; only a provisional lease has an expiry to extend.
func (c *Coordinator) Renew(profileID, slotKey string) (lease Lease, err error) {
	if err = validateLeaseIdentity(profileID, slotKey); err != nil {
		return Lease{}, err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.clock.Now()
	defer func() {
		c.recordDecisionLocked(CommandRenew, profileID, err == nil, err, now)
	}()
	expired, err := c.sweepExpiredLocked(now)
	if err != nil {
		return Lease{}, err
	}
	key := leaseKey{profileID: profileID, slotKey: slotKey}.String()
	if expired[key] {
		return Lease{}, ErrLeaseExpired
	}
	existing, exists := c.state.Leases[key]
	if !exists {
		return Lease{}, ErrLeaseNotFound
	}
	if existing.Status != LeaseProvisional {
		return Lease{}, ErrLeaseNotProvisional
	}
	deadline := now.Add(c.provisionalTTL)
	existing.ExpiresAtUnixNano = deadline.UnixNano()
	next := c.state.clone()
	next.DecisionSequence++
	next.Leases[key] = existing
	if err = c.store.Save(next); err != nil {
		return Lease{}, err
	}
	c.state = next
	c.provisionalDeadlines[key] = deadline
	return existing, nil
}

// Activate promotes a provisional lease to active only if it has not
// expired. Activation of an already-active lease is idempotent, so a
// manager can safely retry after an ambiguous acknowledgement. A worker
// process must never be started before Activate succeeds.
func (c *Coordinator) Activate(profileID, slotKey string) (lease Lease, err error) {
	if err = validateLeaseIdentity(profileID, slotKey); err != nil {
		return Lease{}, err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.clock.Now()
	defer func() {
		c.recordDecisionLocked(CommandActivate, profileID, err == nil, err, now)
	}()
	expired, err := c.sweepExpiredLocked(now)
	if err != nil {
		return Lease{}, err
	}
	key := leaseKey{profileID: profileID, slotKey: slotKey}.String()
	if expired[key] {
		return Lease{}, ErrLeaseExpired
	}
	existing, exists := c.state.Leases[key]
	if !exists {
		return Lease{}, ErrLeaseNotFound
	}
	if existing.Status == LeaseActive {
		return existing, nil
	}
	sequence := c.state.DecisionSequence + 1
	existing.Status = LeaseActive
	existing.ExpiresAtUnixNano = 0
	existing.ActivatedAtSequence = sequence
	next := c.state.clone()
	next.DecisionSequence = sequence
	next.Leases[key] = existing
	if err = c.store.Save(next); err != nil {
		return Lease{}, err
	}
	c.state = next
	delete(c.provisionalDeadlines, key)
	return existing, nil
}

// Release performs an exact, durable release of one lease, whether
// provisional or active, and records a tombstone. Releasing an
// already-tombstoned slot is a safe idempotent no-op. Releasing a slot that
// never existed and was never tombstoned returns ErrLeaseNotFound.
func (c *Coordinator) Release(profileID, slotKey string) (err error) {
	if err = validateLeaseIdentity(profileID, slotKey); err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.clock.Now()
	defer func() {
		c.recordDecisionLocked(CommandRelease, profileID, err == nil, err, now)
	}()
	if _, err = c.sweepExpiredLocked(now); err != nil {
		return err
	}
	err = c.tombstoneLocked(profileID, slotKey, TombstoneReleased, "")
	return err
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
func (c *Coordinator) Reconcile(profileID, slotKey, evidence string) (err error) {
	if err = validateLeaseIdentity(profileID, slotKey); err != nil {
		return err
	}
	sanitized, err := sanitizeEvidence(evidence)
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.clock.Now()
	defer func() {
		c.recordDecisionLocked(CommandReconcile, profileID, err == nil, err, now)
	}()
	if _, err = c.sweepExpiredLocked(now); err != nil {
		return err
	}
	err = c.tombstoneLocked(profileID, slotKey, TombstoneReconciledAbsent, sanitized)
	return err
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
	markLeaseAccountedForAdoption(&next, profileID, slotKey)
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

func activeLeaseSlotKeys(leases map[string]Lease, profileID string) []string {
	keys := make([]string, 0)
	for _, lease := range leases {
		if lease.ProfileID == profileID && lease.Status == LeaseActive {
			keys = append(keys, lease.SlotKey)
		}
	}
	sort.Strings(keys)
	return keys
}

func markLeaseAccountedForAdoption(
	state *durableState,
	profileID string,
	slotKey string,
) bool {
	fence, exists := state.AdoptionFences[profileID]
	if !exists || len(fence.PendingLeaseKeys) == 0 {
		return false
	}
	index := sort.SearchStrings(fence.PendingLeaseKeys, slotKey)
	if index >= len(fence.PendingLeaseKeys) ||
		fence.PendingLeaseKeys[index] != slotKey {
		return false
	}
	fence.PendingLeaseKeys = append(
		fence.PendingLeaseKeys[:index],
		fence.PendingLeaseKeys[index+1:]...,
	)
	state.AdoptionFences[profileID] = fence
	return true
}

// Decision is a bounded, sanitized record of the single most recent lease
// admission decision (Acquire, Adopt, Renew, Activate, Release, or Reconcile). It
// carries only the validated profile identity and a closed failure-category
// vocabulary drawn from ErrorCode. Exact slot identity stays in the private
// lease ledger and is never duplicated into decision telemetry.
// ApplyPolicy, SetDemand, and Status are not lease decisions and never
// produce one.
type Decision struct {
	// Sequence is the durable decision sequence in effect when this
	// decision was made: the new sequence for a granted request, or the
	// unchanged current sequence for a denied one, so a rejection never
	// perturbs the sequence used by every other durable mutation.
	Sequence          int64     `json:"sequence"`
	Command           Command   `json:"command"`
	ProfileID         string    `json:"profileId,omitempty"`
	Granted           bool      `json:"granted"`
	FailureCategory   ErrorCode `json:"failureCategory,omitempty"`
	DecidedAtUnixNano int64     `json:"decidedAtUnixNano"`
}

// recordDecisionLocked durably records the single most recent lease
// decision. It is best-effort: a failure to persist this informational
// record is swallowed rather than surfaced as the calling operation's own
// error, since a successful Acquire/Adopt/Renew/Activate/Release/Reconcile must
// never be turned into a failure by a problem persisting only this
// supplementary bookkeeping. The caller must already hold c.mu.
func (c *Coordinator) recordDecisionLocked(
	command Command,
	profileID string,
	granted bool,
	err error,
	now time.Time,
) {
	decision := Decision{
		Sequence:          c.state.DecisionSequence,
		Command:           command,
		ProfileID:         profileID,
		Granted:           granted,
		DecidedAtUnixNano: now.UnixNano(),
	}
	if !granted && err != nil {
		decision.FailureCategory = durableDecisionErrorCode(err)
	}
	next := c.state.clone()
	next.LastDecision = &decision
	if saveErr := c.store.Save(next); saveErr != nil {
		return
	}
	c.state = next
}

func durableDecisionErrorCode(err error) ErrorCode {
	if errors.Is(err, ErrBudgetExceeded) {
		return ErrorCodeBudgetExceeded
	}
	return errorCodeForErr(err)
}

// Snapshot is a read-only, deterministically ordered view of the
// coordinator's durable state, suitable for the CLI status subcommand and
// for tests.
//
// Accounting semantics (see docs/adr/adr-0003-dedicated-host-admission-service.md
// and docs/adr/adr-0002-workload-agnostic-service-classes.md):
//   - ActiveUnits: units held by leases already promoted to LeaseActive.
//   - ProvisionalUnits: units held by leases still LeaseProvisional.
//   - HeldUnits: ActiveUnits+ProvisionalUnits, the profile's current total
//     allocation regardless of lease lifecycle stage.
//   - ReservedUnits: the profile's configured protected reservation (from
//     policy, not measured).
//   - BorrowedUnits: max(HeldUnits-ReservedUnits, 0) -- units this profile
//     currently holds beyond its own reservation, drawn from the shared
//     fair pool or another profile's borrowable headroom.
//   - PendingUnits: the profile's last known outstanding worker demand
//     converted to policy units. It is null after coordinator restart, policy
//     replacement, or demand expiry until that profile republishes demand.
//   - WithheldUnits: the same outstanding unit demand while it remains
//     ungranted. A successful Acquire consumes one worker from demand before
//     status can report it.
//   - AllocatableUnits/Workers: additional current capacity not held or
//     protected from this profile. A current denied decision reports zero.
//   - TheoreticalMaximumUnits/Workers: the static policy ceiling after other
//     profiles' non-borrowable reservations are protected.
//   - WithholdingReason: the coordinator-owned current denial category for
//     refreshed pending demand, or nil when demand is not currently denied.
//   - AvailableUnits (host-wide): EffectiveTotalUnits minus every profile's
//     HeldUnits, the leftover host budget no profile currently holds.
type Snapshot struct {
	ProtocolVersion       int                 `json:"protocolVersion,omitempty"`
	Namespace             string              `json:"namespace,omitempty"`
	Epoch                 int64               `json:"epoch"`
	DecisionSequence      int64               `json:"decisionSequence"`
	Policy                HostPolicy          `json:"policy"`
	CapacityUnits         int                 `json:"capacityUnits"`
	SafetyMarginUnits     int                 `json:"safetyMarginUnits"`
	EffectiveTotalUnits   int                 `json:"effectiveTotalUnits"`
	HostPolicyFingerprint string              `json:"hostPolicyFingerprint,omitempty"`
	AvailableUnits        int                 `json:"availableUnits"`
	Accounting            []ProfileAccounting `json:"accounting"`
	Leases                []Lease             `json:"leases"`
	Tombstones            []Tombstone         `json:"tombstones"`
	AdoptionFences        []AdoptionFence     `json:"adoptionFences,omitempty"`
	LastDecision          *Decision           `json:"lastDecision,omitempty"`
}

// ProfileAccounting is the bounded, per-profile accounting view described on
// Snapshot. It exists for exactly the profiles enumerated in the currently
// applied policy, so its size is always bounded by the policy's own
// (already-validated) profile count.
type ProfileAccounting struct {
	ProfileID                 string             `json:"profileId"`
	UnitCost                  int                `json:"unitCost"`
	ReservedUnits             int                `json:"reservedUnits"`
	Borrowable                bool               `json:"borrowable"`
	ProfilePolicyFingerprint  string             `json:"profilePolicyFingerprint,omitempty"`
	ActiveUnits               int                `json:"activeUnits"`
	ProvisionalUnits          int                `json:"provisionalUnits"`
	HeldUnits                 int                `json:"heldUnits"`
	BorrowedUnits             int                `json:"borrowedUnits"`
	PendingUnits              *int               `json:"pendingUnits"`
	WithheldUnits             *int               `json:"withheldUnits"`
	AllocatableUnits          *int               `json:"allocatableUnits"`
	AllocatableWorkers        *int               `json:"allocatableWorkers"`
	TheoreticalMaximumUnits   *int               `json:"theoreticalMaximumUnits"`
	TheoreticalMaximumWorkers *int               `json:"theoreticalMaximumWorkers"`
	WithholdingReason         *WithholdingReason `json:"withholdingReason"`
}

// Status returns a deterministic snapshot of the current durable state.
func (c *Coordinator) Status() (Snapshot, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.clock.Now()
	if _, err := c.sweepExpiredLocked(now); err != nil {
		return Snapshot{}, err
	}
	c.expireStaleDemandLocked(now)
	policy := clonePolicy(c.state.Policy)
	snapshot := Snapshot{
		Namespace:             policy.Namespace,
		Epoch:                 c.state.Epoch,
		DecisionSequence:      c.state.DecisionSequence,
		Policy:                policy,
		CapacityUnits:         policy.CapacityUnits,
		SafetyMarginUnits:     policy.SafetyMarginUnits,
		EffectiveTotalUnits:   policy.EffectiveTotalUnits(),
		HostPolicyFingerprint: policy.HostPolicyFingerprint,
	}
	for _, key := range sortedStateKeys(c.state.Leases) {
		snapshot.Leases = append(snapshot.Leases, c.state.Leases[key])
	}
	for _, key := range sortedStateKeys(c.state.Tombstones) {
		snapshot.Tombstones = append(snapshot.Tombstones, c.state.Tombstones[key])
	}
	for _, key := range sortedStateKeys(c.state.AdoptionFences) {
		fence := c.state.AdoptionFences[key]
		// Protocol 4 distinguishes an accounted empty list from legacy null.
		fence.PendingLeaseKeys = append(
			make([]string, 0, len(fence.PendingLeaseKeys)),
			fence.PendingLeaseKeys...,
		)
		snapshot.AdoptionFences = append(snapshot.AdoptionFences, fence)
	}
	if c.state.LastDecision != nil {
		decision := *c.state.LastDecision
		snapshot.LastDecision = &decision
	}

	activeHeld := make(map[string]int, len(policy.Profiles))
	provisionalHeld := make(map[string]int, len(policy.Profiles))
	heldByProfile := make(map[string]int, len(policy.Profiles))
	for _, lease := range c.state.Leases {
		heldByProfile[lease.ProfileID] += lease.Units
		switch lease.Status {
		case LeaseActive:
			activeHeld[lease.ProfileID] += lease.Units
		case LeaseProvisional:
			provisionalHeld[lease.ProfileID] += lease.Units
		}
	}
	totalHeld := 0
	for _, profileID := range policy.sortedProfileIDs() {
		profilePolicy, _ := policy.profile(profileID)
		active := activeHeld[profileID]
		provisional := provisionalHeld[profileID]
		held := active + provisional
		totalHeld += held
		capacity := c.profileCapacityLocked(profileID, heldByProfile)
		allocatableUnits := capacity.allocatableUnits
		allocatableWorkers := capacity.allocatableWorkers
		theoreticalMaximumUnits := capacity.theoreticalMaximumUnits
		theoreticalMaximumWorkers := capacity.theoreticalMaximumWorkers
		accounting := ProfileAccounting{
			ProfileID:                 profileID,
			UnitCost:                  profilePolicy.UnitCost,
			ReservedUnits:             profilePolicy.ReservedUnits,
			Borrowable:                profilePolicy.Borrowable,
			ProfilePolicyFingerprint:  profilePolicy.ProfilePolicyFingerprint,
			ActiveUnits:               active,
			ProvisionalUnits:          provisional,
			HeldUnits:                 held,
			BorrowedUnits:             max(held-profilePolicy.ReservedUnits, 0),
			AllocatableUnits:          &allocatableUnits,
			AllocatableWorkers:        &allocatableWorkers,
			TheoreticalMaximumUnits:   &theoreticalMaximumUnits,
			TheoreticalMaximumWorkers: &theoreticalMaximumWorkers,
			WithholdingReason:         capacity.withholdingReason,
		}
		if c.demandKnown[profileID] {
			pendingUnits := c.demand[profileID] * profilePolicy.UnitCost
			withheldUnits := pendingUnits
			accounting.PendingUnits = &pendingUnits
			accounting.WithheldUnits = &withheldUnits
		}
		snapshot.Accounting = append(snapshot.Accounting, accounting)
	}
	snapshot.AvailableUnits = max(snapshot.EffectiveTotalUnits-totalHeld, 0)
	return snapshot, nil
}

type profileCapacity struct {
	allocatableUnits          int
	allocatableWorkers        int
	theoreticalMaximumUnits   int
	theoreticalMaximumWorkers int
	withholdingReason         *WithholdingReason
}

func (c *Coordinator) profileCapacityLocked(
	profileID string,
	held map[string]int,
) profileCapacity {
	profilePolicy, known := c.state.Policy.profile(profileID)
	if !known {
		return profileCapacity{}
	}

	protectedMaximum := 0
	totalHeld := 0
	for _, profile := range c.state.Policy.Profiles {
		totalHeld += held[profile.ProfileID]
		if profile.ProfileID != profileID && !profile.Borrowable {
			protectedMaximum += profile.ReservedUnits
		}
	}
	theoreticalUnits := max(c.state.Policy.TotalUnits-protectedMaximum, 0)
	currentProtected := c.protectedNonBorrowableLocked(profileID, held)
	currentFree := max(c.state.Policy.TotalUnits-totalHeld, 0)
	allocatableUnits := max(currentFree-currentProtected, 0)
	allocatableUnits = min(
		allocatableUnits,
		max(theoreticalUnits-held[profileID], 0),
	)

	var withholdingReason *WithholdingReason
	if len(c.state.AdoptionFences) > 0 {
		allocatableUnits = 0
	}
	if c.demandKnown[profileID] && c.demand[profileID] > 0 {
		if len(c.state.AdoptionFences) == 0 {
			ownRemaining := min(
				max(profilePolicy.ReservedUnits-held[profileID], 0),
				currentFree,
			)
			fairAllocatable, _ := c.fairAllocatableUnitsLocked(
				profileID,
				held,
				max(currentFree-currentProtected, 0),
			)
			allocatableUnits = min(
				max(ownRemaining, fairAllocatable),
				max(theoreticalUnits-held[profileID], 0),
			)
		}
		var reason WithholdingReason
		var withheld bool
		if len(c.state.AdoptionFences) > 0 {
			reason = WithholdingAdoptionPending
			withheld = true
		} else if _, err := c.evaluateAcquireLocked(
			profileID,
			profilePolicy,
			held,
		); err != nil {
			reason, withheld = withholdingReasonForError(err)
		}
		if withheld {
			withholdingReason = &reason
			allocatableUnits = 0
		}
	}

	return profileCapacity{
		allocatableUnits:          allocatableUnits,
		allocatableWorkers:        allocatableUnits / profilePolicy.UnitCost,
		theoreticalMaximumUnits:   theoreticalUnits,
		theoreticalMaximumWorkers: theoreticalUnits / profilePolicy.UnitCost,
		withholdingReason:         withholdingReason,
	}
}

func withholdingReasonForError(err error) (WithholdingReason, bool) {
	switch {
	case errors.Is(err, ErrBudgetExhausted):
		return WithholdingBudgetExhausted, true
	case errors.Is(err, ErrProtectedReservation):
		return WithholdingProtectedReservation, true
	case errors.Is(err, ErrFairShareContention):
		return WithholdingFairShareContention, true
	case errors.Is(err, ErrAdoptionPending):
		return WithholdingAdoptionPending, true
	default:
		return "", false
	}
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
	expiredProfiles := make(map[string]bool)
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
		expiredProfiles[lease.ProfileID] = true
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
	for profileID := range expiredProfiles {
		delete(c.demand, profileID)
		delete(c.demandKnown, profileID)
		delete(c.demandDeadlines, profileID)
	}
	for key := range expired {
		delete(c.provisionalDeadlines, key)
	}
	return expired, nil
}

func (c *Coordinator) expireStaleDemandLocked(now time.Time) {
	for profileID, deadline := range c.demandDeadlines {
		if now.Before(deadline) {
			continue
		}
		delete(c.demand, profileID)
		delete(c.demandKnown, profileID)
		delete(c.demandDeadlines, profileID)
	}
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
// every other demanding profile's own guarantee is protected.
//
// fairTurnLocked itself never advances the rotation cursor: it only decides
// whether this request wins the round. The returned contenderCount is the
// value the caller must pass to advanceRotationLocked, and the caller must
// do so only after the resulting grant has been durably saved, so a save
// failure can never move fairness priority for a request that was not
// actually admitted. A contenderCount of zero means no contenders were
// registered and there is no rotation cursor to advance.
func (c *Coordinator) fairTurnLocked(
	profileID string,
	held map[string]int,
	available int,
	unitCost int,
) (granted bool, contenderCount int) {
	allocatable, contenderCount := c.fairAllocatableUnitsLocked(
		profileID,
		held,
		available,
	)
	return allocatable >= unitCost, contenderCount
}

func (c *Coordinator) fairAllocatableUnitsLocked(
	profileID string,
	held map[string]int,
	available int,
) (allocatable int, contenderCount int) {
	contenders := c.contendersLocked()
	count := len(contenders)
	if count == 0 {
		return max(available, 0), 0
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
	return max(available-protected, 0), count
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
