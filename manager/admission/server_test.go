package admission

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
	"time"
)

// shortSocketDir returns a short-lived temporary directory outside
// t.TempDir()'s long, test-name-derived path. Unix domain socket addresses
// are bound by a short fixed-size buffer (traditionally 108 bytes,
// including on Windows' AF_UNIX support), and t.TempDir() nests a full test
// name into the path, which routinely exceeds that limit.
func shortSocketDir(t *testing.T) string {
	t.Helper()
	directory, err := os.MkdirTemp("", "pcadm")
	if err != nil {
		t.Fatalf("create short socket directory: %v", err)
	}
	t.Cleanup(func() {
		_ = os.RemoveAll(directory)
	})
	return directory
}

func startTestServer(t *testing.T, coordinator *Coordinator) (*Server, string) {
	t.Helper()
	socketPath := filepath.Join(shortSocketDir(t), "a.sock")
	server, err := NewServer(coordinator, socketPath, nil)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		if err := server.Serve(ctx); err != nil {
			t.Errorf("serve: %v", err)
		}
	}()
	t.Cleanup(func() {
		cancel()
		_ = server.Close()
		<-done
	})
	return server, socketPath
}

func TestServerClientAcquireActivateReleaseOverSocket(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 2, 1, 0, false))
	_, socketPath := startTestServer(t, coordinator)

	client := NewClient(socketPath)
	lease, err := client.Acquire("alpha", "slot-a", 1)
	if err != nil {
		t.Fatalf("acquire over socket: %v", err)
	}
	if lease.Status != LeaseProvisional {
		t.Fatalf("expected provisional lease over the wire, got %q", lease.Status)
	}
	active, err := client.Activate("alpha", "slot-a")
	if err != nil {
		t.Fatalf("activate over socket: %v", err)
	}
	if active.Status != LeaseActive {
		t.Fatalf("expected active lease over the wire, got %q", active.Status)
	}
	snapshot, err := client.Status()
	if err != nil {
		t.Fatalf("status over socket: %v", err)
	}
	if len(snapshot.Leases) != 1 {
		t.Fatalf("expected one lease in remote snapshot, got %d", len(snapshot.Leases))
	}
	if err := client.Release("alpha", "slot-a"); err != nil {
		t.Fatalf("release over socket: %v", err)
	}
	snapshot, err = client.Status()
	if err != nil {
		t.Fatalf("status after release: %v", err)
	}
	if len(snapshot.Leases) != 0 || len(snapshot.Tombstones) != 1 {
		t.Fatalf("expected release to be durable over the wire, got %+v", snapshot)
	}
}

// TestClientSetDemandPropagatesCoordinatorErrorsOverSocket confirms
// SetDemand's error path is not swallowed by the server: a client request
// naming an unknown profile must reach the client as a non-nil error
// carrying the coordinator's sentinel, not silently succeed.
func TestClientSetDemandPropagatesCoordinatorErrorsOverSocket(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 2, 1, 0, false))
	_, socketPath := startTestServer(t, coordinator)

	client := NewClient(socketPath)
	if err := client.SetDemand("never-registered", 1); !errors.Is(err, ErrUnknownProfile) {
		t.Fatalf("expected ErrUnknownProfile over the wire, got %v", err)
	}
	if err := client.SetDemand("alpha", 3); err != nil {
		t.Fatalf("expected a known profile's demand to be accepted over the wire: %v", err)
	}
}

func TestServerRejectsClientWithNoOverlappingProtocolVersion(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 2, 1, 0, false))
	_, socketPath := startTestServer(t, coordinator)

	client := NewClient(socketPath).WithSupportedVersions([]int{99})
	_, err := client.Acquire("alpha", "slot-a", 1)
	if !errors.Is(err, ErrProtocolMismatch) {
		t.Fatalf("expected ErrProtocolMismatch, got %v", err)
	}
}

func TestServerAcceptsOverlappingProtocolVersionAmongMultiple(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 2, 1, 0, false))
	_, socketPath := startTestServer(t, coordinator)

	client := NewClient(socketPath).WithSupportedVersions([]int{0, CurrentProtocolVersion, 99})
	if _, err := client.Acquire("alpha", "slot-a", 1); err != nil {
		t.Fatalf("expected overlapping version to be accepted: %v", err)
	}
}

func TestServerSerializesConcurrentClientsWithinBudget(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 4, 1, 0, false))
	_, socketPath := startTestServer(t, coordinator)

	const attempts = 20
	var wg sync.WaitGroup
	granted := make(chan bool, attempts)
	for i := 0; i < attempts; i++ {
		wg.Add(1)
		go func(index int) {
			defer wg.Done()
			client := NewClient(socketPath)
			_, err := client.Acquire("alpha", slotName(index), 1)
			granted <- err == nil
		}(i)
	}
	wg.Wait()
	close(granted)

	count := 0
	for ok := range granted {
		if ok {
			count++
		}
	}
	if count != 4 {
		t.Fatalf("expected exactly 4 grants across concurrent clients, got %d", count)
	}
}

