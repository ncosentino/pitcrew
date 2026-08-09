package main

import (
	"errors"
	"sync"

	"github.com/ncosentino/pitcrew/manager/admission"
)

// hostAdmissionLeaseClient is the subset of admission.Client this package
// depends on, so tests can substitute a fake instead of a real Unix socket
// (see ADR-0003 for the wire protocol this wraps).
type hostAdmissionLeaseClient interface {
	SetDemand(profileID string, pending int) error
	Acquire(profileID, slotKey string, pendingDemand int) (admission.Lease, error)
	Renew(profileID, slotKey string) (admission.Lease, error)
	Activate(profileID, slotKey string) (admission.Lease, error)
	Release(profileID, slotKey string) error
	Reconcile(profileID, slotKey, evidence string) error
	Status() (admission.Snapshot, error)
}

var _ hostAdmissionLeaseClient = (*admission.Client)(nil)

// hostAdmissionOutcome distinguishes why an acquire attempt did not admit a
// launch. It is process-internal only: the observed-state contract's closed
// deficit/reason vocabulary stays at manager contract 17 for this feature
// (see diagnostics.go, capacity_evidence.go), so every published deficit and
// reason still uses the existing deficitAdmissionCeiling/
// reasonCapacityCeiling constants regardless of which of these applies.
type hostAdmissionOutcome int

const (
	hostAdmissionGranted hostAdmissionOutcome = iota
	hostAdmissionBudgetDenied
	hostAdmissionOutage
)

// hostAdmissionCoordinator gates JIT/launch admission on a host-local budget
// shared across every profile on the host (ADR-0003), layered on top of the
// existing in-process admissionController's profile-wide fairness ceiling.
// A disabled coordinator (client is nil) makes every method here an exact
// no-op that always grants, preserving current behavior precisely when
// PITCREW_HOST_ADMISSION_* is unset.
type hostAdmissionCoordinator struct {
	client    hostAdmissionLeaseClient
	profileID string

	// namespace, hostFingerprint, and profileFingerprint are this
	// manager's own configured identity (see hostAdmissionConfig),
	// reported and compared against the coordinator's actual policy
	// independently of whether the coordinator is currently reachable, so
	// an outage never has to guess this manager's own configuration.
	namespace          string
	hostFingerprint    string
	profileFingerprint string

	mu     sync.Mutex
	demand map[string]int
}

// newHostAdmissionCoordinator builds the coordinator this profile's
// autoscaler manager uses for the lifetime of the process. Disabled
// configuration returns a coordinator with a nil client rather than a nil
// coordinator, so every call site can invoke methods on it unconditionally.
func newHostAdmissionCoordinator(
	cfg hostAdmissionConfig,
	profileID string,
) *hostAdmissionCoordinator {
	if !cfg.enabled {
		return &hostAdmissionCoordinator{}
	}
	coordinator := newHostAdmissionCoordinatorWithClient(
		admission.NewClient(cfg.socketPath),
		profileID,
	)
	coordinator.namespace = cfg.namespace
	coordinator.hostFingerprint = cfg.hostFingerprint
	coordinator.profileFingerprint = cfg.profileFingerprint
	return coordinator
}

// newHostAdmissionCoordinatorWithClient builds a coordinator around an
// arbitrary client, so tests can exercise the enabled path with a fake
// implementation of hostAdmissionLeaseClient instead of a real socket.
func newHostAdmissionCoordinatorWithClient(
	client hostAdmissionLeaseClient,
	profileID string,
) *hostAdmissionCoordinator {
	return &hostAdmissionCoordinator{
		client:    client,
		profileID: profileID,
		demand:    make(map[string]int),
	}
}

func (h *hostAdmissionCoordinator) enabled() bool {
	return h != nil && h.client != nil
}

