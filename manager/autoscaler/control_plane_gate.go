package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/actions/scaleset"
)

const (
	controlPlaneCrashRetryBase   = time.Minute
	controlPlaneCrashRetryJitter = 15 * time.Second
)

type controlPlaneRetryState struct {
	SchemaVersion          int    `json:"schemaVersion"`
	ManagerContractVersion int    `json:"managerContractVersion"`
	ProfileID              string `json:"profileId"`
	CredentialIdentity     string `json:"credentialIdentity,omitempty"`
	ConsecutiveFailures    int    `json:"consecutiveFailures"`
	NextAttemptAt          string `json:"nextAttemptAt"`
}

type controlPlaneRateGate struct {
	mu                  sync.Mutex
	path                string
	profileID           string
	credentialIdentity  string
	clock               clock
	slots               chan struct{}
	inFlight            int
	rateLimited         bool
	consecutiveFailures int
	nextAttemptAt       time.Time
}

type controlPlaneBackoffError struct {
	retryAt time.Time
}

func (e controlPlaneBackoffError) Error() string {
	return "GitHub control-plane operation is waiting on retry backoff"
}

func newControlPlaneRateGate(
	path string,
	profileID string,
	gateClock clock,
) *controlPlaneRateGate {
	return &controlPlaneRateGate{
		path:               path,
		profileID:          profileID,
		credentialIdentity: "pat",
		clock:              gateClock,
		slots:              make(chan struct{}, registrationAccessMaxConcurrency),
	}
}

