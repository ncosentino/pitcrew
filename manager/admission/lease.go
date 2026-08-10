package admission

import (
	"errors"
	"fmt"
)

// ErrUnknownProfile reports a request for a profile not present in the
// currently applied policy.
var ErrUnknownProfile = errors.New("admission: unknown profile")

// ErrDuplicateLease reports an Acquire call for a profile/slot pair that
// already holds a live (active or unexpired provisional) lease. The caller
// receives the existing lease alongside this error so a safe retry never
// double-counts budget.
var ErrDuplicateLease = errors.New("admission: duplicate profile/slot lease")

// ErrLeaseNotFound reports an operation against a profile/slot pair with no
// live lease and no recorded release tombstone.
var ErrLeaseNotFound = errors.New("admission: lease not found")

// ErrLeaseExpired reports a Renew or Activate call against a provisional
// lease whose monotonic expiry has already elapsed. The service always fails
// the operation closed; it never silently revives an expired lease.
var ErrLeaseExpired = errors.New("admission: provisional lease expired")

// ErrLeaseNotProvisional reports an Activate or Renew call against a lease
// that is already active. Activate is idempotent for an already-active lease
// so a manager can safely retry after an ambiguous failure; Renew is not,
// since only a provisional lease has an expiry to extend.
var ErrLeaseNotProvisional = errors.New("admission: lease is not provisional")

// ErrBudgetExceeded reports that no unit budget is currently available to
// satisfy an Acquire request, whether due to the host-wide budget, another
// profile's protected reservation, or losing this round of fair rotation.
var ErrBudgetExceeded = errors.New("admission: unit budget exceeded")

// ErrAdoptionPending reports that one or more profile managers have not yet
// completed existing-worker adoption. Ordinary acquisition remains blocked
// host-wide until every durable adoption fence is cleared.
var ErrAdoptionPending = errors.New("admission: existing-worker adoption pending")

// ErrEvidenceRequired reports a Reconcile call without exact retained
// evidence that the previous worker and registration are absent. Fenced
// recovery never releases an active lease on ambiguous or missing evidence.
var ErrEvidenceRequired = errors.New("admission: reconciliation evidence required")

// ErrEvidenceInvalid reports Reconcile evidence that fails the strict
// sanitized format this package requires: no more than maxEvidenceBytes
// UTF-8 bytes after trimming surrounding whitespace, and no control
// characters or newlines. Evidence is a durable, operator-visible audit
// trail, not free-form text.
var ErrEvidenceInvalid = errors.New("admission: reconciliation evidence is invalid")

// ErrInvalidIdentity reports a ProfileID or SlotKey that does not match this
// package's identity syntax. Both are validated before they are ever joined
// into a leaseKey, so a syntactically invalid identity can never be
// confused with, or collide against, a different valid identity (see
// identity.go).
var ErrInvalidIdentity = errors.New("admission: invalid profile or slot identity")

// LeaseStatus is the lifecycle state of one granted lease.
type LeaseStatus string

const (
	// LeaseProvisional leases carry a monotonic service-owned expiry and may
	// be renewed or activated before it elapses. A worker process must never
	// start against a provisional lease.
	LeaseProvisional LeaseStatus = "provisional"
	// LeaseActive leases are durable and are never reclaimed solely because
	// a manager heartbeat stops. They are released only by exact release,
	// fenced reconciliation, or a profile-removal fence.
	LeaseActive LeaseStatus = "active"
)

// Lease is one exact allocation of abstract units for one profile and slot.
type Lease struct {
	ProfileID string      `json:"profileId"`
	SlotKey   string      `json:"slotKey"`
	LeaseID   string      `json:"leaseId"`
	Units     int         `json:"units"`
	Status    LeaseStatus `json:"status"`
	// ExpiresAtUnixNano is a bounded, serialized snapshot of the provisional
	// expiry last computed by the coordinator process that granted or
	// renewed this lease, for protocol and status reporting only. It is
	// zero for an active lease, which never expires from time alone. The
	// coordinator never compares against this durable value to decide
	// whether a provisional lease has expired; that decision always uses
	// the in-process Coordinator.provisionalDeadlines entry for the
	// lease, which is the only monotonic deadline this package trusts
	// within one running process (see ADR-0003, service-owned monotonic
	// expiry). A restored provisional lease's deadline cannot be trusted
	// across a restart and is discarded before the coordinator serves any
	// request; see Coordinator.Open.
	ExpiresAtUnixNano int64 `json:"expiresAtUnixNano,omitempty"`
	// GrantedAtSequence and ActivatedAtSequence record the durable decision
	// sequence at which this lease reached its current milestones.
	GrantedAtSequence   int64 `json:"grantedAtSequence"`
	ActivatedAtSequence int64 `json:"activatedAtSequence,omitempty"`
}

func (l Lease) key() leaseKey {
	return leaseKey{profileID: l.ProfileID, slotKey: l.SlotKey}
}

type leaseKey struct {
	profileID string
	slotKey   string
}

func (k leaseKey) String() string {
	return fmt.Sprintf("%s/%s", k.profileID, k.slotKey)
}

// TombstoneReason records why a lease was permanently released.
type TombstoneReason string

const (
	// TombstoneReleased marks an exact, owner-initiated release.
	TombstoneReleased TombstoneReason = "released"
	// TombstoneExpired marks a provisional lease the service swept after its
	// monotonic expiry elapsed with no renewal or activation.
	TombstoneExpired TombstoneReason = "expired"
	// TombstoneReconciledAbsent marks a fenced recovery release: a
	// replacement manager proved, with retained evidence, that the previous
	// worker and registration are absent.
	TombstoneReconciledAbsent TombstoneReason = "reconciled-absent"
	// TombstoneRestartDiscarded marks a provisional lease this coordinator
	// build found still on disk when it opened durable state. A
	// provisional lease's monotonic expiry is tracked only in the process
	// memory of the coordinator instance that granted or last renewed it;
	// a restored provisional has no trustworthy in-process deadline, so
	// ADR-0003's service-owned monotonic expiry requirement means it is
	// never carried forward across a restart. Only active leases, which
	// never expire from time alone, survive a restart.
	TombstoneRestartDiscarded TombstoneReason = "restart-discarded"
)

// Tombstone is a durable record of a permanently released lease. Tombstones
// make release exact and idempotent: a repeated release or reconcile call
// against an already-tombstoned slot is a safe no-op rather than a fresh
// state mutation.
type Tombstone struct {
	ProfileID string          `json:"profileId"`
	SlotKey   string          `json:"slotKey"`
	LeaseID   string          `json:"leaseId"`
	Reason    TombstoneReason `json:"reason"`
	Evidence  string          `json:"evidence,omitempty"`
	Sequence  int64           `json:"sequence"`
}

// AdoptionFence records one policy participant whose replacement manager has
// not yet completed its recovered-running-worker adoption pass.
type AdoptionFence struct {
	ProfileID string `json:"profileId"`
}
