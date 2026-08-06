package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/actions/scaleset"
	"github.com/actions/scaleset/listener"
)

type clock interface {
	now() time.Time
}

type realClock struct{}

const staleFenceRetryDelay = 15 * time.Second

func (realClock) now() time.Time {
	return time.Now()
}

type runnerLifecycleState string

const (
	runnerStarting       runnerLifecycleState = "starting"
	runnerIdle           runnerLifecycleState = "idle"
	runnerBusy           runnerLifecycleState = "busy"
	runnerDraining       runnerLifecycleState = "draining"
	runnerCleanupPending runnerLifecycleState = "cleanup-pending"
)

type runnerRecord struct {
	key                 string
	targetKey           string
	repository          string
	runnerName          string
	runnerID            int64
	containerID         string
	container           string
	state               runnerLifecycleState
	startedAt           time.Time
	updatedAt           time.Time
	idleSince           *time.Time
	jobStartedAt        *time.Time
	completedAt         *time.Time
	currentJob          *observedJobContext
	revision            string
	stale               bool
	fenceRetryAt        *time.Time
	recovered           bool
	protected           bool
	registrationRemoved bool
}

type scalerStatistics struct {
	observedAt        time.Time
	assignedJobs      int
	runningJobs       int
	availableJobs     int
	acquiredJobs      int
	registeredRunners int
	busyRunners       int
	idleRunners       int
}

// capacityBlock records why the scaler could not reach its activation target
// during the most recent reconciliation.
type capacityBlock struct {
	reason   string
	evidence string
}

type scalerSnapshot struct {
	blocking         capacityBlock
	target           targetSpec
	scaleSetID       int
	targetSlots      int
	scaleDownAt      *time.Time
	statistics       scalerStatistics
	runners          []runnerRecord
	pendingCleanups  []registrationCleanupRecord
	activeRunners    int
	idleRunners      int
	busyRunners      int
	drainingRunners  int
	staleRunners     int
	minimumIdleSlots int
	retiring         bool
}

type runnerScaler struct {
	operationGate chan struct{}
	mu            sync.Mutex

	lifecycleContext  context.Context
	profileID         string
	image             string
	imageID           string
	resources         workerResourcePolicy
	volumes           []readOnlyVolume
	network           string
	workerRevision    string
	assumeUnversioned bool
	namePrefix        string
	minimumIdle       int
	scaleDownDelay    time.Duration
	target            targetSpec
	scaleSetID        int
	api               scaleSetService
	docker            dockerClient
	clock             clock
	runners           map[string]*runnerRecord
	statistics        scalerStatistics
	targetSlots       int
	scaleDownAt       *time.Time
	shuttingDown      bool
	retiring          bool
	onChange          func()
	onError           func(error)
	nameSuffix        func() (string, error)
	logger            *slog.Logger

	cleanupStore         registrationCleanupStore
	pendingRegistrations map[string]registrationCleanupRecord
	admission            *admissionController
	diagnostics          *diagnosticsRecorder
	blocking             capacityBlock
}

func newRunnerScaler(
	lifecycleContext context.Context,
	cfg config,
	target targetSpec,
	scaleSetID int,
	api scaleSetService,
	docker dockerClient,
	scalerClock clock,
	admission *admissionController,
	diagnostics *diagnosticsRecorder,
	logger *slog.Logger,
	onChange func(),
	onError func(error),
) *runnerScaler {
	if onChange == nil {
		onChange = func() {}
	}
	if onError == nil {
		onError = func(error) {}
	}
	if logger == nil {
		logger = slog.New(slog.DiscardHandler)
	}
	scaler := &runnerScaler{
		operationGate:     make(chan struct{}, 1),
		lifecycleContext:  lifecycleContext,
		profileID:         cfg.profileID,
		image:             cfg.runnerImage,
		imageID:           cfg.workerImageID,
		resources:         cfg.resources,
		volumes:           cfg.readOnlyVolumes,
		network:           cfg.serviceNetwork,
		workerRevision:    cfg.workerRevision,
		assumeUnversioned: cfg.assumeUnversioned,
		namePrefix:        cfg.namePrefix,
		minimumIdle:       cfg.minimumIdle,
		scaleDownDelay:    cfg.scaleDownDelay,
		target:            target,
		scaleSetID:        scaleSetID,
		api:               boundScaleSetService(api),
		docker:            boundDockerClient(docker),
		clock:             scalerClock,
		runners:           make(map[string]*runnerRecord),
		targetSlots:       calculateTarget(target.maximum, cfg.minimumIdle, 0),
		onChange:          onChange,
		onError:           onError,
		nameSuffix:        randomSuffix,
		logger: logger.With(
			"targetKey", target.key,
			"component", "scaler",
		),
		cleanupStore: newRegistrationCleanupStore(
			cfg.stateDirectory,
			target.key,
		),
		pendingRegistrations: make(map[string]registrationCleanupRecord),
		admission:            admission,
		diagnostics:          diagnostics,
	}
	scaler.restorePendingRegistrations()
	scaler.admission.join(target.key, scaler.runnerCount)
	scaler.operationGate <- struct{}{}
	return scaler
}

// restorePendingRegistrations reloads registration cleanup work that a previous
// manager instance could not finish, so a restart cannot turn a known
// registration into an untracked ghost.
func (s *runnerScaler) restorePendingRegistrations() {
	records, err := s.cleanupStore.load()
	if err != nil {
		s.onError(fmt.Errorf(
			"restore pending registration cleanup for %s: %w",
			s.target.key,
			err,
		))
		return
	}
	for _, record := range records {
		s.pendingRegistrations[record.SlotKey] = record
	}
	if len(records) > 0 {
		s.logger.Warn(
			"Restored pending runner registration cleanup",
			"pendingRegistrations", len(records),
		)
	}
}

func calculateTarget(maximum, minimumIdle, assignedJobs int) int {
	if maximum < 0 || minimumIdle < 0 || assignedJobs < 0 {
		return 0
	}
	if minimumIdle >= maximum || assignedJobs >= maximum-minimumIdle {
		return maximum
	}
	return minimumIdle + assignedJobs
}

func registrationRemovalError(err error) error {
	if errors.Is(err, scaleset.RunnerNotFoundError) {
		return nil
	}
	return err
}

func (s *runnerScaler) acquireOperation(ctx context.Context) error {
	if ctx == nil {
		return errors.New("scaler operation context is required")
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-s.operationGate:
		return nil
	}
}

func (s *runnerScaler) releaseOperation() {
	s.operationGate <- struct{}{}
}

