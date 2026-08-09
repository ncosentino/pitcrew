package admission

import (
	"context"
	"errors"
	"os"
	"path/filepath"
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
