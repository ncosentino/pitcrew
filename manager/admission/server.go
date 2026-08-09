package admission

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"sync"
)

// Server exposes a Coordinator over a Unix domain socket using one
// JSON-encoded Request/Response per connection. It never mounts a Docker
// socket, host port, repository credential, or worker volume; the socket
// path is the sole transport boundary, and only participating managers are
// expected to hold the volume in which it lives.
type Server struct {
	coordinator       *Coordinator
	listener          net.Listener
	supportedVersions []int
	logger            *slog.Logger

	mu       sync.Mutex
	closed   bool
	shutdown chan struct{}
	wg       sync.WaitGroup
}

// NewServer wraps coordinator with a Unix domain socket listener bound to
// socketPath. The socket file is removed first if a stale one exists from a
// prior process, matching the same crash-then-restart tolerance as the
// durable state store.
func NewServer(coordinator *Coordinator, socketPath string, logger *slog.Logger) (*Server, error) {
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(os.Stderr, nil))
	}
	if err := os.Remove(socketPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("remove stale admission socket %s: %w", socketPath, err)
	}
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return nil, fmt.Errorf("listen on admission socket %s: %w", socketPath, err)
	}
	return &Server{
		coordinator:       coordinator,
		listener:          listener,
		supportedVersions: ServerSupportedVersions(),
		logger:            logger,
		shutdown:          make(chan struct{}),
	}, nil
}

// Addr returns the underlying socket address, primarily for tests.
func (s *Server) Addr() net.Addr {
	return s.listener.Addr()
}

// Serve accepts connections until ctx is cancelled or Close is called. Each
// connection is handled synchronously against the shared Coordinator, which
// serializes every mutation behind its own mutex, so concurrent connections
// can never together exceed the configured budget.
func (s *Server) Serve(ctx context.Context) error {
	go func() {
		select {
		case <-ctx.Done():
			_ = s.Close()
		case <-s.shutdown:
		}
	}()
	for {
		connection, err := s.listener.Accept()
		if err != nil {
			s.mu.Lock()
			closed := s.closed
			s.mu.Unlock()
			if closed {
				s.wg.Wait()
				return nil
			}
			return fmt.Errorf("accept admission connection: %w", err)
		}
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			s.handle(connection)
		}()
	}
}

// Close stops accepting new connections and waits for in-flight requests to
// finish being written before returning.
func (s *Server) Close() error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil
	}
	s.closed = true
	s.mu.Unlock()
	close(s.shutdown)
	return s.listener.Close()
}

func (s *Server) handle(connection net.Conn) {
	defer func() {
		_ = connection.Close()
	}()
	reader := bufio.NewReader(connection)
	line, err := reader.ReadBytes('\n')
	if err != nil {
		return
	}
	var request Request
	if err := json.Unmarshal(line, &request); err != nil {
		s.writeResponse(connection, Response{
			Status: responseStatusError,
			Error:  "malformed request",
		})
		return
	}
	response := s.dispatch(request)
	s.writeResponse(connection, response)
}

func (s *Server) writeResponse(connection net.Conn, response Response) {
	encoded, err := json.Marshal(response)
	if err != nil {
		s.logger.Error("failed to encode admission response", "error", err)
		return
	}
	encoded = append(encoded, '\n')
	if _, err := connection.Write(encoded); err != nil {
		s.logger.Warn("failed to write admission response", "error", err)
	}
}

func (s *Server) dispatch(request Request) Response {
	version, overlap := NegotiateProtocolVersion(s.supportedVersions, request.ProtocolVersions)
	if !overlap {
		return Response{
			Status: responseStatusError,
			Error:  "no overlapping protocol version",
		}
	}
	response := Response{ProtocolVersion: version, Status: responseStatusOK}
	switch request.Command {
	case CommandApplyPolicy:
		if request.Policy == nil {
			return errorResponse(version, "policy is required")
		}
		if err := s.coordinator.ApplyPolicy(*request.Policy); err != nil {
			return errorResponse(version, err.Error())
		}
	case CommandSetDemand:
		s.coordinator.SetDemand(request.ProfileID, request.PendingDemand)
	case CommandAcquire:
		lease, err := s.coordinator.Acquire(request.ProfileID, request.SlotKey, request.PendingDemand)
		if err != nil && !errors.Is(err, ErrDuplicateLease) {
			return errorResponse(version, err.Error())
		}
		response.Lease = &lease
		if errors.Is(err, ErrDuplicateLease) {
			response.Error = err.Error()
		}
	case CommandRenew:
		lease, err := s.coordinator.Renew(request.ProfileID, request.SlotKey)
		if err != nil {
			return errorResponse(version, err.Error())
		}
		response.Lease = &lease
	case CommandActivate:
		lease, err := s.coordinator.Activate(request.ProfileID, request.SlotKey)
		if err != nil {
			return errorResponse(version, err.Error())
		}
		response.Lease = &lease
	case CommandRelease:
		if err := s.coordinator.Release(request.ProfileID, request.SlotKey); err != nil {
			return errorResponse(version, err.Error())
		}
	case CommandReconcile:
		if err := s.coordinator.Reconcile(request.ProfileID, request.SlotKey, request.Evidence); err != nil {
			return errorResponse(version, err.Error())
		}
	case CommandStatus:
		snapshot := s.coordinator.Status()
		response.Snapshot = &snapshot
	default:
		return errorResponse(version, fmt.Sprintf("unsupported command %q", request.Command))
	}
	return response
}

func errorResponse(version int, message string) Response {
	return Response{
		ProtocolVersion: version,
		Status:          responseStatusError,
		Error:           message,
	}
}