// HandleDesiredRunnerCount reconciles live runners to the scale-set demand count.
func (s *runnerScaler) HandleDesiredRunnerCount(
	ctx context.Context,
	assignedJobs int,
) (int, error) {
	if assignedJobs < 0 {
		return 0, errors.New("assigned job count cannot be negative")
	}
	if err := s.acquireOperation(ctx); err != nil {
		return s.capacityCount(), fmt.Errorf("wait for desired-count reconciliation: %w", err)
	}
	defer s.releaseOperation()

	s.mu.Lock()
	s.statistics.assignedJobs = assignedJobs
	if s.retiring {
		s.targetSlots = 0
	} else {
		s.targetSlots = calculateTarget(s.target.maximum, s.minimumIdle, assignedJobs)
	}
	s.mu.Unlock()
	count, err := s.reconcileLocked(ctx)
	if err != nil {
		return count, err
	}
	return count, nil
}

// HandleJobStarted marks the matching local runner busy without changing demand.
func (s *runnerScaler) HandleJobStarted(
	ctx context.Context,
	jobInfo *scaleset.JobStarted,
) error {
	if jobInfo == nil {
		return errors.New("job-started message is required")
	}
	if err := s.acquireOperation(ctx); err != nil {
		return fmt.Errorf("wait to record job start: %w", err)
	}
	defer s.releaseOperation()
	now := s.clock.now().UTC()
	s.mu.Lock()
	runner := s.findRunnerLocked(jobInfo.RunnerName, int64(jobInfo.RunnerID))
	if runner == nil {
		s.mu.Unlock()
		return fmt.Errorf(
			"job-started message references unknown runner %q (%d)",
			jobInfo.RunnerName,
			jobInfo.RunnerID,
		)
	}
	if runner.registrationRemoved {
		s.mu.Unlock()
		return fmt.Errorf(
			"job-started message references deregistered runner %q (%d)",
			jobInfo.RunnerName,
			jobInfo.RunnerID,
		)
	}
	runner.state = runnerBusy
	runner.protected = false
	runner.idleSince = nil
	if runner.jobStartedAt == nil {
		runner.jobStartedAt = timePointer(now)
	}
	runner.currentJob = mergeStartedJobContext(
		runner.currentJob,
		jobContextFromStarted(jobInfo, now),
	)
	runner.updatedAt = now
	s.mu.Unlock()
	s.onChange()
	return nil
}

// HandleJobCompleted marks the matching JIT runner as draining without changing demand.
func (s *runnerScaler) HandleJobCompleted(
	ctx context.Context,
	jobInfo *scaleset.JobCompleted,
) error {
	if jobInfo == nil {
		return errors.New("job-completed message is required")
	}
	if err := s.acquireOperation(ctx); err != nil {
		return fmt.Errorf("wait to record job completion: %w", err)
	}
	defer s.releaseOperation()
	now := s.clock.now().UTC()
	s.mu.Lock()
	runner := s.findRunnerLocked(jobInfo.RunnerName, int64(jobInfo.RunnerID))
	if runner == nil {
		s.mu.Unlock()
		return fmt.Errorf(
			"job-completed message references unknown runner %q (%d)",
			jobInfo.RunnerName,
			jobInfo.RunnerID,
		)
	}
	if runner.registrationRemoved {
		s.mu.Unlock()
		return fmt.Errorf(
			"job-completed message references deregistered runner %q (%d)",
			jobInfo.RunnerName,
			jobInfo.RunnerID,
		)
	}
	runner.state = runnerDraining
	runner.protected = false
	runner.idleSince = nil
	runner.completedAt = timePointer(now)
	runner.currentJob = jobContextFromCompleted(
		jobInfo,
		now,
		runner.currentJob,
	)
	runner.updatedAt = now
	s.mu.Unlock()
	s.onChange()
	return nil
}

// RecordStatistics captures current scale-set job statistics for observed state.
func (s *runnerScaler) RecordStatistics(statistics *scaleset.RunnerScaleSetStatistic) {
	if statistics == nil {
		s.onError(errors.New("scale-set listener supplied nil statistics"))
		return
	}
	s.mu.Lock()
	s.statistics = scalerStatistics{
		observedAt:        s.clock.now().UTC(),
		assignedJobs:      statistics.TotalAssignedJobs,
		runningJobs:       statistics.TotalRunningJobs,
		availableJobs:     statistics.TotalAvailableJobs,
		acquiredJobs:      statistics.TotalAcquiredJobs,
		registeredRunners: statistics.TotalRegisteredRunners,
		busyRunners:       statistics.TotalBusyRunners,
		idleRunners:       statistics.TotalIdleRunners,
	}
	s.mu.Unlock()
	s.onChange()
}

// RecordJobStarted records listener metrics already represented by lifecycle handling.
func (s *runnerScaler) RecordJobStarted(_ *scaleset.JobStarted) {}

// RecordJobCompleted records listener metrics already represented by lifecycle handling.
func (s *runnerScaler) RecordJobCompleted(_ *scaleset.JobCompleted) {}

// RecordDesiredRunners records listener metrics already represented by reconciliation.
func (s *runnerScaler) RecordDesiredRunners(_ int) {}

func (s *runnerScaler) setMaximum(ctx context.Context, maximum int) error {
	if maximum < 0 {
		return errors.New("configured maximum cannot be negative")
	}
	if err := s.acquireOperation(ctx); err != nil {
		return fmt.Errorf("wait to update configured maximum: %w", err)
	}
	defer s.releaseOperation()

	s.mu.Lock()
	previousMaximum := s.target.maximum
	var previousScaleDownAt *time.Time
	if s.scaleDownAt != nil {
		value := *s.scaleDownAt
		previousScaleDownAt = &value
	}
	s.target.maximum = maximum
	if s.retiring {
		s.targetSlots = 0
	} else {
		s.targetSlots = calculateTarget(maximum, s.minimumIdle, s.statistics.assignedJobs)
	}
	s.mu.Unlock()
	if _, err := s.reconcileLocked(ctx); err == nil {
		return nil
	} else {
		applyErr := fmt.Errorf("apply configured maximum %d: %w", maximum, err)
		s.mu.Lock()
		s.target.maximum = previousMaximum
		if s.retiring {
			s.targetSlots = 0
		} else {
			s.targetSlots = calculateTarget(
				previousMaximum,
				s.minimumIdle,
				s.statistics.assignedJobs,
			)
		}
		s.scaleDownAt = previousScaleDownAt
		s.mu.Unlock()

		rollbackContext, rollbackCancel := detachedCleanupContext(ctx)
		_, rollbackErr := s.reconcileLocked(rollbackContext)
		rollbackCancel()
		if rollbackErr != nil {
			rollbackErr = fmt.Errorf(
				"restore configured maximum %d: %w",
				previousMaximum,
				rollbackErr,
			)
		}
		return errors.Join(applyErr, rollbackErr)
	}
}

