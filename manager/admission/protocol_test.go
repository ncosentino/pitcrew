package admission

import (
	"errors"
	"fmt"
	"testing"
)

// TestErrorCodeRoundTripsForKnownSentinels proves every sentinel error this
// package maps to a wire ErrorCode round-trips back to an error satisfying
// errors.Is against the original sentinel, including when the sentinel is
// wrapped with request-specific detail (the common case: coordinator errors
// are usually returned as fmt.Errorf("%w: ...", sentinel)).
func TestErrorCodeRoundTripsForKnownSentinels(t *testing.T) {
	sentinels := []error{
		ErrDuplicateLease,
		ErrUnknownProfile,
		ErrLeaseNotFound,
		ErrLeaseExpired,
		ErrLeaseNotProvisional,
		ErrBudgetExceeded,
		ErrBudgetExhausted,
		ErrProtectedReservation,
		ErrFairShareContention,
		ErrAdoptionPending,
		ErrEvidenceInvalid,
		ErrEvidenceRequired,
		ErrStalePolicy,
		ErrInvalidPolicy,
		ErrInvalidIdentity,
		ErrCorruptState,
	}
	for _, sentinel := range sentinels {
		t.Run(sentinel.Error(), func(t *testing.T) {
			wrapped := fmt.Errorf("%w: extra request detail", sentinel)
			code := errorCodeForErr(wrapped)
			if code == "" {
				t.Fatalf("expected a non-empty error code for %v", sentinel)
			}
			reconstructed := errForErrorCode(code)
			if !errors.Is(reconstructed, sentinel) {
				t.Fatalf(
					"expected errForErrorCode(%q) to satisfy errors.Is against %v, got %v",
					code, sentinel, reconstructed,
				)
			}
		})
	}
}

func TestErrorCodeForErrIsEmptyForUnrecognizedErrors(t *testing.T) {
	if code := errorCodeForErr(errors.New("some unrelated error")); code != "" {
		t.Fatalf("expected an unrecognized error to map to the empty code, got %q", code)
	}
}

func TestErrForErrorCodeIsNilForUnrecognizedOrEmptyCode(t *testing.T) {
	if err := errForErrorCode(""); err != nil {
		t.Fatalf("expected the empty code to map to a nil error, got %v", err)
	}
	if err := errForErrorCode(ErrorCode("not-a-real-code")); err != nil {
		t.Fatalf("expected an unrecognized code to map to a nil error, got %v", err)
	}
}

func TestProtocolVersionWindow(t *testing.T) {
	server := ServerSupportedVersions()
	if len(server) != 2 || server[0] != CurrentProtocolVersion ||
		server[1] != previousProtocolVersion {
		t.Fatalf("unexpected server protocol window: %#v", server)
	}
	client := ClientSupportedVersions()
	if len(client) != 2 || client[0] != CurrentProtocolVersion ||
		client[1] != previousProtocolVersion {
		t.Fatalf("unexpected client protocol versions: %#v", client)
	}
	if CommandAdopt.supportedBy(1) {
		t.Fatal("protocol one unexpectedly supports adoption")
	}
	if !CommandAdopt.supportedBy(previousProtocolVersion) ||
		!CommandAdopt.supportedBy(CurrentProtocolVersion) {
		t.Fatal("current and previous protocols must support adoption")
	}
	for _, command := range []Command{CommandBeginAdoption, CommandCompleteAdoption} {
		if command.supportedBy(1) {
			t.Fatalf("protocol one unexpectedly supports %q", command)
		}
		if !command.supportedBy(previousProtocolVersion) ||
			!command.supportedBy(CurrentProtocolVersion) {
			t.Fatalf("current and previous protocols must support %q", command)
		}
	}
}

func TestProtocolTwoDowngradesSpecificWithholdingCodes(t *testing.T) {
	for _, sentinel := range []error{
		ErrBudgetExhausted,
		ErrProtectedReservation,
		ErrFairShareContention,
	} {
		if code := errorCodeForErrVersion(sentinel, previousProtocolVersion); code != ErrorCodeBudgetExceeded {
			t.Fatalf("protocol two mapped %v to %q, want %q", sentinel, code, ErrorCodeBudgetExceeded)
		}
	}
}

func TestErrorCodeForErrMapsProtocolMismatch(t *testing.T) {
	if code := errorCodeForErr(ErrProtocolMismatch); code != "" {
		// ErrProtocolMismatch is a client-side sentinel produced from the
		// wire ErrorCodeProtocolMismatch, not the reverse; errorCodeForErr
		// is only used server-side against coordinator sentinels, so it is
		// expected to not recognize it. errForErrorCode is the direction
		// that must recognize ErrorCodeProtocolMismatch.
		t.Fatalf("errorCodeForErr is not expected to map ErrProtocolMismatch, got %q", code)
	}
	if err := errForErrorCode(ErrorCodeProtocolMismatch); !errors.Is(err, ErrProtocolMismatch) {
		t.Fatalf("expected ErrorCodeProtocolMismatch to reconstruct ErrProtocolMismatch, got %v", err)
	}
}
