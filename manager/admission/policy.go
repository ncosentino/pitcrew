// Package admission implements the generic, host-local admission coordinator
// core described by docs/adr/adr-0003-dedicated-host-admission-service.md. It
// owns atomic allocation of an abstract per-host unit budget across
// participating profiles, including reservations, borrowing, fairness,
// provisional lease expiry, durable active leases, and fail-closed recovery
// from corrupt or unsupported durable state.
//
// The package intentionally has no knowledge of Docker, GitHub, or any
// host-specific resource (CPU, memory, disk). All quantities are abstract
// positive integer units supplied by policy configured elsewhere. Wiring this
// core into the manager Compose topology, Setup-Runner.ps1, and the
// autoscaler/shell managers is out of scope for this package.
package admission

import (
	"errors"
	"fmt"
	"sort"
)

// ErrInvalidPolicy reports a structurally invalid host policy.
var ErrInvalidPolicy = errors.New("admission: invalid host policy")

// ErrStalePolicy reports a policy generation that is not newer than the
// generation currently applied to the coordinator.
var ErrStalePolicy = errors.New("admission: stale policy generation")

// ProfilePolicy carries one participating profile's admission configuration.
// UnitCost, ReservedUnits, and every budget quantity are abstract positive
// integers; this package assigns them no physical meaning.
type ProfilePolicy struct {
	// ProfileID is the stable profile identity supplied by the participating
	// manager. It is opaque to this package.
	ProfileID string `json:"profileId"`
	// UnitCost is the number of abstract units one lease for this profile
	// consumes. Every Acquire call for this profile allocates exactly this
	// many units; partial allocations are never granted.
	UnitCost int `json:"unitCost"`
	// ReservedUnits is the number of units protected for this profile. Zero
	// means the profile has no reservation and competes only for the shared
	// fair pool.
	ReservedUnits int `json:"reservedUnits"`
	// Borrowable marks whether unused reserved units may be borrowed by other
	// profiles through the fair shared pool. A non-borrowable reservation
	// remains protected headroom even while unused.
	Borrowable bool `json:"borrowable"`
}

func (p ProfilePolicy) validate() error {
	if p.ProfileID == "" {
		return fmt.Errorf("%w: profile identity cannot be empty", ErrInvalidPolicy)
	}
	if p.UnitCost < 1 {
		return fmt.Errorf(
			"%w: profile %q unit cost must be a positive integer",
			ErrInvalidPolicy,
			p.ProfileID,
		)
	}
	if p.ReservedUnits < 0 {
		return fmt.Errorf(
			"%w: profile %q reserved units cannot be negative",
			ErrInvalidPolicy,
			p.ProfileID,
		)
	}
	return nil
}

// HostPolicy is the versioned desired admission policy for one Docker
// daemon's admission namespace. Setup wiring outside this package is
// responsible for producing and delivering HostPolicy values; this package
// only validates, applies, and persists them.
type HostPolicy struct {
	// Generation is a monotonically increasing policy version. ApplyPolicy
	// rejects a generation that is not strictly greater than the currently
	// applied generation, so a replayed or reordered policy publication can
	// never roll admission back to older, less-informed state.
	Generation int `json:"generation"`
	// TotalUnits is the abstract host-wide budget shared by every
	// participating profile.
	TotalUnits int `json:"totalUnits"`
	// Profiles enumerates every participating profile's cost and
	// reservation policy. Profile identities must be unique.
	Profiles []ProfilePolicy `json:"profiles"`
}

func (h HostPolicy) validate() error {
	if h.Generation < 1 {
		return fmt.Errorf("%w: generation must be a positive integer", ErrInvalidPolicy)
	}
	if h.TotalUnits < 0 {
		return fmt.Errorf("%w: total units cannot be negative", ErrInvalidPolicy)
	}
	seen := make(map[string]struct{}, len(h.Profiles))
	reserved := 0
	for _, profile := range h.Profiles {
		if err := profile.validate(); err != nil {
			return err
		}
		if _, exists := seen[profile.ProfileID]; exists {
			return fmt.Errorf(
				"%w: duplicate profile identity %q",
				ErrInvalidPolicy,
				profile.ProfileID,
			)
		}
		seen[profile.ProfileID] = struct{}{}
		reserved += profile.ReservedUnits
	}
	if reserved > h.TotalUnits {
		return fmt.Errorf(
			"%w: reserved units %d exceed total units %d",
			ErrInvalidPolicy,
			reserved,
			h.TotalUnits,
		)
	}
	return nil
}

// profile looks up one profile's policy by identity.
func (h HostPolicy) profile(profileID string) (ProfilePolicy, bool) {
	for _, profile := range h.Profiles {
		if profile.ProfileID == profileID {
			return profile, true
		}
	}
	return ProfilePolicy{}, false
}

// sortedProfileIDs returns every configured profile identity in a stable,
// deterministic order so fairness rotation never depends on map iteration
// order.
func (h HostPolicy) sortedProfileIDs() []string {
	ids := make([]string, 0, len(h.Profiles))
	for _, profile := range h.Profiles {
		ids = append(ids, profile.ProfileID)
	}
	sort.Strings(ids)
	return ids
}

func clonePolicy(policy HostPolicy) HostPolicy {
	cloned := HostPolicy{
		Generation: policy.Generation,
		TotalUnits: policy.TotalUnits,
		Profiles:   make([]ProfilePolicy, len(policy.Profiles)),
	}
	copy(cloned.Profiles, policy.Profiles)
	return cloned
}
