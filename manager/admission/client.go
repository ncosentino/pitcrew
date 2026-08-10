package admission

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"time"
)

// ErrProtocolMismatch reports that the client and the connected admission
// service share no overlapping protocol version.
var ErrProtocolMismatch = errors.New("admission: no overlapping protocol version")

// Client is a minimal Unix domain socket client for the admission wire
// protocol. It is intentionally dependency-free so the same client logic can
// back both the CLI binary used by the shell manager and direct use from a
// Go manager such as the autoscaler.
type Client struct {
	socketPath        string
	dialTimeout       time.Duration
	requestTimeout    time.Duration
	supportedVersions []int
}

// NewClient builds a client that dials socketPath for every call. Every
// call sets a total connection deadline immediately after dialing, so a
// server that never responds (or that stalls mid-response) can never hang
// a caller indefinitely; the connection is closed and the call fails once
// the deadline elapses.
func NewClient(socketPath string) *Client {
	return &Client{
		socketPath:        socketPath,
		dialTimeout:       5 * time.Second,
		requestTimeout:    10 * time.Second,
		supportedVersions: ClientSupportedVersions(),
	}
}

// WithSupportedVersions overrides the protocol versions this client offers.
// Production callers never need this; it exists so tests can exercise
// protocol negotiation and rejection with synthetic version sets.
func (c *Client) WithSupportedVersions(versions []int) *Client {
	clone := *c
	clone.supportedVersions = append([]int(nil), versions...)
	return &clone
}

func (c *Client) call(request Request) (Response, error) {
	supportedVersions := make([]int, 0, len(c.supportedVersions))
	for _, version := range c.supportedVersions {
		if version >= request.Command.minimumProtocolVersion() {
			supportedVersions = append(supportedVersions, version)
		}
	}
	request.ProtocolVersions = sortedInts(supportedVersions)
	connection, err := net.DialTimeout("unix", c.socketPath, c.dialTimeout)
	if err != nil {
		return Response{}, fmt.Errorf("dial admission socket %s: %w", c.socketPath, err)
	}
	defer func() {
		_ = connection.Close()
	}()
	if err := connection.SetDeadline(time.Now().Add(c.requestTimeout)); err != nil {
		return Response{}, fmt.Errorf("set admission connection deadline: %w", err)
	}

	encoded, err := json.Marshal(request)
	if err != nil {
		return Response{}, fmt.Errorf("encode admission request: %w", err)
	}
	encoded = append(encoded, '\n')
	if _, err := connection.Write(encoded); err != nil {
		return Response{}, fmt.Errorf("write admission request: %w", err)
	}

	reader := bufio.NewReader(connection)
	line, err := reader.ReadBytes('\n')
	if err != nil {
		return Response{}, fmt.Errorf("read admission response: %w", err)
	}
	var response Response
	if err := json.Unmarshal(line, &response); err != nil {
		return Response{}, fmt.Errorf("decode admission response: %w", err)
	}
	if response.ErrorCode == ErrorCodeProtocolMismatch {
		return response, ErrProtocolMismatch
	}
	return response, nil
}

// ApplyPolicy publishes a new host policy to the admission service.
func (c *Client) ApplyPolicy(policy HostPolicy) error {
	response, err := c.call(Request{Command: CommandApplyPolicy, Policy: &policy})
	if err != nil {
		return err
	}
	return responseErr(response)
}

// SetDemand publishes one profile's current pending worker count.
func (c *Client) SetDemand(profileID string, pending int) error {
	response, err := c.call(Request{
		Command:       CommandSetDemand,
		ProfileID:     profileID,
		PendingDemand: pending,
	})
	if err != nil {
		return err
	}
	return responseErr(response)
}

// Acquire requests one provisional lease for profileID/slotKey. A duplicate
// request against a profile/slot pair that already holds a live lease
// returns that lease alongside an error satisfying errors.Is(err,
// ErrDuplicateLease), matching Coordinator.Acquire's local contract.
func (c *Client) Acquire(profileID, slotKey string, pendingDemand int) (Lease, error) {
	response, err := c.call(Request{
		Command:       CommandAcquire,
		ProfileID:     profileID,
		SlotKey:       slotKey,
		PendingDemand: pendingDemand,
	})
	if err != nil {
		return Lease{}, err
	}
	result := responseErr(response)
	if response.Lease == nil {
		if result != nil {
			return Lease{}, result
		}
		return Lease{}, fmt.Errorf("admission: acquire response missing lease")
	}
	return *response.Lease, result
}