func (s *runnerScaler) beginRetirement(ctx context.Context) error {
	if err := s.acquireOperation(ctx); err != nil {
		return fmt.Errorf("wait to begin target retirement: %w", err)
	}
	defer s.releaseOperation()
	s.mu.Lock()
	s.retiring = true
	s.target.maximum = 0
	s.targetSlots = 0
	now := s.clock.now().UTC()
	s.scaleDownAt = &now
	s.mu.Unlock()
	_, err := s.reconcileLocked(ctx)
	return err
}

func (s *runnerScaler) reactivate(ctx context.Context, target targetSpec) error {
	if target.maximum < 1 {
		return errors.New("reactivated target maximum must be positive")
	}
	if err := s.acquireOperation(ctx); err != nil {
		return fmt.Errorf("wait to reactivate target: %w", err)
	}
	defer s.releaseOperation()
	s.mu.Lock()
	s.retiring = false
	s.target = target
	s.targetSlots = calculateTarget(
		target.maximum,
		s.minimumIdle,
		s.statistics.assignedJobs,
	)
	s.scaleDownAt = nil
	s.mu.Unlock()
	_, err := s.reconcileLocked(ctx)
	return err
}

func (s *runnerScaler) tick(ctx context.Context) error {
	if err := s.acquireOperation(ctx); err != nil {
		return fmt.Errorf("wait for target reconciliation: %w", err)
	}
	defer s.releaseOperation()
	_, err := s.reconcileLocked(ctx)
	return err
}

func (s *runnerScaler) reconcileLocked(ctx context.Context) (int, error) {
	var operationErrors []error
	if err := s.retryPendingRegistrations(ctx); err != nil {
		operationErrors = append(operationErrors, err)
	}
	if err := s.retryCleanupPending(ctx); err != nil {
		operationErrors = append(operationErrors, err)
	}
	if err := s.retireStaleRunners(ctx); err != nil {
		operationErrors = append(operationErrors, err)
	}
	s.mu.Lock()
	if s.shuttingDown {
		count := s.capacityCountLocked()
		s.mu.Unlock()
		return count, errors.Join(operationErrors...)
	}
	current := s.capacityCountLocked()
	target := s.targetSlots
	if target >= current {
		s.scaleDownAt = nil
	}
	s.mu.Unlock()

	if target > current {
		missing := target - current
		if blocked := s.pendingRegistrationCount(); blocked > 0 {
			if blocked > missing {
				blocked = missing
			}
			missing -= blocked
			s.setBlocking(
				deficitCleanupPending,
				"replacement capacity waits for exact registration cleanup",
			)
			s.logger.Warn(
				"Deferring replacement capacity until registration cleanup completes",
				"blockedSlots", blocked,
			)
		}
		admitted := s.admission.reserve(s.target.key, missing)
		if admitted < missing {
			s.setBlocking(
				deficitAdmissionCeiling,
				"profile active-worker ceiling deferred requested capacity",
			)
			s.logger.Warn(
				"Deferring capacity to respect the profile active-worker ceiling",
				"requestedSlots", missing,
				"admittedSlots", admitted,
			)
			s.diagnostics.record(diagnosticsObservation{
				subsystem: subsystemAdmission,
				operation: operationAdmissionReserve,
				target:    s.target.key,
				outcome:   outcomeBlocked,
				reason:    reasonCapacityCeiling,
				evidence:  "profile active-worker ceiling deferred requested capacity",
			})
		} else if admitted > 0 {
			s.setBlocking(deficitLaunchPending, "admitted workers are still starting")
		}
		for ; admitted > 0; admitted-- {
			_, err := s.startRunner(ctx)
			s.admission.settle(s.target.key, 1)
			if err != nil {
				s.admission.settle(s.target.key, admitted-1)
				return s.capacityCount(), errors.Join(
					errors.Join(operationErrors...),
					fmt.Errorf("start missing runner: %w", err),
				)
			}
		}
		s.onChange()
		return s.capacityCount(), errors.Join(operationErrors...)
	}
	if target == current {
		s.clearBlocking()
		return s.capacityCount(), errors.Join(operationErrors...)
	}
	s.clearBlocking()

	now := s.clock.now().UTC()
	s.mu.Lock()
	if s.scaleDownAt == nil {
		scaleDownAt := now.Add(s.scaleDownDelay)
		s.scaleDownAt = &scaleDownAt
	}
	scaleDownAt := *s.scaleDownAt
	if now.Before(scaleDownAt) {
		count := s.capacityCountLocked()
		s.mu.Unlock()
		s.onChange()
		return count, errors.Join(operationErrors...)
	}
	s.mu.Unlock()

	for {
		s.mu.Lock()
		if s.capacityCountLocked() <= s.targetSlots {
			s.scaleDownAt = nil
			count := s.capacityCountLocked()
			s.mu.Unlock()
			s.onChange()
			return count, errors.Join(operationErrors...)
		}
		candidate := s.oldestIdleRunnerLocked()
		if candidate == nil && s.retiring {
			candidate = s.oldestProtectedRecoveredRunnerLocked()
		}
		if candidate == nil {
			count := s.capacityCountLocked()
			s.mu.Unlock()
			return count, errors.Join(operationErrors...)
		}
		previousState := candidate.state
		previousIdleSince := candidate.idleSince
		candidate.state = runnerDraining
		candidate.idleSince = nil
		candidate.updatedAt = s.clock.now().UTC()
		runnerID := candidate.runnerID
		containerID := candidate.containerID
		runnerKey := candidate.key
		s.mu.Unlock()
		s.onChange()

		if err := registrationRemovalError(
			s.api.removeRunner(ctx, runnerID),
		); err != nil {
			s.mu.Lock()
			if currentRunner := s.runners[runnerKey]; currentRunner != nil {
				if errors.Is(err, scaleset.JobStillRunningError) {
					currentRunner.state = runnerBusy
					currentRunner.protected = false
				} else if currentRunner.state == runnerDraining {
					currentRunner.state = previousState
					currentRunner.idleSince = previousIdleSince
				}
				currentRunner.updatedAt = s.clock.now().UTC()
			}
			s.scaleDownAt = nil
			s.mu.Unlock()
			s.onChange()
			return s.capacityCount(), errors.Join(
				errors.Join(operationErrors...),
				fmt.Errorf("remove runner %d before scale-down: %w", runnerID, err),
			)
		}
		if err := s.docker.stopAndRemove(ctx, containerID); err != nil {
			s.mu.Lock()
			if currentRunner := s.runners[runnerKey]; currentRunner != nil {
				currentRunner.state = runnerCleanupPending
				currentRunner.registrationRemoved = true
				currentRunner.updatedAt = s.clock.now().UTC()
			}
			s.mu.Unlock()
			s.onChange()
			operationErrors = append(operationErrors, fmt.Errorf(
				"stop runner container %s after registration removal: %w",
				containerID,
				err,
			))
			continue
		}

		s.mu.Lock()
		delete(s.runners, runnerKey)
		s.mu.Unlock()
		s.onChange()
	}
}

