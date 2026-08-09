package admission

import (
	"fmt"
	"regexp"
)

// profileIDPattern is the public profile identity contract: a lowercase,
// DNS-label-like token of 1-32 characters starting with a letter. This
// matches the identity syntax the runner-profile schema already requires
// for a profile name, so a policy's ProfileID can be supplied directly from
// a profile manifest without translation.
var profileIDPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)

// slotKeyPattern bounds SlotKey to a short, opaque, Docker-safe token of up
// to 128 characters starting with an alphanumeric character. Neither this
// pattern nor profileIDPattern permits "/", the separator leaseKey.String()
// uses to join ProfileID and SlotKey into one durable map key; excluding it
// from both is what makes that join collision-free, since no valid
// ProfileID can ever supply the separator itself and no valid SlotKey can
// ever be mistaken for a second path segment.
var slotKeyPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`)

// validateProfileID rejects a ProfileID that does not match the public
// profile identity contract: empty, oversized, or containing any character
// outside the pattern (including "/", uppercase letters, or a non-letter
// first character).
func validateProfileID(profileID string) error {
	if !profileIDPattern.MatchString(profileID) {
		return fmt.Errorf(
			"%w: profile identity %q must match %s",
			ErrInvalidIdentity,
			profileID,
			profileIDPattern.String(),
		)
	}
	return nil
}

// validateSlotKey rejects a SlotKey that does not match the bounded opaque
// identity contract: empty, oversized, or containing any character outside
// the pattern (including "/", control characters, or whitespace).
func validateSlotKey(slotKey string) error {
	if !slotKeyPattern.MatchString(slotKey) {
		return fmt.Errorf(
			"%w: slot key %q must match %s",
			ErrInvalidIdentity,
			slotKey,
			slotKeyPattern.String(),
		)
	}
	return nil
}

// validateLeaseIdentity validates both halves of a lease identity together,
// before either is joined into a leaseKey. Every exported slot operation
// (Acquire, Renew, Activate, Release, Reconcile) calls this first, so an
// invalid identity is rejected before it can ever reach map-key formation,
// policy lookup, or durable state.
func validateLeaseIdentity(profileID, slotKey string) error {
	if err := validateProfileID(profileID); err != nil {
		return err
	}
	if err := validateSlotKey(slotKey); err != nil {
		return err
	}
	return nil
}
