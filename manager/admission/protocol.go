package admission

import (
	"errors"
	"sort"
)

// CurrentProtocolVersion is the exact wire protocol version this build
// speaks by default. ADR-0003 requires the service to keep serving the
// current and immediately previous client protocol during a rolling
// manager upgrade; ServerSupportedVersions expresses that compatibility
// window explicitly rather than leaving it implicit in a single constant.
const CurrentProtocolVersion = 1

// ServerSupportedVersions returns the protocol versions this build's server
// accepts, newest first. There is no previous version yet: once a second
// version ships, this slice grows to include it, and the server keeps
// speaking both until every participating manager has been replaced.
func ServerSupportedVersions() []int {
	return []int{CurrentProtocolVersion}
}

// ClientSupportedVersions returns the protocol versions this build's client
// can speak, newest first.
func ClientSupportedVersions() []int {
	return []int{CurrentProtocolVersion}
}

// NegotiateProtocolVersion picks the highest protocol version both the
// server and the client support. It returns false when no overlap exists,
// so the caller can reject the connection instead of guessing a fallback.
func NegotiateProtocolVersion(serverVersions, clientVersions []int) (int, bool) {
	supported := make(map[int]struct{}, len(serverVersions))
	for _, version := range serverVersions {
		supported[version] = struct{}{}
	}
	best := 0
	found := false
	for _, version := range clientVersions {
		if _, ok := supported[version]; ok && version > best {
			best = version
			found = true
		}
	}
	return best, found
}

// Command identifies one requested coordinator operation over the wire
// protocol.
type Command string

const (
	CommandApplyPolicy Command = "apply-policy"
	CommandSetDemand   Command = "set-demand"
	CommandAcquire     Command = "acquire"
	CommandRenew       Command = "renew"
	CommandActivate    Command = "activate"
	CommandRelease     Command = "release"
	CommandReconcile   Command = "reconcile"
	CommandStatus      Command = "status"
)

// Request is the exact, versioned wire envelope a client sends to the
// admission service over the Unix domain socket. ProtocolVersions lists
// every protocol version the client is willing to speak; the server picks
// the highest version it also supports and reports it in the Response.
type Request struct {
	ProtocolVersions []int       `json:"protocolVersions"`
	Command          Command     `json:"command"`
	ProfileID        string      `json:"profileId,omitempty"`
	SlotKey          string      `json:"slotKey,omitempty"`
	PendingDemand    int         `json:"pendingDemand,omitempty"`
	Evidence         string      `json:"evidence,omitempty"`
	Policy           *HostPolicy `json:"policy,omitempty"`
}

// Response is the exact, versioned wire envelope the admission service
// returns for one Request.
type Response struct {
	ProtocolVersion int       `json:"protocolVersion"`
	Status          string    `json:"status"`
	Error           string    `json:"error,omitempty"`
	ErrorCode       ErrorCode `json:"errorCode,omitempty"`
	Lease           *Lease    `json:"lease,omitempty"`
	Snapshot        *Snapshot `json:"snapshot,omitempty"`
}

// ErrorCode is a stable, wire-safe identifier for a known coordinator or
// transport error. Response.Error remains the free-form, human-readable
// message for logs and CLI output; ErrorCode is what a client uses to
// reconstruct the exact package sentinel error so errors.Is keeps working
// across the wire, even though the human message may change over time or
// carry request-specific detail.
type ErrorCode string

const (
	ErrorCodeUnknownProfile      ErrorCode = "unknown-profile"
	ErrorCodeDuplicateLease      ErrorCode = "duplicate-lease"
	ErrorCodeLeaseNotFound       ErrorCode = "lease-not-found"
	ErrorCodeLeaseExpired        ErrorCode = "lease-expired"
	ErrorCodeLeaseNotProvisional ErrorCode = "lease-not-provisional"
	ErrorCodeBudgetExceeded      ErrorCode = "budget-exceeded"
	ErrorCodeEvidenceRequired    ErrorCode = "evidence-required"
	ErrorCodeEvidenceInvalid     ErrorCode = "evidence-invalid"
	ErrorCodeInvalidPolicy       ErrorCode = "invalid-policy"
	ErrorCodeStalePolicy         ErrorCode = "stale-policy"
	ErrorCodeCorruptState        ErrorCode = "corrupt-state"
	ErrorCodeRequestTooLarge     ErrorCode = "request-too-large"
	ErrorCodeMalformedRequest    ErrorCode = "malformed-request"
	ErrorCodeProtocolMismatch    ErrorCode = "protocol-mismatch"
)

// errorCodeForErr maps a coordinator sentinel error to its stable wire
// code. It uses errors.Is so an error wrapped with additional detail (for
// example "%w: profile %q ...") still maps to the correct code. An error
// this package does not recognize maps to the empty code, and the client
// falls back to the free-form message.
func errorCodeForErr(err error) ErrorCode {
	switch {
	case errors.Is(err, ErrDuplicateLease):
		return ErrorCodeDuplicateLease
	case errors.Is(err, ErrUnknownProfile):
		return ErrorCodeUnknownProfile
	case errors.Is(err, ErrLeaseNotFound):
		return ErrorCodeLeaseNotFound
	case errors.Is(err, ErrLeaseExpired):
		return ErrorCodeLeaseExpired
	case errors.Is(err, ErrLeaseNotProvisional):
		return ErrorCodeLeaseNotProvisional
	case errors.Is(err, ErrBudgetExceeded):
		return ErrorCodeBudgetExceeded
	case errors.Is(err, ErrEvidenceInvalid):
		return ErrorCodeEvidenceInvalid
	case errors.Is(err, ErrEvidenceRequired):
		return ErrorCodeEvidenceRequired
	case errors.Is(err, ErrStalePolicy):
		return ErrorCodeStalePolicy
	case errors.Is(err, ErrInvalidPolicy):
		return ErrorCodeInvalidPolicy
	case errors.Is(err, ErrCorruptState):
		return ErrorCodeCorruptState
	default:
		return ""
	}
}

// errForErrorCode is the client-side inverse of errorCodeForErr: it
// reconstructs the package sentinel error for a known code so
// errors.Is(err, admission.ErrX) succeeds for a caller that only observed
// the wire response. An unrecognized or empty code returns nil, and the
// caller falls back to the free-form message.
func errForErrorCode(code ErrorCode) error {
	switch code {
	case ErrorCodeDuplicateLease:
		return ErrDuplicateLease
	case ErrorCodeUnknownProfile:
		return ErrUnknownProfile
	case ErrorCodeLeaseNotFound:
		return ErrLeaseNotFound
	case ErrorCodeLeaseExpired:
		return ErrLeaseExpired
	case ErrorCodeLeaseNotProvisional:
		return ErrLeaseNotProvisional
	case ErrorCodeBudgetExceeded:
		return ErrBudgetExceeded
	case ErrorCodeEvidenceInvalid:
		return ErrEvidenceInvalid
	case ErrorCodeEvidenceRequired:
		return ErrEvidenceRequired
	case ErrorCodeStalePolicy:
		return ErrStalePolicy
	case ErrorCodeInvalidPolicy:
		return ErrInvalidPolicy
	case ErrorCodeCorruptState:
		return ErrCorruptState
	case ErrorCodeProtocolMismatch:
		return ErrProtocolMismatch
	default:
		return nil
	}
}

const (
	responseStatusOK    = "ok"
	responseStatusError = "error"
)

// sortedInts returns a stable, ascending copy of values, used so wire
// fixtures and tests never depend on caller ordering.
func sortedInts(values []int) []int {
	sorted := append([]int(nil), values...)
	sort.Ints(sorted)
	return sorted
}