// setBlocking records why the scaler could not reach its activation target, so
// published capacity evidence carries the manager's actual blocking reason.
func (s *runnerScaler) setBlocking(reason string, evidence string) {
	s.mu.Lock()
	s.blocking = capacityBlock{reason: reason, evidence: evidence}
	s.mu.Unlock()
}

func (s *runnerScaler) clearBlocking() {
	s.mu.Lock()
	s.blocking = capacityBlock{}
	s.mu.Unlock()
}

func (s *runnerScaler) retryCleanupPending(ctx context.Context) error {
	s.mu.Lock()
	pending := make([]runnerRecord, 0)
	for _, runner := range s.runners {
		if runner.state == runnerCleanupPending {
			pending = append(pending, *runner)
		}
	}
	s.mu.Unlock()
	sort.Slice(pending, func(i, j int) bool {
		return pending[i].key < pending[j].key
	})

	var cleanupErrors []error
	for _, runner := range pending {
		if err := s.docker.stopAndRemove(ctx, runner.containerID); err != nil {
			cleanupErrors = append(cleanupErrors, fmt.Errorf(
				"retry cleanup for runner container %s: %w",
				runner.containerID,
				err,
			))
			continue
		}
		s.mu.Lock()
		if current := s.runners[runner.key]; current != nil &&
			current.state == runnerCleanupPending {
			delete(s.runners, runner.key)
		}
		s.mu.Unlock()
		s.onChange()
	}
	return errors.Join(cleanupErrors...)
}

// beginPendingRegistrationCleanup durably records the exact runner identity
// before its registration removal is attempted, so a crash mid-removal cannot
// forget a registration that GitHub may still hold.
func (s *runnerScaler) beginPendingRegistrationCleanup(
	runner runnerRecord,
	diagnostic *lastExitDiagnostic,
	now time.Time,
) registrationCleanupRecord {
	s.mu.Lock()
	record, exists := s.pendingRegistrations[runner.key]
	if !exists {
		record = registrationCleanupRecord{
			TargetKey:     s.target.key,
			SlotKey:       runner.key,
			RunnerID:      runner.runnerID,
			RunnerName:    runner.runnerName,
			ContainerID:   runner.containerID,
			ContainerName: runner.container,
			FirstFailedAt: now.Format(time.RFC3339),
		}
	}
	if diagnostic != nil {
		value := *diagnostic
		record.LastExit = &value
	}
	s.pendingRegistrations[record.SlotKey] = record
	evicted := s.boundPendingRegistrationsLocked()
	records := s.pendingRegistrationsLocked()
	s.mu.Unlock()
	s.reportEvictedRegistrations(evicted)
	s.persistPendingRegistrations(records)
	return record
}

// markPendingRegistrationAttempt keeps a failed registration removal pending
// with bounded retry metadata.
func (s *runnerScaler) markPendingRegistrationAttempt(
	record registrationCleanupRecord,
	now time.Time,
	cause error,
) {
	s.mu.Lock()
	current, exists := s.pendingRegistrations[record.SlotKey]
	if !exists {
		current = record
	}
	if current.FirstFailedAt == "" {
		current.FirstFailedAt = now.Format(time.RFC3339)
	}
	current.Attempts++
	current.LastAttemptAt = now.Format(time.RFC3339)
	current.NextAttemptAt = now.Add(registrationCleanupRetryDelay).Format(time.RFC3339)
	s.pendingRegistrations[current.SlotKey] = current
	evicted := s.boundPendingRegistrationsLocked()
	records := s.pendingRegistrationsLocked()
	s.mu.Unlock()
	s.reportEvictedRegistrations(evicted)
	s.persistPendingRegistrations(records)
	retryAt := now.Add(registrationCleanupRetryDelay)
	s.diagnostics.record(diagnosticsObservation{
		subsystem: subsystemCleanup,
		operation: operationRegistrationCleanup,
		target:    current.SlotKey,
		outcome:   outcomeRetry,
		reason:    classifyFailure(cause),
		evidence:  "exact runner registration removal is still pending",
		attempt:   current.Attempts,
		retryAt:   &retryAt,
	})
	s.logger.Warn(
		"Runner registration cleanup is pending",
		"slotKey", current.SlotKey,
		"runnerId", current.RunnerID,
		"attempts", current.Attempts,
	)
	s.onError(fmt.Errorf(
		"remove registration for runner %d after container exit: %w",
		current.RunnerID,
		cause,
	))
}

func (s *runnerScaler) resolvePendingRegistration(slotKey string, reason string) {
	s.mu.Lock()
	_, exists := s.pendingRegistrations[slotKey]
	delete(s.pendingRegistrations, slotKey)
	records := s.pendingRegistrationsLocked()
	s.mu.Unlock()
	if !exists {
		return
	}
	s.persistPendingRegistrations(records)
	s.diagnostics.record(diagnosticsObservation{
		subsystem: subsystemCleanup,
		operation: operationRegistrationCleanup,
		target:    slotKey,
		outcome:   outcomeSucceeded,
		reason:    reasonNone,
		evidence:  "exact runner registration cleanup resolved as " + reason,
	})
	s.logger.Info(
		"Runner registration cleanup completed",
		"slotKey", slotKey,
		"reason", reason,
	)
}

func (s *runnerScaler) persistPendingRegistrations(
	records []registrationCleanupRecord,
) {
	if err := s.cleanupStore.save(records); err != nil {
		s.onError(fmt.Errorf(
			"persist pending registration cleanup for %s: %w",
			s.target.key,
			err,
		))
	}
}

func (s *runnerScaler) reportEvictedRegistrations(
	evicted []registrationCleanupRecord,
) {
	for _, record := range evicted {
		s.onError(fmt.Errorf(
			"pending registration cleanup for runner %d was dropped at the %d record bound",
			record.RunnerID,
			maxPendingRegistrationCleanups,
		))
	}
}

func (s *runnerScaler) boundPendingRegistrationsLocked() []registrationCleanupRecord {
	evicted := make([]registrationCleanupRecord, 0)
	for len(s.pendingRegistrations) > maxPendingRegistrationCleanups {
		var oldest *registrationCleanupRecord
		for _, record := range s.pendingRegistrations {
			if oldest == nil ||
				record.FirstFailedAt < oldest.FirstFailedAt ||
				(record.FirstFailedAt == oldest.FirstFailedAt &&
					record.SlotKey < oldest.SlotKey) {
				value := record
				oldest = &value
			}
		}
		if oldest == nil {
			break
		}
		delete(s.pendingRegistrations, oldest.SlotKey)
		evicted = append(evicted, *oldest)
	}
	return evicted
}

