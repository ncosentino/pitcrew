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

// validateNamespace rejects a host-admission namespace that does not match
// the same public identity syntax as a profile identity (see
// RunnerProfiles.Functions.ps1's `^[a-z][a-z0-9-]{0,31}$` namespace
// pattern), so Setup and this package always agree on one shape. An empty
// namespace is valid here: it means the policy predates namespace
// reporting (contract <=17) and this package assigns it no meaning beyond
// "unset".
func validateNamespace(namespace string) error {
	if namespace == "" {
		return nil
	}
	if !profileIDPattern.MatchString(namespace) {
		return fmt.Errorf(
			"%w: namespace %q must match %s",
			ErrInvalidIdentity,
			namespace,
			profileIDPattern.String(),
		)
	}
	return nil
}

// maxFingerprintBytes bounds a policy fingerprint to a short, opaque,
// single-line token (for example a hex-encoded digest), never a
// free-form or unbounded string.
const maxFingerprintBytes = 128

// fingerprintPattern accepts only the bounded, opaque alphanumeric-plus-dash
// tokens Setup's SHA-256-based fingerprints produce. It intentionally
// excludes whitespace, "/", and control characters, so a fingerprint can
// never carry a path, URL, or embedded credential.
var fingerprintPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

// validateFingerprint rejects a HostPolicyFingerprint or
// ProfilePolicyFingerprint that is not a short, opaque, bounded token. An
// empty fingerprint is valid: it means the publishing side predates
// fingerprint reporting.
func validateFingerprint(name, fingerprint string) error {
	if fingerprint == "" {
		return nil
	}
	if len(fingerprint) > maxFingerprintBytes || !fingerprintPattern.MatchString(fingerprint) {
		return fmt.Errorf(
			"%w: %s must be a bounded opaque token matching %s",
			ErrInvalidPolicy,
			name,
			fingerprintPattern.String(),
		)
	}
	return nil
}
