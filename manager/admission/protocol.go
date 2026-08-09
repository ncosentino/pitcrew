package admission

import "sort"

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
	Lease           *Lease    `json:"lease,omitempty"`
	Snapshot        *Snapshot `json:"snapshot,omitempty"`
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