func (s *runnerScaler) pendingRegistrationsLocked() []registrationCleanupRecord {
	records := make([]registrationCleanupRecord, 0, len(s.pendingRegistrations))
	for _, record := range s.pendingRegistrations {
		records = append(records, record)
	}
	sort.Slice(records, func(i, j int) bool {
		return records[i].SlotKey < records[j].SlotKey
	})
	return records
}

func (s *runnerScaler) pendingRegistrationCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.pendingRegistrations)
}

// removeExitedRegistration removes the exact JIT registration of a worker that
// has exited, retaining a durable cleanup-pending record when GitHub cannot
// confirm the removal.
func (s *runnerScaler) removeExitedRegistration(
	runner runnerRecord,
	diagnostic lastExitDiagnostic,
) {
	now := s.clock.now().UTC()
	record := s.beginPendingRegistrationCleanup(runner, &diagnostic, now)
	cleanupContext, cleanupCancel := detachedCleanupContext(s.lifecycleContext)
	err := registrationRemovalError(
		s.api.removeRunner(cleanupContext, record.RunnerID),
	)
	cleanupCancel()
	if err == nil {
		s.resolvePendingRegistration(record.SlotKey, "removed")
		return
	}
	s.markPendingRegistrationAttempt(record, s.clock.now().UTC(), err)
}

// retryPendingRegistrations retries registration removals that previously
// failed, including work restored after a manager restart.
func (s *runnerScaler) retryPendingRegistrations(ctx context.Context) error {
	s.mu.Lock()
	pending := s.pendingRegistrationsLocked()
	s.mu.Unlock()

	var cleanupErrors []error
	for _, record := range pending {
		if s.registrationHeldByLiveRunner(record) {
			s.resolvePendingRegistration(record.SlotKey, "held-by-live-runner")
			continue
		}
		now := s.clock.now().UTC()
		if !registrationCleanupDue(record, now) {
			continue
		}
		err := registrationRemovalError(
			s.api.removeRunner(ctx, record.RunnerID),
		)
		if err == nil {
			s.resolvePendingRegistration(record.SlotKey, "removed")
			continue
		}
		s.markPendingRegistrationAttempt(record, s.clock.now().UTC(), err)
		cleanupErrors = append(cleanupErrors, fmt.Errorf(
			"retry registration removal for runner %d: %w",
			record.RunnerID,
			err,
		))
	}
	return errors.Join(cleanupErrors...)
}

// registrationHeldByLiveRunner reports whether a live worker still owns the
// exact identity of a pending cleanup record, so cleanup can never deregister
// an assigned or busy runner.
func (s *runnerScaler) registrationHeldByLiveRunner(
	record registrationCleanupRecord,
) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, runner := range s.runners {
		if runner.registrationRemoved {
			continue
		}
		if runner.runnerID == record.RunnerID ||
			runner.containerID == record.ContainerID {
			return true
		}
	}
	return false
}

func (s *runnerScaler) startRunner(ctx context.Context) (*runnerRecord, error) {
	requestedName, err := s.nextRunnerName()
	if err != nil {
		return nil, err
	}
	launchStartedAt := s.clock.now()
	jit, err := s.api.generateJIT(ctx, s.scaleSetID, requestedName)
	if err != nil {
		s.setBlocking(
			deficitJITFailed,
			"just-in-time runner configuration could not be generated",
		)
		s.recordLaunchFailure(
			"",
			classifyFailure(err),
			"just-in-time runner configuration could not be generated",
			launchStartedAt,
		)
		return nil, err
	}

	slotKey := s.target.key + "-" + strconv.FormatInt(jit.runnerID, 10)
	containerName := sanitizeIdentifier(jit.runnerName, 63)
	if containerName == "" {
		cleanupContext, cleanupCancel := detachedCleanupContext(ctx)
		cleanupErr := registrationRemovalError(
			s.api.removeRunner(cleanupContext, jit.runnerID),
		)
		cleanupCancel()
		return nil, errors.Join(
			errors.New("JIT runner name cannot form a Docker container name"),
			cleanupErr,
		)
	}
	labels := map[string]string{
		managedProfileLabelKey: s.profileID,
		managedSlotLabelKey:    slotKey,
		autoscalerLabelKey:     "true",
		targetKeyLabelKey:      s.target.key,
		runnerNameLabelKey:     jit.runnerName,
		runnerIDLabelKey:       strconv.FormatInt(jit.runnerID, 10),
		workerRevisionLabelKey: s.workerRevision,
	}
	containerID, err := s.docker.run(ctx, containerLaunch{
		name:      containerName,
		image:     s.image,
		jitConfig: jit.encoded,
		labels:    labels,
		resources: s.resources,
		volumes:   s.volumes,
		network:   s.network,
	})
	if err != nil {
		launchFailure := launchFailureDiagnostic(s.clock.now())
		s.setBlocking(deficitDockerFailed, "worker container launch failed")
		s.recordLaunchFailure(
			slotKey,
			dockerFailureReason(err),
			"worker container launch failed",
			launchStartedAt,
		)
		s.logger.Warn(
			"Runner container launch failed",
			"slotKey", slotKey,
			"classification", launchFailure.Classification,
			"observedAt", launchFailure.ObservedAt,
		)
		cleanupContext, cleanupCancel := detachedCleanupContext(ctx)
		cleanupErr := registrationRemovalError(
			s.api.removeRunner(cleanupContext, jit.runnerID),
		)
		cleanupCancel()
		if cleanupErr != nil {
			return nil, errors.Join(err, fmt.Errorf(
				"remove registration for unlaunched runner %d: %w",
				jit.runnerID,
				cleanupErr,
			))
		}
		return nil, err
	}

	now := s.clock.now().UTC()
	runner := &runnerRecord{
		key:         slotKey,
		targetKey:   s.target.key,
		repository:  s.target.repository,
		runnerName:  jit.runnerName,
		runnerID:    jit.runnerID,
		containerID: containerID,
		container:   containerName,
		state:       runnerStarting,
		revision:    s.workerRevision,
		startedAt:   now,
		updatedAt:   now,
	}
	s.mu.Lock()
	if s.shuttingDown {
		s.mu.Unlock()
		cleanupContext, cleanupCancel := detachedCleanupContext(ctx)
		defer cleanupCancel()
		removeErr := registrationRemovalError(
			s.api.removeRunner(cleanupContext, runner.runnerID),
		)
		if removeErr != nil {
			removeErr = fmt.Errorf(
				"remove runner %d started during shutdown: %w",
				runner.runnerID,
				removeErr,
			)
		}
		containerErr := s.docker.stopAndRemove(
			cleanupContext,
			runner.containerID,
		)
		return nil, errors.Join(
			errors.New("autoscaler began shutdown while starting a runner"),
			removeErr,
			containerErr,
		)
	}
	s.runners[runner.key] = runner
	s.mu.Unlock()
	s.recordLaunchOutcome(runner.key, launchStartedAt)
	s.monitorRunner(runner, now)
	s.onChange()
	return runner, nil
}

