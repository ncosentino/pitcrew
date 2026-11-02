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

type controlPlaneRetryState struct {
	SchemaVersion          int    `json:"schemaVersion"`
	ManagerContractVersion int    `json:"managerContractVersion"`
	ProfileID              string `json:"profileId"`
	ConsecutiveFailures    int    `json:"consecutiveFailures"`
	NextAttemptAt          string `json:"nextAttemptAt"`
}

type controlPlaneRateGate struct {
	operationMu         sync.Mutex
	mu                  sync.Mutex
	path                string
	profileID           string
	clock               clock
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
		path:      path,
		profileID: profileID,
		clock:     gateClock,
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
	nextAttemptAt, err := time.Parse(time.RFC3339, state.NextAttemptAt)
	if err != nil {
		return err
	}
	g.mu.Lock()
	g.consecutiveFailures = min(
		state.ConsecutiveFailures,
		maxRegistrationCleanupAttempts,
	)
	g.nextAttemptAt = nextAttemptAt
	g.mu.Unlock()
	return nil
}

func (g *controlPlaneRateGate) before() error {
	if g == nil {
		return nil
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	now := g.clock.now().UTC()
	if now.Before(g.nextAttemptAt) {
		return controlPlaneBackoffError{retryAt: g.nextAttemptAt}
	}
	g.nextAttemptAt = now.Add(
		registrationAccessNextDelay(g.profileID, 0, false),
	)
	return g.saveLocked()
}

func (g *controlPlaneRateGate) after(operationErr error) {
	if g == nil {
		return
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if operationErr == nil || expectedControlPlaneResult(operationErr) {
		g.consecutiveFailures = 0
		g.nextAttemptAt = time.Time{}
		if err := g.clearLocked(); err != nil {
			g.nextAttemptAt = g.clock.now().UTC().Add(
				registrationAccessNextDelay(g.profileID, 0, false),
			)
		}
		return
	}
	if g.consecutiveFailures < maxRegistrationCleanupAttempts {
		g.consecutiveFailures++
	}
	rateLimited := classifyFailure(operationErr) == reasonRateLimited
	var delay time.Duration
	if rateLimited {
		delay = registrationAccessNextDelay(
			g.profileID,
			g.consecutiveFailures,
			true,
		)
	} else {
		delay = registrationOperationRetryDelay(g.consecutiveFailures)
	}
	g.nextAttemptAt = g.clock.now().UTC().Add(delay)
	_ = g.saveLocked()
}

func (g *controlPlaneRateGate) saveLocked() error {
	if g.path == "" {
		return nil
	}
	return writeJSONAtomically(g.path, controlPlaneRetryState{
		SchemaVersion:          1,
		ManagerContractVersion: managerContractVersion,
		ProfileID:              g.profileID,
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

func expectedControlPlaneResult(err error) bool {
	return errors.Is(err, scaleset.RunnerNotFoundError) ||
		errors.Is(err, scaleset.JobStillRunningError)
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
	operation func() error,
) error {
	if s.gate != nil {
		s.gate.operationMu.Lock()
		defer s.gate.operationMu.Unlock()
	}
	if err := s.gate.before(); err != nil {
		return err
	}
	err := operation()
	s.gate.after(err)
	return err
}

func (s *pacedScaleSetService) ensureScaleSet(
	ctx context.Context,
	name string,
	runnerGroup string,
	labels []string,
) (scaleSetHandle, error) {
	var result scaleSetHandle
	err := s.run(func() error {
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
	err := s.run(func() error {
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
	err := s.run(func() error {
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
	err := s.run(func() error {
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
	return s.run(func() error {
		return s.inner.removeRunner(ctx, runnerID)
	})
}

func (s *pacedScaleSetService) checkRegistrationAccess(
	ctx context.Context,
) error {
	return s.run(func() error {
		return s.inner.checkRegistrationAccess(ctx)
	})
}

func (s *pacedScaleSetService) openSession(
	ctx context.Context,
	scaleSetID int,
	owner string,
) (messageSession, error) {
	var result messageSession
	err := s.run(func() error {
		var err error
		result, err = s.inner.openSession(ctx, scaleSetID, owner)
		return err
	})
	return result, err
}

func (s *pacedScaleSetService) deleteScaleSet(
	ctx context.Context,
	scaleSetID int,
) error {
	return s.run(func() error {
		return s.inner.deleteScaleSet(ctx, scaleSetID)
	})
}

var _ scaleSetServiceFactory = (*pacedScaleSetServiceFactory)(nil)
var _ scaleSetService = (*pacedScaleSetService)(nil)