// setTargetDemand records one target's current pending demand and publishes
// the profile-wide aggregate to the host coordinator, so cross-profile
// fairness at the host level can partition ahead of any single target's own
// Acquire call. Publication failure never blocks the caller: SetDemand is
// advisory partitioning input, not an admission decision, so an outage here
// must never itself alter GitHub demand, existing workers, or
// registrations.
func (h *hostAdmissionCoordinator) setTargetDemand(targetKey string, pending int) {
	if !h.enabled() {
		return
	}
	h.mu.Lock()
	if pending > 0 {
		h.demand[targetKey] = pending
	} else {
		delete(h.demand, targetKey)
	}
	total := 0
	for _, count := range h.demand {
		total += count
	}
	h.mu.Unlock()
	_ = h.client.SetDemand(h.profileID, total)
}

// currentDemand reports the last aggregate pending demand this coordinator
// published, for use as the pendingDemand argument to acquire.
func (h *hostAdmissionCoordinator) currentDemand() int {
	if !h.enabled() {
		return 0
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	total := 0
	for _, count := range h.demand {
		total += count
	}
	return total
}

// acquire requests one provisional lease for slotKey before any GitHub JIT
// call is made, so a worker container is never created for a job the host
// budget has not admitted. A duplicate acquire against a lease this process
// already holds is treated as granted, matching the wire client's retry
// contract. The returned outcome distinguishes a budget deny from a
// coordinator/socket outage, so callers can react differently without the
// distinction ever reaching the public observed-state contract.
func (h *hostAdmissionCoordinator) acquire(
	slotKey string,
	pendingDemand int,
) (admission.Lease, hostAdmissionOutcome, error) {
	if !h.enabled() {
		return admission.Lease{}, hostAdmissionGranted, nil
	}
	lease, err := h.client.Acquire(h.profileID, slotKey, pendingDemand)
	if err == nil {
		return lease, hostAdmissionGranted, nil
	}
	if errors.Is(err, admission.ErrDuplicateLease) {
		return lease, hostAdmissionGranted, nil
	}
	if errors.Is(err, admission.ErrBudgetExceeded) {
		return admission.Lease{}, hostAdmissionBudgetDenied, err
	}
	return admission.Lease{}, hostAdmissionOutage, err
}

// renew extends a provisional lease during bounded pre-launch work (JIT
// generation, container create). A renewal failure is treated the same as
// an acquire failure by the caller: the launch attempt is abandoned and the
// lease is released exactly, never left dangling.
func (h *hostAdmissionCoordinator) renew(slotKey string) error {
	if !h.enabled() {
		return nil
	}
	_, err := h.client.Renew(h.profileID, slotKey)
	return err
}

// activate promotes a provisional lease to active, or confirms an
// already-active lease unchanged. It is idempotent, so a manager can safely
// retry after an ambiguous failure without double-activating, and can use
// it to re-confirm a lease recovered across a restart.
func (h *hostAdmissionCoordinator) activate(slotKey string) (admission.Lease, error) {
	if !h.enabled() {
		return admission.Lease{}, nil
	}
	return h.client.Activate(h.profileID, slotKey)
}

// release performs an exact release of one lease, whether provisional or
// active. Callers must guarantee this runs at most once per acquired slot
// key; see runnerRecord.hostLeaseReleased and markHostLeaseReleaseLocked. A
// lease already gone (released, expired, or never known to this
// coordinator instance) is a safe no-op rather than an error, so a
// best-effort cleanup call never needs its own special-cased error
// handling.
func (h *hostAdmissionCoordinator) release(slotKey string) error {
	if !h.enabled() || slotKey == "" {
		return nil
	}
	err := h.client.Release(h.profileID, slotKey)
	if errors.Is(err, admission.ErrLeaseNotFound) {
		return nil
	}
	return err
}

// Closed hostAdmission.status vocabulary for the observed-state contract
// (see observed-state.schema.json). Only "available" and "degraded" ever
// carry measured values; "disabled" and "unavailable" never do.
const (
	hostAdmissionStatusDisabled    = "disabled"
	hostAdmissionStatusAvailable   = "available"
	hostAdmissionStatusDegraded    = "degraded"
	hostAdmissionStatusUnavailable = "unavailable"
)

// sampleObservedHostAdmission builds this profile's scoped hostAdmission
// telemetry object for observed-state. It never blocks lifecycle: a
// Status() failure is captured as status "unavailable", never propagated as
// an error, matching the diagnostics-only isolation every other
// observed-state subsystem already uses (see manager.go's
// tryPublishObserved / applyDiagnostics).
//
// Scope: this reports only namespace/host-wide budget totals plus this
// profile's own accounting entry. It intentionally never republishes any
// other profile's identity, accounting, or lease/decision detail, even
// though the coordinator's Status() carries that full ledger -- this
// manager's own public observed-state contract stays scoped to itself,
// never leaking a sibling profile's identity through this profile's own
// published state.
func (h *hostAdmissionCoordinator) sampleObservedHostAdmission() observedHostAdmission {
	if !h.enabled() {
		return observedHostAdmission{Status: hostAdmissionStatusDisabled}
	}
	namespace := nonEmptyString(h.namespace)
	snapshot, err := h.client.Status()
	if err != nil {
		return observedHostAdmission{
			Status:    hostAdmissionStatusUnavailable,
			Namespace: namespace,
		}
	}

	profile, known := findProfileAccounting(snapshot.Accounting, h.profileID)
	degraded := !known
	if h.hostFingerprint != "" && snapshot.HostPolicyFingerprint != "" &&
		h.hostFingerprint != snapshot.HostPolicyFingerprint {
		degraded = true
	}
	if known && h.profileFingerprint != "" && profile.ProfilePolicyFingerprint != "" &&
		h.profileFingerprint != profile.ProfilePolicyFingerprint {
		degraded = true
	}
	status := hostAdmissionStatusAvailable
	if degraded {
		status = hostAdmissionStatusDegraded
	}

	epoch := snapshot.Epoch
	decisionSequence := snapshot.DecisionSequence
	effectiveTotalUnits := snapshot.EffectiveTotalUnits
	availableUnits := snapshot.AvailableUnits
	observed := observedHostAdmission{
		Status:                status,
		Namespace:             namespace,
		Epoch:                 &epoch,
		DecisionSequence:      &decisionSequence,
		EffectiveTotalUnits:   &effectiveTotalUnits,
		AvailableUnits:        &availableUnits,
		HostPolicyFingerprint: nonEmptyString(snapshot.HostPolicyFingerprint),
	}
	if snapshot.CapacityUnits > 0 {
		capacityUnits := snapshot.CapacityUnits
		safetyMarginUnits := snapshot.SafetyMarginUnits
		observed.CapacityUnits = &capacityUnits
		observed.SafetyMarginUnits = &safetyMarginUnits
	}
	if known {
		observed.Accounting = &observedHostAdmissionAccounting{
			UnitCost:                 profile.UnitCost,
			ReservedUnits:            profile.ReservedUnits,
			Borrowable:               profile.Borrowable,
			ProfilePolicyFingerprint: nonEmptyString(profile.ProfilePolicyFingerprint),
			ActiveUnits:              profile.ActiveUnits,
			ProvisionalUnits:         profile.ProvisionalUnits,
			HeldUnits:                profile.HeldUnits,
			BorrowedUnits:            profile.BorrowedUnits,
			PendingUnits:             profile.PendingUnits,
			WithheldUnits:            profile.WithheldUnits,
		}
	}
	if decision := snapshot.LastDecision; decision != nil && decision.ProfileID == h.profileID {
		observed.LastDecision = &observedHostAdmissionDecision{
			Sequence:          decision.Sequence,
			Command:           string(decision.Command),
			Granted:           decision.Granted,
			FailureCategory:   nonEmptyString(string(decision.FailureCategory)),
			DecidedAtUnixNano: decision.DecidedAtUnixNano,
		}
	}
	return observed
}

// findProfileAccounting looks up one profile's accounting entry by
// identity in a Status() snapshot's bounded, policy-sized accounting list.
func findProfileAccounting(
	accounting []admission.ProfileAccounting,
	profileID string,
) (admission.ProfileAccounting, bool) {
	for _, entry := range accounting {
		if entry.ProfileID == profileID {
			return entry, true
		}
	}
	return admission.ProfileAccounting{}, false
}

// nonEmptyString reports an optional string as null rather than an empty
// string, so an unset or not-yet-reported value is never confused with a
// deliberately empty one.
func nonEmptyString(value string) *string {
	if value == "" {
		return nil
	}
	return &value
}