// recordLaunchFailure journals a failed worker launch with the manager's own
// classification instead of raw Docker or API output.
func (s *runnerScaler) recordLaunchFailure(
	slotKey string,
	reason string,
	evidence string,
	startedAt time.Time,
) {
	target := slotKey
	if target == "" {
		target = s.target.key
	}
	duration := s.clock.now().Sub(startedAt)
	s.diagnostics.record(diagnosticsObservation{
		subsystem: subsystemWorkerLaunch,
		operation: operationWorkerLaunch,
		target:    target,
		outcome:   launchOutcome(reason),
		reason:    reason,
		evidence:  evidence,
		duration:  &duration,
		attempt:   1,
	})
}

func launchOutcome(reason string) string {
	if reason == reasonTimeout {
		return outcomeTimedOut
	}
	return outcomeFailed
}

func (s *runnerScaler) recordLaunchOutcome(slotKey string, startedAt time.Time) {
	duration := s.clock.now().Sub(startedAt)
	s.diagnostics.record(diagnosticsObservation{
		subsystem: subsystemWorkerLaunch,
		operation: operationWorkerLaunch,
		target:    slotKey,
		outcome:   outcomeSucceeded,
		reason:    reasonNone,
		evidence:  "worker launched for one job",
		duration:  &duration,
		attempt:   1,
	})
}

func (s *runnerScaler) recover(container recoveredContainer) error {
	if container.targetKey != s.target.key {
		return fmt.Errorf(
			"container %s target %q does not match controller target %q",
			container.containerID,
			container.targetKey,
			s.target.key,
		)
	}
	startedAt := container.createdAt.UTC()
	if startedAt.IsZero() {
		startedAt = s.clock.now().UTC()
	}
	runner := &runnerRecord{
		key:         container.slotKey,
		targetKey:   container.targetKey,
		repository:  s.target.repository,
		runnerName:  container.runnerName,
		runnerID:    container.runnerID,
		containerID: container.containerID,
		container:   container.name,
		state:       runnerStarting,
		revision:    container.revision,
		stale: container.revision != s.workerRevision &&
			!(container.revision == "" && s.assumeUnversioned),
		startedAt: startedAt,
		updatedAt: s.clock.now().UTC(),
		recovered: true,
		protected: true,
	}

	s.mu.Lock()
	if _, exists := s.runners[runner.key]; exists {
		s.mu.Unlock()
		return fmt.Errorf("duplicate recovered runner key %q", runner.key)
	}
	s.runners[runner.key] = runner
	s.mu.Unlock()
	snapshotAt := s.clock.now().UTC()
	monitorSince := snapshotAt
	lines, err := s.docker.readLogs(s.lifecycleContext, runner.containerID)
	if err != nil {
		s.onError(err)
		monitorSince = startedAt
	} else {
		var latest runnerLifecycleState
		for _, line := range lines {
			if state, ok := lifecycleStateFromLog(line); ok {
				latest = state
			}
		}
		if latest != "" {
			s.applyLogState(runner.containerID, latest, snapshotAt)
		}
	}
	s.monitorRunner(runner, monitorSince)
	s.onChange()
	return nil
}

func (s *runnerScaler) retireStaleRunners(ctx context.Context) error {
	s.mu.Lock()
	candidates := make([]runnerRecord, 0)
	now := s.clock.now().UTC()
	for _, runner := range s.runners {
		if !runner.stale ||
			runner.registrationRemoved ||
			runner.state == runnerBusy ||
			runner.state == runnerDraining ||
			runner.state == runnerCleanupPending ||
			runner.fenceRetryAt != nil && now.Before(*runner.fenceRetryAt) {
			continue
		}
		candidates = append(candidates, *runner)
	}
	s.mu.Unlock()
	sort.Slice(candidates, func(i, j int) bool {
		return candidates[i].key < candidates[j].key
	})

	var operationErrors []error
	for _, candidate := range candidates {
		s.mu.Lock()
		current := s.runners[candidate.key]
		if current == nil ||
			!current.stale ||
			current.registrationRemoved ||
			current.state == runnerBusy ||
			current.state == runnerDraining ||
			current.state == runnerCleanupPending {
			s.mu.Unlock()
			continue
		}
		previousState := current.state
		previousIdleSince := current.idleSince
		current.state = runnerDraining
		current.idleSince = nil
		current.updatedAt = s.clock.now().UTC()
		runnerID := current.runnerID
		containerID := current.containerID
		s.mu.Unlock()
		s.onChange()

		err := registrationRemovalError(s.api.removeRunner(ctx, runnerID))
		if err != nil {
			s.mu.Lock()
			if current := s.runners[candidate.key]; current != nil {
				if errors.Is(err, scaleset.JobStillRunningError) {
					current.state = runnerBusy
					current.protected = false
				} else if current.state == runnerDraining {
					current.state = previousState
					current.idleSince = previousIdleSince
					retryAt := s.clock.now().UTC().Add(staleFenceRetryDelay)
					current.fenceRetryAt = &retryAt
				}
				current.updatedAt = s.clock.now().UTC()
			}
			s.mu.Unlock()
			s.onChange()
			if !errors.Is(err, scaleset.JobStillRunningError) {
				operationErrors = append(operationErrors, fmt.Errorf(
					"fence stale runner %d before replacement: %w",
					runnerID,
					err,
				))
			}
			continue
		}

		if err := s.docker.stopAndRemove(ctx, containerID); err != nil {
			s.mu.Lock()
			if current := s.runners[candidate.key]; current != nil {
				current.state = runnerCleanupPending
				current.registrationRemoved = true
				current.updatedAt = s.clock.now().UTC()
			}
			s.mu.Unlock()
			s.onChange()
			operationErrors = append(operationErrors, fmt.Errorf(
				"stop stale runner container %s after registration removal: %w",
				containerID,
				err,
			))
			continue
		}

		s.mu.Lock()
		delete(s.runners, candidate.key)
		s.mu.Unlock()
		s.onChange()
	}
	return errors.Join(operationErrors...)
}

