package admission

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"sync"
	"time"
)

// maxRequestBytes bounds one wire request so a misbehaving or hostile
// client can never force the server to buffer an unbounded line.
const maxRequestBytes = 64 * 1024

// maxConcurrentHandlers bounds how many connections this server services at
// once. Combined with defaultConnectionDeadline, it guarantees Close can
// never wait forever on an unbounded number of half-open or stalled
// connections: at most this many handler goroutines can be outstanding at
// any time, and each is bounded by its own connection deadline.
const maxConcurrentHandlers = 64

// defaultConnectionDeadline bounds how long the server waits, in total, for
// one connection's request to arrive and its response to be written.
const defaultConnectionDeadline = 30 * time.Second

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
	// connectionDeadline is a struct field, not a bare use of the package
	// constant, so tests in this package can shorten it to exercise the
	// stalled-client path deterministically without a real 30-second wait.
	connectionDeadline time.Duration

	mu           sync.Mutex
	closed       bool
	shutdown     chan struct{}
	wg           sync.WaitGroup
	handlerSlots chan struct{}
}

// NewServer wraps coordinator with a Unix domain socket listener bound to
// socketPath. A stale socket file left behind by a prior crashed process at
// the same path is removed and replaced; any other pre-existing file (for
// example a regular file placed there by mistake or by something hostile)
// is rejected outright rather than silently deleted. The socket is chmoded
// to 0600 immediately after binding, so only the owning user can connect,
// matching the durable state store's file permissions.
func NewServer(coordinator *Coordinator, socketPath string, logger *slog.Logger) (*Server, error) {
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(os.Stderr, nil))
	}
	if info, err := os.Lstat(socketPath); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return nil, fmt.Errorf(
				"admission socket path %s exists and is not a socket; refusing to remove it",
				socketPath,
			)
		}
		if err := os.Remove(socketPath); err != nil {
			return nil, fmt.Errorf("remove stale admission socket %s: %w", socketPath, err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("stat admission socket path %s: %w", socketPath, err)
	}
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return nil, fmt.Errorf("listen on admission socket %s: %w", socketPath, err)
	}
	if err := os.Chmod(socketPath, 0o600); err != nil {
		_ = listener.Close()
		return nil, fmt.Errorf("set admission socket permissions %s: %w", socketPath, err)
	}
	return &Server{
		coordinator:        coordinator,
		listener:           listener,
		supportedVersions:  ServerSupportedVersions(),
		logger:             logger,
		connectionDeadline: defaultConnectionDeadline,
		shutdown:           make(chan struct{}),
		handlerSlots:       make(chan struct{}, maxConcurrentHandlers),
	}, nil
}

// Addr returns the underlying socket address, primarily for tests.
func (s *Server) Addr() net.Addr {
	return s.listener.Addr()
}

// Serve accepts connections until ctx is cancelled or Close is called. Each
// connection is handled synchronously against the shared Coordinator, which
// serializes every mutation behind its own mutex, so concurrent connections
// can never together exceed the configured budget. No more than
// maxConcurrentHandlers connections are serviced at once; once that many
// are outstanding, Serve blocks accepting further connections until one
// finishes or its connection deadline elapses.
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
		select {
		case s.handlerSlots <- struct{}{}:
		case <-s.shutdown:
			_ = connection.Close()
			s.wg.Wait()
			return nil
		}
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			defer func() { <-s.handlerSlots }()
			s.handle(connection)
		}()
	}
}

// Close stops accepting new connections and waits for in-flight requests to
// finish being written before returning. Because every handler goroutine
// enforces its own connection deadline, and at most maxConcurrentHandlers
// can ever be outstanding, this wait is always bounded.
func (s *Server) Close() error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil
	}
	s.closed = true
	s.mu.Unlock()
	close(s.shutdown)
	err := s.listener.Close()
	s.wg.Wait()
	return err
}

func (s *Server) handle(connection net.Conn) {
	defer func() {
		_ = connection.Close()
	}()
	deadline := time.Now().Add(s.connectionDeadline)
	if err := connection.SetDeadline(deadline); err != nil {
		s.logger.Warn("failed to set admission connection deadline", "error", err)
	}
	limited := &io.LimitedReader{R: connection, N: maxRequestBytes}
	reader := bufio.NewReader(limited)
	line, err := reader.ReadBytes('\n')
	if err != nil {
		if limited.N <= 0 {
			// The client may still have in-flight bytes beyond the bound
			// already sitting in the socket buffer; discard a further
			// bounded amount, with a short deadline of its own, before
			// closing. Closing with unread inbound data pending can
			// otherwise be surfaced by the platform as a reset that
			// discards the error response written below instead of
			// delivering it.
			_ = connection.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
			_, _ = io.CopyN(io.Discard, connection, maxRequestBytes)
			_ = connection.SetReadDeadline(deadline)
			s.writeResponse(connection, Response{
				Status:    responseStatusError,
				Error:     "request exceeds maximum size",
				ErrorCode: ErrorCodeRequestTooLarge,
			})
		}
		return
	}
	var request Request
	if err := json.Unmarshal(line, &request); err != nil {
		s.writeResponse(connection, Response{
			Status:    responseStatusError,
			Error:     "malformed request",
			ErrorCode: ErrorCodeMalformedRequest,
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
			Status:    responseStatusError,
			Error:     "no overlapping protocol version",
			ErrorCode: ErrorCodeProtocolMismatch,
		}
	}
	response := Response{ProtocolVersion: version, Status: responseStatusOK}
	switch request.Command {
	case CommandApplyPolicy:
		if request.Policy == nil {
			return errorResponse(version, fmt.Errorf("%w: policy is required", ErrInvalidPolicy))
		}
		if err := s.coordinator.ApplyPolicy(*request.Policy); err != nil {
			return errorResponse(version, err)
		}
	case CommandSetDemand:
		s.coordinator.SetDemand(request.ProfileID, request.PendingDemand)
	case CommandAcquire:
		lease, err := s.coordinator.Acquire(request.ProfileID, request.SlotKey, request.PendingDemand)
		if err != nil && !errors.Is(err, ErrDuplicateLease) {
			return errorResponse(version, err)
		}
		response.Lease = &lease
		if errors.Is(err, ErrDuplicateLease) {
			response.Error = err.Error()
			response.ErrorCode = ErrorCodeDuplicateLease
		}
	case CommandRenew:
		lease, err := s.coordinator.Renew(request.ProfileID, request.SlotKey)
		if err != nil {
			return errorResponse(version, err)
		}
		response.Lease = &lease
	case CommandActivate:
		lease, err := s.coordinator.Activate(request.ProfileID, request.SlotKey)
		if err != nil {
			return errorResponse(version, err)
		}
		response.Lease = &lease
	case CommandRelease:
		if err := s.coordinator.Release(request.ProfileID, request.SlotKey); err != nil {
			return errorResponse(version, err)
		}
	case CommandReconcile:
		if err := s.coordinator.Reconcile(request.ProfileID, request.SlotKey, request.Evidence); err != nil {
			return errorResponse(version, err)
		}
	case CommandStatus:
		snapshot := s.coordinator.Status()
		response.Snapshot = &snapshot
	default:
		return errorResponse(version, fmt.Errorf("unsupported command %q", request.Command))
	}
	return response
}

func errorResponse(version int, err error) Response {
	return Response{
		ProtocolVersion: version,
		Status:          responseStatusError,
		Error:           err.Error(),
		ErrorCode:       errorCodeForErr(err),
	}
}