// Adopt records an already-running worker as an active lease without applying
// ordinary Acquire budget enforcement. It is idempotent for an existing
// profile/slot lease so manager recovery can safely retry after ambiguous
// coordinator responses.
func (c *Client) Adopt(profileID, slotKey string) (Lease, error) {
	response, err := c.call(Request{
		Command:   CommandAdopt,
		ProfileID: profileID,
		SlotKey:   slotKey,
	})
	if err != nil {
		return Lease{}, err
	}
	if err := responseErr(response); err != nil {
		return Lease{}, err
	}
	if response.Lease == nil {
		return Lease{}, fmt.Errorf("admission: adopt response missing lease")
	}
	return *response.Lease, nil
}

// BeginAdoption establishes this profile manager's durable host-wide recovery
// fence. While any profile has an incomplete adoption pass, ordinary Acquire
// calls are denied across the namespace.
func (c *Client) BeginAdoption(profileID string) error {
	response, err := c.call(Request{
		Command:   CommandBeginAdoption,
		ProfileID: profileID,
	})
	if err != nil {
		return err
	}
	return responseErr(response)
}

// CompleteAdoption clears this profile manager's durable recovery fence after
// every recovered running worker has either been adopted or observed exited.
func (c *Client) CompleteAdoption(profileID string) error {
	response, err := c.call(Request{
		Command:   CommandCompleteAdoption,
		ProfileID: profileID,
	})
	if err != nil {
		return err
	}
	return responseErr(response)
}

// Renew extends a provisional lease's expiry.
func (c *Client) Renew(profileID, slotKey string) (Lease, error) {
	response, err := c.call(Request{Command: CommandRenew, ProfileID: profileID, SlotKey: slotKey})
	if err != nil {
		return Lease{}, err
	}
	if err := responseErr(response); err != nil {
		return Lease{}, err
	}
	if response.Lease == nil {
		return Lease{}, fmt.Errorf("admission: renew response missing lease")
	}
	return *response.Lease, nil
}

// Activate promotes a provisional lease to active.
func (c *Client) Activate(profileID, slotKey string) (Lease, error) {
	response, err := c.call(Request{Command: CommandActivate, ProfileID: profileID, SlotKey: slotKey})
	if err != nil {
		return Lease{}, err
	}
	if err := responseErr(response); err != nil {
		return Lease{}, err
	}
	if response.Lease == nil {
		return Lease{}, fmt.Errorf("admission: activate response missing lease")
	}
	return *response.Lease, nil
}

// Release performs an exact release of one lease.
func (c *Client) Release(profileID, slotKey string) error {
	response, err := c.call(Request{Command: CommandRelease, ProfileID: profileID, SlotKey: slotKey})
	if err != nil {
		return err
	}
	return responseErr(response)
}

// Reconcile performs fenced recovery release for one profile/slot using
// exact retained evidence that the previous worker and registration are
// absent.
func (c *Client) Reconcile(profileID, slotKey, evidence string) error {
	response, err := c.call(Request{
		Command:   CommandReconcile,
		ProfileID: profileID,
		SlotKey:   slotKey,
		Evidence:  evidence,
	})
	if err != nil {
		return err
	}
	return responseErr(response)
}

// Status retrieves a snapshot of the current durable state.
func (c *Client) Status() (Snapshot, error) {
	response, err := c.call(Request{Command: CommandStatus})
	if err != nil {
		return Snapshot{}, err
	}
	if err := responseErr(response); err != nil {
		return Snapshot{}, err
	}
	if response.Snapshot == nil {
		return Snapshot{}, fmt.Errorf("admission: status response missing snapshot")
	}
	return *response.Snapshot, nil
}

// responseErr reconstructs an error from a wire Response. When the response
// carries a recognized ErrorCode, the returned error satisfies
// errors.Is(err, <the matching package sentinel>), regardless of whether
// Status is "error" (a duplicate Acquire response reports Status "ok" plus
// an ErrorCode alongside a still-usable Lease). The human-readable message
// is preserved by wrapping it around the sentinel when it carries extra
// detail; otherwise the sentinel is returned unwrapped.
func responseErr(response Response) error {
	if response.ErrorCode != "" {
		if sentinel := errForErrorCode(response.ErrorCode); sentinel != nil {
			if response.Error != "" && response.Error != sentinel.Error() {
				return fmt.Errorf("%w: %s", sentinel, response.Error)
			}
			return sentinel
		}
	}
	if response.Status == responseStatusError {
		if response.Error == "" {
			return errors.New("admission: unknown error")
		}
		return errors.New(response.Error)
	}
	return nil
}