func (s *runnerScaler) monitorRunner(runner *runnerRecord, since time.Time) {
	go func() {
		err := s.docker.followLogs(
			s.lifecycleContext,
			runner.containerID,
			since,
			func(line string) {
				s.handleLogSignal(runner.containerID, line)
			},
		)
		if err != nil && !errors.Is(err, context.Canceled) &&
			s.lifecycleContext.Err() == nil {
			s.onError(err)
		}
	}()
	go func() {
		retryDelay := time.Second
		for {
			exitCode, err := s.docker.wait(
				s.lifecycleContext,
				runner.containerID,
			)
			if s.lifecycleContext.Err() != nil {
				return
			}
			if err == nil {
				s.handleContainerExit(runner.containerID, &exitCode)
				return
			}
			s.onError(err)
			running, stateErr := s.docker.isRunning(
				s.lifecycleContext,
				runner.containerID,
			)
			if s.lifecycleContext.Err() != nil {
				return
			}
			if stateErr != nil {
				s.onError(stateErr)
			} else if !running {
				s.handleContainerExit(runner.containerID, nil)
				return
			}
			if !s.hasRunner(runner.containerID) {
				return
			}
			timer := time.NewTimer(retryDelay)
			select {
			case <-s.lifecycleContext.Done():
				if !timer.Stop() {
					select {
					case <-timer.C:
					default:
					}
				}
				return
			case <-timer.C:
			}
			retryDelay = min(retryDelay*2, 30*time.Second)
		}
	}()
}

func (s *runnerScaler) handleLogSignal(containerID, line string) {
	nextState, ok := lifecycleStateFromLog(line)
	if !ok {
		return
	}
	s.applyLogState(containerID, nextState, s.clock.now().UTC())
}

func (s *runnerScaler) applyLogState(
	containerID string,
	nextState runnerLifecycleState,
	observedAt time.Time,
) {
	if err := s.acquireOperation(s.lifecycleContext); err != nil {
		return
	}
	defer s.releaseOperation()
	s.mu.Lock()
	runner := s.findRunnerByContainerLocked(containerID)
	if runner == nil {
		s.mu.Unlock()
		return
	}
	if runner.registrationRemoved {
		s.mu.Unlock()
		return
	}
	if nextState == runnerIdle && runner.state == runnerBusy {
		s.mu.Unlock()
		return
	}
	runner.state = nextState
	runner.protected = false
	runner.updatedAt = observedAt
	if nextState == runnerIdle {
		runner.idleSince = timePointer(observedAt)
	} else {
		runner.idleSince = nil
	}
	if nextState == runnerBusy && runner.jobStartedAt == nil {
		runner.jobStartedAt = timePointer(observedAt)
	}
	if nextState == runnerDraining && runner.completedAt == nil {
		runner.completedAt = timePointer(observedAt)
	}
	s.mu.Unlock()
	s.onChange()
}

func lifecycleStateFromLog(line string) (runnerLifecycleState, bool) {
	lower := strings.ToLower(line)
	switch {
	case strings.Contains(lower, "listening for jobs"):
		return runnerIdle, true
	case strings.Contains(lower, "running job") || strings.Contains(lower, "job started"):
		return runnerBusy, true
	case strings.Contains(lower, "job completed") ||
		strings.Contains(lower, "completed job") ||
		(strings.Contains(lower, "job ") && strings.Contains(lower, " completed")):
		return runnerDraining, true
	default:
		return "", false
	}
}

// captureExitEvidence records Docker's own exit evidence for the exact
// container before it disappears. Workers launch with --rm, so a missing
// container falls back to the status reported by docker wait, and an
// unobserved status stays unknown instead of being guessed.
func (s *runnerScaler) captureExitEvidence(
	containerID string,
	exitCode *int,
) lastExitDiagnostic {
	observedAt := s.clock.now().UTC()
	inspectContext, cancel := detachedCleanupContext(s.lifecycleContext)
	state, inspected := s.docker.inspectExit(inspectContext, containerID)
	cancel()
	if inspected {
		return classifyContainerExit(state, true, observedAt)
	}
	if exitCode == nil {
		return classifyContainerExit(containerExitState{exitCode: -1}, false, observedAt)
	}
	return classifyContainerExit(
		containerExitState{exitCode: *exitCode},
		false,
		observedAt,
	)
}

func (s *runnerScaler) handleContainerExit(containerID string, exitCode *int) {
	if err := s.acquireOperation(s.lifecycleContext); err != nil {
		return
	}
	defer s.releaseOperation()
	diagnostic := s.captureExitEvidence(containerID, exitCode)
	s.mu.Lock()
	runner := s.findRunnerByContainerLocked(containerID)
	if runner == nil {
		s.mu.Unlock()
		return
	}
	exited := *runner
	shuttingDown := s.shuttingDown
	unexpected := runner.state != runnerDraining && !shuttingDown
	delete(s.runners, runner.key)
	needsReconcile := !s.shuttingDown && s.capacityCountLocked() < s.targetSlots
	if s.capacityCountLocked() <= s.targetSlots {
		s.scaleDownAt = nil
	}
	s.mu.Unlock()
	s.onChange()

	s.diagnostics.record(diagnosticsObservation{
		subsystem: subsystemWorkerExit,
		operation: operationWorkerExit,
		target:    exited.key,
		outcome:   workerExitOutcome(unexpected, diagnostic.Classification),
		reason:    workerExitReason(unexpected, diagnostic.Classification),
		evidence:  "worker container exited with classification " + diagnostic.Classification,
	})
	s.logger.Info(
		"Runner container exited",
		"slotKey", exited.key,
		"classification", diagnostic.Classification,
		"evidence", diagnostic.Evidence,
	)
	if unexpected && diagnostic.Classification != "clean" {
		s.onError(fmt.Errorf(
			"runner container %s exited unexpectedly (%s)",
			containerID,
			diagnostic.Classification,
		))
	}
	if !shuttingDown && !exited.registrationRemoved {
		s.removeExitedRegistration(exited, diagnostic)
	}
	if needsReconcile && s.lifecycleContext.Err() == nil {
		if _, err := s.reconcileLocked(s.lifecycleContext); err != nil {
			s.onError(fmt.Errorf("restore runner target after container exit: %w", err))
		}
	}
}

// workerExitOutcome separates an expected worker retirement from a worker that
// disappeared while it was still wanted.
func workerExitOutcome(unexpected bool, classification string) string {
	if unexpected && classification != "clean" {
		return outcomeFailed
	}
	return outcomeSucceeded
}

func workerExitReason(unexpected bool, classification string) string {
	if unexpected && classification != "clean" {
		return reasonUnknown
	}
	return reasonNone
}