func (g *controlPlaneRateGate) load() error {
	if g == nil || g.path == "" {
		return nil
	}
	data, exists, err := readOptionalFile(g.path)
	if err != nil || !exists {
		return err
	}
	var state controlPlaneRetryState
	if err := json.Unmarshal(data, &state); err != nil {
		return err
	}
	if state.SchemaVersion != 1 ||
		state.ManagerContractVersion < 22 ||
		state.ManagerContractVersion > managerContractVersion ||
		state.ProfileID != g.profileID ||
		state.ConsecutiveFailures < 0 ||
		state.NextAttemptAt == "" {
		return errors.New("GitHub control-plane retry state is incompatible")
	}
	savedCredentialIdentity := state.CredentialIdentity
	if savedCredentialIdentity == "" {
		savedCredentialIdentity = "pat"
	}
	if savedCredentialIdentity != g.credentialIdentity {
		return nil
	}
	nextAttemptAt, err := time.Parse(time.RFC3339, state.NextAttemptAt)
	if err != nil {
		return err
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	g.consecutiveFailures = min(
		state.ConsecutiveFailures,
		maxRegistrationCleanupAttempts,
	)
	g.rateLimited = g.consecutiveFailures > 0
	g.nextAttemptAt = nextAttemptAt
	if !g.rateLimited {
		maximum := g.clock.now().UTC().Add(g.crashRetryDelay())
		if g.nextAttemptAt.After(maximum) {
			g.nextAttemptAt = maximum
			return g.saveLocked()
		}
	}
	return nil
}

func (g *controlPlaneRateGate) crashRetryDelay() time.Duration {
	return controlPlaneCrashRetryBase +
		deterministicRetryJitter(g.profileID, controlPlaneCrashRetryJitter)
}

func (g *controlPlaneRateGate) before() error {
	if g == nil {
		return nil
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	now := g.clock.now().UTC()
	if (g.rateLimited || g.inFlight == 0) && now.Before(g.nextAttemptAt) {
		return controlPlaneBackoffError{retryAt: g.nextAttemptAt}
	}
	if g.inFlight == 0 {
		g.rateLimited = false
		g.nextAttemptAt = now.Add(g.crashRetryDelay())
		if err := g.saveLocked(); err != nil {
			return err
		}
	}
	g.inFlight++
	return nil
}

func (g *controlPlaneRateGate) after(operationErr error) error {
	if g == nil {
		return nil
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.inFlight > 0 {
		g.inFlight--
	}
	if classifyFailure(operationErr) == reasonRateLimited {
		return g.recordRateLimitLocked()
	}
	if g.inFlight > 0 || g.rateLimited {
		return nil
	}
	if err := g.clearLocked(); err != nil {
		return err
	}
	g.consecutiveFailures = 0
	g.nextAttemptAt = time.Time{}
	return nil
}

func (g *controlPlaneRateGate) observe(operationErr error) error {
	if g == nil || classifyFailure(operationErr) != reasonRateLimited {
		return nil
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.recordRateLimitLocked()
}

func (g *controlPlaneRateGate) recordRateLimitLocked() error {
	g.rateLimited = true
	if g.consecutiveFailures < maxRegistrationCleanupAttempts {
		g.consecutiveFailures++
	}
	g.nextAttemptAt = g.clock.now().UTC().Add(
		registrationAccessNextDelay(
			g.profileID,
			g.consecutiveFailures,
			true,
		),
	)
	return g.saveLocked()
}

func (g *controlPlaneRateGate) saveLocked() error {
	if g.path == "" {
		return nil
	}
	return writeJSONAtomically(g.path, controlPlaneRetryState{
		SchemaVersion:          1,
		ManagerContractVersion: managerContractVersion,
		ProfileID:              g.profileID,
		CredentialIdentity:     g.credentialIdentity,
		ConsecutiveFailures:    g.consecutiveFailures,
		NextAttemptAt:          g.nextAttemptAt.Format(time.RFC3339),
	})
}

func (g *controlPlaneRateGate) clearLocked() error {
	if g.path == "" {
		return nil
	}
	if err := os.Remove(g.path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("clear GitHub control-plane retry state: %w", err)
	}
	return nil
}

type pacedScaleSetServiceFactory struct {
	inner scaleSetServiceFactory
	gate  *controlPlaneRateGate
}

func (f *pacedScaleSetServiceFactory) newService(
	registrationURL string,
) (scaleSetService, error) {
	service, err := f.inner.newService(registrationURL)
	if err != nil {
		return nil, err
	}
	return &pacedScaleSetService{
		inner: service,
		gate:  f.gate,
	}, nil
}

type pacedScaleSetService struct {
	inner scaleSetService
	gate  *controlPlaneRateGate
}

func (s *pacedScaleSetService) run(
	ctx context.Context,
	operation func() error,
) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if s.gate != nil {
		select {
		case s.gate.slots <- struct{}{}:
			defer func() { <-s.gate.slots }()
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := s.gate.before(); err != nil {
		return err
	}
	err := operation()
	return errors.Join(err, s.gate.after(err))
}

func (s *pacedScaleSetService) ensureScaleSet(
	ctx context.Context,
	name string,
	runnerGroup string,
	labels []string,
) (scaleSetHandle, error) {
	var result scaleSetHandle
	err := s.run(ctx, func() error {
		var err error
		result, err = s.inner.ensureScaleSet(ctx, name, runnerGroup, labels)
		return err
	})
	return result, err
}

func (s *pacedScaleSetService) findScaleSet(
	ctx context.Context,
	name string,
	runnerGroup string,
) (scaleSetHandle, bool, error) {
	var result scaleSetHandle
	var found bool
	err := s.run(ctx, func() error {
		var err error
		result, found, err = s.inner.findScaleSet(ctx, name, runnerGroup)
		return err
	})
	return result, found, err
}

func (s *pacedScaleSetService) generateJIT(
	ctx context.Context,
	scaleSetID int,
	runnerName string,
) (jitRunnerConfig, error) {
	var result jitRunnerConfig
	err := s.run(ctx, func() error {
		var err error
		result, err = s.inner.generateJIT(ctx, scaleSetID, runnerName)
		return err
	})
	return result, err
}

func (s *pacedScaleSetService) findRunnerByName(
	ctx context.Context,
	runnerName string,
) (runnerReference, bool, error) {
	var result runnerReference
	var found bool
	err := s.run(ctx, func() error {
		var err error
		result, found, err = s.inner.findRunnerByName(ctx, runnerName)
		return err
	})
	return result, found, err
}

func (s *pacedScaleSetService) removeRunner(
	ctx context.Context,
	runnerID int64,
) error {
	return s.run(ctx, func() error {
		return s.inner.removeRunner(ctx, runnerID)
	})
}

func (s *pacedScaleSetService) checkRegistrationAccess(
	ctx context.Context,
) error {
	return s.run(ctx, func() error {
		return s.inner.checkRegistrationAccess(ctx)
	})
}

func (s *pacedScaleSetService) openSession(
	ctx context.Context,
	scaleSetID int,
	owner string,
) (messageSession, error) {
	var result messageSession
	err := s.run(ctx, func() error {
		var err error
		result, err = s.inner.openSession(ctx, scaleSetID, owner)
		return err
	})
	if err != nil {
		return nil, err
	}
	return &pacedMessageSession{
		inner: result,
		gate:  s.gate,
	}, nil
}

func (s *pacedScaleSetService) deleteScaleSet(
	ctx context.Context,
	scaleSetID int,
) error {
	return s.run(ctx, func() error {
		return s.inner.deleteScaleSet(ctx, scaleSetID)
	})
}

var _ scaleSetServiceFactory = (*pacedScaleSetServiceFactory)(nil)
var _ scaleSetService = (*pacedScaleSetService)(nil)

type pacedMessageSession struct {
	inner messageSession
	gate  *controlPlaneRateGate
}

func (s *pacedMessageSession) GetMessage(
	ctx context.Context,
	lastMessageID int,
	maxCapacity int,
) (*scaleset.RunnerScaleSetMessage, error) {
	message, err := s.inner.GetMessage(ctx, lastMessageID, maxCapacity)
	return message, errors.Join(err, s.gate.observe(err))
}

func (s *pacedMessageSession) DeleteMessage(
	ctx context.Context,
	messageID int,
) error {
	err := s.inner.DeleteMessage(ctx, messageID)
	return errors.Join(err, s.gate.observe(err))
}

func (s *pacedMessageSession) AcquireJobs(
	ctx context.Context,
	jobMessageIDs []int64,
) ([]int64, error) {
	acquired, err := s.inner.AcquireJobs(ctx, jobMessageIDs)
	return acquired, errors.Join(err, s.gate.observe(err))
}

func (s *pacedMessageSession) Session() scaleset.RunnerScaleSetSession {
	return s.inner.Session()
}

func (s *pacedMessageSession) Close(ctx context.Context) error {
	err := s.inner.Close(ctx)
	return errors.Join(err, s.gate.observe(err))
}

var _ messageSession = (*pacedMessageSession)(nil)