// --- Server hardening ---------------------------------------------------------

func TestNewServerRejectsPreExistingNonSocketPath(t *testing.T) {
	directory := shortSocketDir(t)
	socketPath := filepath.Join(directory, "a.sock")
	if err := os.WriteFile(socketPath, []byte("not a socket"), 0o600); err != nil {
		t.Fatalf("seed a regular file at the socket path: %v", err)
	}
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	if _, err := NewServer(coordinator, socketPath, nil); err == nil {
		t.Fatal("expected NewServer to reject a pre-existing regular file at the socket path")
	}
}

func TestNewServerReplacesStaleSocketFile(t *testing.T) {
	directory := shortSocketDir(t)
	socketPath := filepath.Join(directory, "a.sock")
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)

	first, err := NewServer(coordinator, socketPath, nil)
	if err != nil {
		t.Fatalf("first NewServer: %v", err)
	}
	if err := first.Close(); err != nil {
		t.Fatalf("close first server: %v", err)
	}
	// The socket file is left behind by Close (only the listener is
	// closed, matching a crash that leaves a stale socket file on disk); a
	// fresh NewServer at the same path must still succeed by replacing it.
	second, err := NewServer(coordinator, socketPath, nil)
	if err != nil {
		t.Fatalf("expected NewServer to replace a stale socket file, got %v", err)
	}
	_ = second.Close()
}

func TestNewServerSocketHasOwnerOnlyPermissions(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX file mode bits are not meaningfully enforced on Windows")
	}
	directory := shortSocketDir(t)
	socketPath := filepath.Join(directory, "a.sock")
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	server, err := NewServer(coordinator, socketPath, nil)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	defer func() { _ = server.Close() }()

	info, err := os.Stat(socketPath)
	if err != nil {
		t.Fatalf("stat socket: %v", err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("expected socket permissions 0600, got %o", got)
	}
}

func TestServerRejectsOversizedRequest(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 2, 1, 0, false))
	_, socketPath := startTestServer(t, coordinator)

	connection, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer func() { _ = connection.Close() }()
	if err := connection.SetDeadline(time.Now().Add(10 * time.Second)); err != nil {
		t.Fatalf("set deadline: %v", err)
	}

	oversized := make([]byte, maxRequestBytes+1024)
	for i := range oversized {
		oversized[i] = 'a'
	}
	if _, err := connection.Write(oversized); err != nil {
		t.Fatalf("write oversized payload: %v", err)
	}
	if _, err := connection.Write([]byte("\n")); err != nil {
		t.Fatalf("write trailing newline: %v", err)
	}

	reader := bufio.NewReader(connection)
	line, err := reader.ReadBytes('\n')
	if err != nil {
		t.Fatalf("read response: %v", err)
	}
	var response Response
	if err := json.Unmarshal(line, &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.ErrorCode != ErrorCodeRequestTooLarge {
		t.Fatalf("expected ErrorCodeRequestTooLarge, got %+v", response)
	}
}

func TestServerEnforcesConnectionDeadlineOnStalledClient(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 2, 1, 0, false))

	socketPath := filepath.Join(shortSocketDir(t), "a.sock")
	server, err := NewServer(coordinator, socketPath, nil)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	server.connectionDeadline = 100 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = server.Serve(ctx)
	}()
	t.Cleanup(func() {
		cancel()
		_ = server.Close()
		<-done
	})

	connection, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer func() { _ = connection.Close() }()
	// Never write a complete (newline-terminated) request: the server must
	// give up after its own connection deadline rather than hang forever.
	if _, err := connection.Write([]byte("{\"incomplete")); err != nil {
		t.Fatalf("write partial request: %v", err)
	}
	if err := connection.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	buffer := make([]byte, 1)
	_, readErr := connection.Read(buffer)
	if readErr == nil {
		t.Fatal("expected the server to close the stalled connection after its deadline")
	}
}

func TestClientReconstructsDuplicateLeaseSentinelFromWireErrorCode(t *testing.T) {
	clock := newManualClock()
	coordinator := OpenMemory(clock, time.Minute)
	mustApplyPolicy(t, coordinator, singleProfilePolicy("alpha", 2, 1, 0, false))
	_, socketPath := startTestServer(t, coordinator)

	client := NewClient(socketPath)
	first, err := client.Acquire("alpha", "slot-a", 1)
	if err != nil {
		t.Fatalf("first acquire: %v", err)
	}
	second, err := client.Acquire("alpha", "slot-a", 1)
	if !errors.Is(err, ErrDuplicateLease) {
		t.Fatalf("expected errors.Is(err, ErrDuplicateLease) over the wire, got %v", err)
	}
	if second.LeaseID != first.LeaseID {
		t.Fatalf("expected the duplicate acquire to still return the existing lease over the wire")
	}
}