func (s *runnerScaler) shutdown(ctx context.Context) error {
	s.mu.Lock()
	s.shuttingDown = true
	s.scaleDownAt = nil
	s.mu.Unlock()
	s.onChange()
	if err := s.acquireOperation(ctx); err != nil {
		return fmt.Errorf("wait to shut down runner scaler: %w", err)
	}
	defer s.releaseOperation()
	s.mu.Lock()
	idle := s.idleRunnersLocked()
	s.mu.Unlock()

	var shutdownErrors []error
	shutdownErrors = append(
		shutdownErrors,
		runRunnerOperations(idle, func(runner runnerRecord) error {
			if err := registrationRemovalError(
				s.api.removeRunner(ctx, runner.runnerID),
			); err != nil {
				return fmt.Errorf(
					"remove idle runner %d during shutdown: %w",
					runner.runnerID,
					err,
				)
			}
			if err := s.docker.stopAndRemove(ctx, runner.containerID); err != nil {
				return err
			}
			s.mu.Lock()
			delete(s.runners, runner.key)
			s.mu.Unlock()
			return nil
		})...,
	)

	s.mu.Lock()
	remaining := make([]runnerRecord, 0, len(s.runners))
	for _, runner := range s.runners {
		remaining = append(remaining, *runner)
	}
	s.mu.Unlock()
	sort.Slice(remaining, func(i, j int) bool {
		return remaining[i].key < remaining[j].key
	})
	shutdownErrors = append(
		shutdownErrors,
		runRunnerOperations(remaining, func(runner runnerRecord) error {
			return s.docker.stop(ctx, runner.containerID)
		})...,
	)
	s.mu.Lock()
	clear(s.runners)
	s.mu.Unlock()
	s.admission.leave(s.target.key)
	s.onChange()
	return errors.Join(shutdownErrors...)
}

func runRunnerOperations(
	runners []runnerRecord,
	operation func(runnerRecord) error,
) []error {
	results := make([]error, len(runners))
	var waitGroup sync.WaitGroup
	waitGroup.Add(len(runners))
	for index, runner := range runners {
		index := index
		runner := runner
		go func() {
			defer waitGroup.Done()
			results[index] = operation(runner)
		}()
	}
	waitGroup.Wait()
	return results
}

func (s *runnerScaler) snapshot() scalerSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	snapshot := scalerSnapshot{
		blocking:    s.blocking,
		target:      s.target,
		scaleSetID:  s.scaleSetID,
		targetSlots: s.targetSlots,
		statistics:  s.statistics,
		retiring:    s.retiring,
	}
	if !s.retiring {
		snapshot.minimumIdleSlots = min(s.minimumIdle, s.target.maximum)
	}
	if s.scaleDownAt != nil {
		value := *s.scaleDownAt
		snapshot.scaleDownAt = &value
	}
	snapshot.runners = make([]runnerRecord, 0, len(s.runners))
	for _, runner := range s.runners {
		snapshot.runners = append(snapshot.runners, *runner)
		if runner.stale {
			snapshot.staleRunners++
		}
		switch runner.state {
		case runnerIdle:
			snapshot.idleRunners++
		case runnerBusy:
			snapshot.busyRunners++
		case runnerDraining, runnerCleanupPending:
			snapshot.drainingRunners++
		}
	}
	snapshot.activeRunners = s.capacityCountLocked()
	snapshot.pendingCleanups = s.pendingRegistrationsLocked()
	sort.Slice(snapshot.runners, func(i, j int) bool {
		return snapshot.runners[i].key < snapshot.runners[j].key
	})
	return snapshot
}

func (s *runnerScaler) capacityCountLocked() int {
	count := 0
	for _, runner := range s.runners {
		if runner.state != runnerCleanupPending && runner.state != runnerDraining {
			count++
		}
	}
	return count
}

func (s *runnerScaler) oldestIdleRunnerLocked() *runnerRecord {
	idle := s.idleRunnersLocked()
	if len(idle) == 0 {
		return nil
	}
	return s.runners[idle[0].key]
}

func (s *runnerScaler) oldestProtectedRecoveredRunnerLocked() *runnerRecord {
	protected := make([]runnerRecord, 0)
	for _, runner := range s.runners {
		if runner.recovered &&
			runner.protected &&
			runner.state == runnerStarting &&
			!runner.registrationRemoved {
			protected = append(protected, *runner)
		}
	}
	if len(protected) == 0 {
		return nil
	}
	sort.Slice(protected, func(i, j int) bool {
		if protected[i].startedAt.Equal(protected[j].startedAt) {
			return protected[i].key < protected[j].key
		}
		return protected[i].startedAt.Before(protected[j].startedAt)
	})
	return s.runners[protected[0].key]
}

func (s *runnerScaler) idleRunnersLocked() []runnerRecord {
	idle := make([]runnerRecord, 0)
	for _, runner := range s.runners {
		if runner.state == runnerIdle && !runner.protected {
			idle = append(idle, *runner)
		}
	}
	sort.Slice(idle, func(i, j int) bool {
		left := idle[i].startedAt
		right := idle[j].startedAt
		if idle[i].idleSince != nil {
			left = *idle[i].idleSince
		}
		if idle[j].idleSince != nil {
			right = *idle[j].idleSince
		}
		if left.Equal(right) {
			return idle[i].key < idle[j].key
		}
		return left.Before(right)
	})
	return idle
}

func (s *runnerScaler) findRunnerLocked(name string, runnerID int64) *runnerRecord {
	for _, runner := range s.runners {
		if runnerID > 0 && runner.runnerID == runnerID {
			return runner
		}
		if name != "" && runner.runnerName == name {
			return runner
		}
	}
	return nil
}

func (s *runnerScaler) findRunnerByContainerLocked(containerID string) *runnerRecord {
	for _, runner := range s.runners {
		if runner.containerID == containerID {
			return runner
		}
	}
	return nil
}

func (s *runnerScaler) hasRunner(containerID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.findRunnerByContainerLocked(containerID) != nil
}

func (s *runnerScaler) capacityCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.capacityCountLocked()
}

func (s *runnerScaler) runnerCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.runners)
}

func (s *runnerScaler) nextRunnerName() (string, error) {
	suffix, err := s.nameSuffix()
	if err != nil {
		return "", fmt.Errorf("generate runner name suffix: %w", err)
	}
	prefix := sanitizeIdentifier(s.namePrefix, 30)
	if prefix == "" {
		prefix = "runner"
	}
	target := sanitizeIdentifier(s.target.key, 16)
	return fmt.Sprintf("%s-%s-%s", prefix, target, suffix), nil
}

func randomSuffix() (string, error) {
	random := make([]byte, 4)
	if _, err := rand.Read(random); err != nil {
		return "", err
	}
	return hex.EncodeToString(random), nil
}

func timePointer(value time.Time) *time.Time {
	return &value
}

var _ listener.Scaler = (*runnerScaler)(nil)
var _ listener.MetricsRecorder = (*runnerScaler)(nil)
