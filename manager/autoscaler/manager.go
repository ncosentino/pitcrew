package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"sort"
	"sync"
	"time"
)

const managerShutdownTimeout = 50 * time.Second

type autoscalerManager struct {
	cfg        config
	paths      statePaths
	factory    scaleSetServiceFactory
	docker     dockerClient
	clock      clock
	logger     *slog.Logger
	instanceID string

	controllers          map[string]*targetController
	retiring             map[string]*targetController
	pending              map[string]pendingScaleSet
	recovered            map[string][]recoveredContainer
	retirementRecords    map[string]retirementRecord
	retirementGeneration int
	current              *parsedDesiredState
	applied              *parsedDesiredState
	ackPrevious          desiredState
	ackPending           bool

	managerStatus     string
	desiredStatus     string
	lastDocumentHash  string
	lastError         error
	observedError     error
	latestResources   resourceSample
	resourcesSampled  bool
	resourcesAt       time.Time
	resourceInventory string

	dirty                 chan struct{}
	errors                chan error
	listenerFailureSignal chan struct{}
	listenerFailureMu     sync.Mutex
	listenerFailureState  map[string]error
	restarts              map[string]restartState
	shutdownMu            sync.Mutex
	shutdownTimeout       time.Duration
	writeObserved         func(string, any) error
}

type pendingScaleSet struct {
	handle scaleSetHandle
	api    scaleSetService
}

type restartState struct {
	at       time.Time
	attempts int
}

func newAutoscalerManager(
	cfg config,
	factory scaleSetServiceFactory,
	docker dockerClient,
	managerClock clock,
	logger *slog.Logger,
	instanceID string,
) *autoscalerManager {
	return &autoscalerManager{
		cfg:                   cfg,
		paths:                 newStatePaths(cfg.stateDirectory),
		factory:               boundScaleSetServiceFactory(factory),
		docker:                boundDockerClient(docker),
		clock:                 managerClock,
		logger:                logger,
		instanceID:            instanceID,
		controllers:           make(map[string]*targetController),
		retiring:              make(map[string]*targetController),
		pending:               make(map[string]pendingScaleSet),
		recovered:             make(map[string][]recoveredContainer),
		retirementRecords:     make(map[string]retirementRecord),
		managerStatus:         "starting",
		desiredStatus:         "waiting",
		dirty:                 make(chan struct{}, 1),
		errors:                make(chan error, 128),
		listenerFailureSignal: make(chan struct{}, 1),
		listenerFailureState:  make(map[string]error),
		restarts:              make(map[string]restartState),
		shutdownTimeout:       managerShutdownTimeout,
		writeObserved:         writeJSONAtomically,
	}
}

func (m *autoscalerManager) run(ctx context.Context) error {
	if err := os.MkdirAll(m.cfg.stateDirectory, 0o755); err != nil {
		return fmt.Errorf("create autoscaler state directory: %w", err)
	}
	if _, err := bootstrapLegacyDesiredState(m.cfg, m.paths); err != nil {
		return err
	}
	if err := m.scanRecovered(ctx); err != nil {
		return err
	}
	if err := m.restoreLastValid(); err != nil {
		return err
	}
	if err := m.loadRetirements(); err != nil {
		return err
	}
	m.runReconciliationCycle(ctx)
	m.managerStatus = "running"
	m.tryPublishObserved()

	desiredTicker := time.NewTicker(time.Second)
	observedTicker := time.NewTicker(m.cfg.observedInterval)
	defer desiredTicker.Stop()
	defer observedTicker.Stop()

	for {
		select {
		case <-ctx.Done():
			return m.shutdown()
		case <-m.listenerFailureSignal:
			m.processListenerFailures()
			m.tryPublishObserved()
		case err := <-m.errors:
			m.lastError = err
			m.logger.Error("Autoscaler operation failed", "error", err)
			m.tryPublishObserved()
		case <-m.dirty:
			m.tryPublishObserved()
		case <-desiredTicker.C:
			m.runReconciliationCycle(ctx)
		case <-observedTicker.C:
			m.tryPublishObserved()
		}
	}
}

func (m *autoscalerManager) runReconciliationCycle(ctx context.Context) {
	cycleSucceeded := true
	if m.processListenerFailures() {
		cycleSucceeded = false
	}
	if err := m.processDesired(ctx); err != nil {
		cycleSucceeded = false
		m.recordCycleError("Desired-capacity reconciliation failed", err)
	}
	if m.current != nil {
		if err := m.ensureRetirementStateCurrent(); err != nil {
			cycleSucceeded = false
			m.recordCycleError("Retirement state persistence failed", err)
		}
		if err := m.reconcileDesiredTargets(ctx); err != nil {
			cycleSucceeded = false
			m.recordCycleError("Desired target reconciliation failed", err)
		}
		if err := m.reconcileRetirements(ctx); err != nil {
			cycleSucceeded = false
			m.recordCycleError("Retiring target reconciliation failed", err)
		}
	}
	if m.processListenerFailures() {
		cycleSucceeded = false
	}
	if m.detectStoppedListeners() {
		cycleSucceeded = false
	}
	if err := m.restartFailedListeners(ctx); err != nil {
		cycleSucceeded = false
		m.recordCycleError("Listener restart failed", err)
	}
	if m.processListenerFailures() {
		cycleSucceeded = false
	}
	if m.detectStoppedListeners() {
		cycleSucceeded = false
	}
	if m.current != nil {
		if m.currentConfigurationCoherent() {
			applied := *m.current
			m.applied = &applied
		}
		if err := m.publishAcknowledgement(); err != nil {
			cycleSucceeded = false
			m.recordCycleError("Capacity acknowledgement failed", err)
		}
	}
	if cycleSucceeded && len(m.restarts) == 0 {
		m.lastError = nil
	}
	m.tryPublishObserved()
}

func (m *autoscalerManager) recordCycleError(message string, err error) {
	m.lastError = err
	m.logger.Error(message, "error", err)
}

func (m *autoscalerManager) scanRecovered(ctx context.Context) error {
	containers, err := m.docker.listManaged(ctx, m.cfg.profileID)
	if err != nil {
		return err
	}
	m.recovered = make(map[string][]recoveredContainer)
	for _, container := range containers {
		m.recovered[container.targetKey] = append(
			m.recovered[container.targetKey],
			container,
		)
	}
	return nil
}

func (m *autoscalerManager) restoreLastValid() error {
	data, exists, err := readOptionalFile(m.paths.lastValid)
	if err != nil {
		return err
	}
	if !exists {
		return nil
	}
	parsed, err := parseDesiredState(data, m.cfg.scope)
	if err != nil {
		return fmt.Errorf("persisted last-valid-capacity.json is invalid: %w", err)
	}
	m.current = &parsed
	m.applied = &parsed
	m.ackPrevious = parsed.state
	m.ackPending = true
	m.desiredStatus = "accepted"
	return nil
}

func (m *autoscalerManager) loadRetirements() error {
	data, exists, err := readOptionalFile(m.paths.retirements)
	if err != nil {
		return err
	}
	if !exists {
		return nil
	}
	document, err := parseRetirementDocument(data)
	if err != nil {
		return err
	}
	m.retirementGeneration = document.Generation
	for _, record := range document.Targets {
		m.retirementRecords[record.Key] = record
	}
	return nil
}

func (m *autoscalerManager) processDesired(ctx context.Context) error {
	data, exists, err := readOptionalFile(m.paths.desired)
	if err != nil {
		return err
	}
	if !exists {
		changed := m.lastDocumentHash != ""
		m.lastDocumentHash = ""
		if m.current == nil {
			m.desiredStatus = "waiting"
		} else {
			m.desiredStatus = "accepted"
		}
		if changed {
			m.markDirty()
		}
		return nil
	}
	documentDigest := sha256.Sum256(data)
	documentHash := hex.EncodeToString(documentDigest[:])
	if documentHash == m.lastDocumentHash {
		return nil
	}

	currentGeneration := 0
	currentHash := ""
	if m.current != nil {
		currentGeneration = m.current.state.Generation
		currentHash = m.current.stateHash
	}
	classification, parsed, classificationErr := classifyDesiredState(
		data,
		m.cfg.scope,
		currentGeneration,
		currentHash,
	)
	switch classification {
	case classificationInvalid:
		m.lastDocumentHash = documentHash
		m.desiredStatus = "invalid"
		m.markDirty()
		return fmt.Errorf("reject invalid desired-capacity document: %w", classificationErr)
	case classificationStale:
		m.lastDocumentHash = documentHash
		m.desiredStatus = "stale"
		m.markDirty()
		return fmt.Errorf(
			"reject stale desired-capacity generation %d; current generation is %d",
			parsed.state.Generation,
			currentGeneration,
		)
	case classificationConflict:
		m.lastDocumentHash = documentHash
		m.desiredStatus = "conflict"
		m.markDirty()
		return fmt.Errorf(
			"reject conflicting desired-capacity generation %d",
			parsed.state.Generation,
		)
	case classificationUnchanged:
		m.lastDocumentHash = documentHash
		m.desiredStatus = "accepted"
		return nil
	case classificationNew:
		return m.acceptDesiredTransition(ctx, parsed, documentHash)
	default:
		return fmt.Errorf("unsupported desired-capacity classification %q", classification)
	}
}

func (m *autoscalerManager) acceptDesiredTransition(
	_ context.Context,
	parsed parsedDesiredState,
	documentHash string,
) error {
	previous := desiredState{}
	if m.current != nil {
		previous = m.current.state
	}
	previousApplied := previous
	if m.applied != nil {
		previousApplied = m.applied.state
	} else if m.current != nil {
		applied := *m.current
		m.applied = &applied
	}
	records, err := m.recordsWithNewRetirements(previous, parsed.state)
	if err != nil {
		return err
	}
	if err := m.persistRetirements(parsed.state.Generation, records); err != nil {
		return fmt.Errorf("persist retirement intent: %w", err)
	}
	if err := writeBytesAtomically(m.paths.lastValid, parsed.raw, 0o644); err != nil {
		return fmt.Errorf("persist last-valid capacity: %w", err)
	}

	m.current = &parsed
	m.ackPrevious = previousApplied
	m.ackPending = true
	m.desiredStatus = "accepted"
	m.lastDocumentHash = documentHash
	if err := m.ensureRetirementStateCurrent(); err != nil {
		return err
	}
	m.markDirty()
	return nil
}

func (m *autoscalerManager) recordsWithNewRetirements(
	previous desiredState,
	next desiredState,
) (map[string]retirementRecord, error) {
	records := cloneRetirementRecords(m.retirementRecords)
	previousTargets, err := buildTargetSpecs(previous, m.cfg)
	if previous.Scope == "" {
		previousTargets = nil
		err = nil
	}
	if err != nil {
		return nil, err
	}
	nextTargets, err := buildTargetSpecs(next, m.cfg)
	if err != nil {
		return nil, err
	}
	nextKeys := make(map[string]struct{}, len(nextTargets))
	for _, target := range nextTargets {
		nextKeys[target.key] = struct{}{}
	}
	for _, target := range previousTargets {
		if _, desired := nextKeys[target.key]; desired {
			continue
		}
		if _, exists := records[target.key]; !exists {
			records[target.key] = retirementRecordFor(
				target,
				next.Generation,
			)
		}
	}
	return records, nil
}

func (m *autoscalerManager) ensureRetirementStateCurrent() error {
	if m.current == nil {
		return nil
	}
	desiredTargets, err := buildTargetSpecs(m.current.state, m.cfg)
	if err != nil {
		return err
	}
	records := cloneRetirementRecords(m.retirementRecords)
	for _, target := range desiredTargets {
		delete(records, target.key)
	}
	if m.retirementGeneration >= m.current.state.Generation &&
		len(records) == len(m.retirementRecords) {
		return nil
	}
	return m.persistRetirements(m.current.state.Generation, records)
}

func (m *autoscalerManager) persistRetirements(
	generation int,
	records map[string]retirementRecord,
) error {
	document := newRetirementDocument(generation, records)
	if err := writeJSONAtomically(m.paths.retirements, document); err != nil {
		return err
	}
	m.retirementRecords = cloneRetirementRecords(records)
	m.retirementGeneration = generation
	return nil
}

func cloneRetirementRecords(
	records map[string]retirementRecord,
) map[string]retirementRecord {
	cloned := make(map[string]retirementRecord, len(records))
	for key, record := range records {
		cloned[key] = record
	}
	return cloned
}

func (m *autoscalerManager) reconcileDesiredTargets(ctx context.Context) error {
	if m.current == nil {
		return nil
	}
	targets, err := buildTargetSpecs(m.current.state, m.cfg)
	if err != nil {
		return err
	}
	desired := make(map[string]targetSpec, len(targets))
	var targetErrors []error
	for _, target := range targets {
		desired[target.key] = target
		if controller := m.retiring[target.key]; controller != nil {
			if controller.closed() {
				delete(m.retiring, target.key)
				if err := m.startDesiredController(ctx, target); err != nil {
					targetErrors = append(targetErrors, err)
				}
				continue
			}
			if err := controller.reactivate(ctx, m.cfg, target); err != nil {
				targetErrors = append(targetErrors, fmt.Errorf(
					"reactivate target %s: %w",
					target.key,
					err,
				))
				continue
			}
			m.controllers[target.key] = controller
			delete(m.retiring, target.key)
			continue
		}
		if controller := m.controllers[target.key]; controller != nil {
			if !controller.matches(target) {
				if err := controller.update(ctx, m.cfg, target); err != nil {
					targetErrors = append(targetErrors, fmt.Errorf(
						"update target %s: %w",
						target.key,
						err,
					))
				}
			}
			continue
		}
		if err := m.startDesiredController(ctx, target); err != nil {
			targetErrors = append(targetErrors, err)
		}
	}

	for key, controller := range m.controllers {
		if _, exists := desired[key]; exists {
			continue
		}
		if _, durable := m.retirementRecords[key]; !durable {
			targetErrors = append(targetErrors, fmt.Errorf(
				"target %s cannot retire without durable intent",
				key,
			))
			continue
		}
		delete(m.controllers, key)
		m.retiring[key] = controller
		if err := controller.beginRetirement(ctx); err != nil {
			targetErrors = append(targetErrors, fmt.Errorf(
				"begin retirement for target %s: %w",
				key,
				err,
			))
		}
	}
	for key := range m.pending {
		if _, exists := desired[key]; !exists {
			delete(m.pending, key)
		}
	}
	return errors.Join(targetErrors...)
}

func (m *autoscalerManager) startDesiredController(
	ctx context.Context,
	target targetSpec,
) error {
	pending, exists := m.pending[target.key]
	if !exists {
		api, err := m.factory.newService(target.registrationURL)
		if err != nil {
			return fmt.Errorf("create service for target %s: %w", target.key, err)
		}
		pending = pendingScaleSet{api: api}
	}
	handle, err := pending.api.ensureScaleSet(
		ctx,
		target.scaleSetName,
		m.cfg.runnerGroup,
		effectiveLabels(m.cfg),
	)
	if err != nil {
		return fmt.Errorf("ensure scale set for target %s: %w", target.key, err)
	}
	pending.handle = handle
	m.pending[target.key] = pending
	controller, err := startTargetController(
		ctx,
		m.cfg,
		target,
		pending.api,
		handle,
		m.docker,
		m.clock,
		m.instanceID,
		m.recovered[target.key],
		m.logger,
		m.markDirty,
		m.reportError,
		m.reportListenerFailure,
	)
	if err != nil {
		return fmt.Errorf("start target %s: %w", target.key, err)
	}
	m.controllers[target.key] = controller
	delete(m.pending, target.key)
	delete(m.recovered, target.key)
	return nil
}

func (m *autoscalerManager) reconcileRetirements(ctx context.Context) error {
	if m.current == nil {
		return nil
	}
	desiredTargets, err := buildTargetSpecs(m.current.state, m.cfg)
	if err != nil {
		return err
	}
	desired := make(map[string]struct{}, len(desiredTargets))
	for _, target := range desiredTargets {
		desired[target.key] = struct{}{}
	}
	var retirementErrors []error
	keys := make([]string, 0, len(m.retirementRecords))
	for key, record := range m.retirementRecords {
		if record.RetireAtGeneration <= m.current.state.Generation {
			if _, readded := desired[key]; !readded {
				keys = append(keys, key)
			}
		}
	}
	sort.Strings(keys)
	for _, key := range keys {
		record := m.retirementRecords[key]
		controller := m.retiring[key]
		if controller == nil {
			controller, err = m.startRetiringController(ctx, record)
			if err != nil {
				retirementErrors = append(retirementErrors, err)
				continue
			}
			if controller == nil {
				records := cloneRetirementRecords(m.retirementRecords)
				delete(records, key)
				if err := m.persistRetirements(
					m.current.state.Generation,
					records,
				); err != nil {
					retirementErrors = append(retirementErrors, fmt.Errorf(
						"persist completed retirement %s: %w",
						key,
						err,
					))
					continue
				}
				delete(m.restarts, key)
				continue
			}
			m.retiring[key] = controller
			delete(m.recovered, key)
		}
		if err := controller.beginRetirement(ctx); err != nil {
			retirementErrors = append(retirementErrors, fmt.Errorf(
				"reconcile retiring target %s: %w",
				key,
				err,
			))
			continue
		}
		if controller.runnerCount() != 0 {
			continue
		}
		if err := controller.closeSession(ctx); err != nil {
			retirementErrors = append(retirementErrors, err)
			continue
		}
		handle, exists, err := controller.api.findScaleSet(
			ctx,
			record.ScaleSetName,
			m.cfg.runnerGroup,
		)
		if err != nil {
			retirementErrors = append(retirementErrors, err)
			continue
		}
		if exists {
			if err := controller.api.deleteScaleSet(ctx, handle.id); err != nil {
				retirementErrors = append(retirementErrors, fmt.Errorf(
					"delete retired scale set %s: %w",
					key,
					err,
				))
				continue
			}
		}
		records := cloneRetirementRecords(m.retirementRecords)
		delete(records, key)
		if err := m.persistRetirements(m.current.state.Generation, records); err != nil {
			retirementErrors = append(retirementErrors, fmt.Errorf(
				"persist completed retirement %s: %w",
				key,
				err,
			))
			continue
		}
		delete(m.retiring, key)
		delete(m.restarts, key)
	}
	return errors.Join(retirementErrors...)
}

func (m *autoscalerManager) startRetiringController(
	ctx context.Context,
	record retirementRecord,
) (*targetController, error) {
	target := record.targetSpec()
	api, err := m.factory.newService(target.registrationURL)
	if err != nil {
		return nil, fmt.Errorf("create service for retiring target %s: %w", target.key, err)
	}
	existing, exists, err := api.findScaleSet(
		ctx,
		target.scaleSetName,
		m.cfg.runnerGroup,
	)
	if err != nil {
		return nil, fmt.Errorf("find retiring scale set %s: %w", target.key, err)
	}
	if !exists {
		if len(m.recovered[target.key]) != 0 {
			return nil, fmt.Errorf(
				"retiring target %s has recovered containers but no scale set",
				target.key,
			)
		}
		return nil, nil
	}
	target.maximum = 0
	controller, err := startTargetController(
		ctx,
		m.cfg,
		target,
		api,
		existing,
		m.docker,
		m.clock,
		m.instanceID,
		m.recovered[target.key],
		m.logger,
		m.markDirty,
		m.reportError,
		m.reportListenerFailure,
	)
	if err != nil {
		return nil, fmt.Errorf("start retiring target %s: %w", target.key, err)
	}
	return controller, nil
}

func (m *autoscalerManager) publishAcknowledgement() error {
	if !m.ackPending || m.current == nil {
		return nil
	}
	if !m.currentConfigurationCoherent() {
		return fmt.Errorf(
			"desired generation %d is durably accepted but not yet applied",
			m.current.state.Generation,
		)
	}
	if m.retirementGeneration < m.current.state.Generation {
		return fmt.Errorf(
			"retirement intent generation %d has not reached desired generation %d",
			m.retirementGeneration,
			m.current.state.Generation,
		)
	}
	desiredTargets, err := buildTargetSpecs(m.current.state, m.cfg)
	if err != nil {
		return err
	}
	for _, target := range desiredTargets {
		if _, retiring := m.retirementRecords[target.key]; retiring {
			return fmt.Errorf(
				"desired target %s still has a retirement record",
				target.key,
			)
		}
	}
	ack := buildAcknowledgement(
		*m.current,
		m.ackPrevious,
		m.activeRunnerCount(),
		m.aggregateMinimumIdle(),
		m.clock.now(),
	)
	if err := writeJSONAtomically(m.paths.acknowledgement, ack); err != nil {
		return err
	}
	m.ackPending = false
	return nil
}

func (m *autoscalerManager) currentConfigurationCoherent() bool {
	if m.current == nil {
		return false
	}
	targets, err := buildTargetSpecs(m.current.state, m.cfg)
	if err != nil {
		return false
	}
	if len(m.controllers) != len(targets) {
		return false
	}
	desired := make(map[string]struct{}, len(targets))
	for _, target := range targets {
		desired[target.key] = struct{}{}
		controller := m.controllers[target.key]
		if controller == nil ||
			m.retiring[target.key] != nil {
			return false
		}
		if _, pending := m.pending[target.key]; pending {
			return false
		}
		if _, restarting := m.restarts[target.key]; restarting ||
			m.listenerFailurePending(target.key) ||
			controller.closed() ||
			controller.listenerStopped() {
			return false
		}
		snapshot := controller.snapshot()
		if snapshot.retiring ||
			snapshot.target.key != target.key ||
			snapshot.target.maximum != target.maximum ||
			snapshot.targetSlots > target.maximum {
			return false
		}
	}
	for key := range m.controllers {
		if _, exists := desired[key]; !exists {
			return false
		}
	}
	return true
}

func (m *autoscalerManager) tryPublishObserved() {
	m.observedError = nil
	if err := m.publishObserved(); err != nil {
		m.observedError = err
		m.logger.Error("Observed-state publication failed; retrying", "error", err)
		return
	}
}

func (m *autoscalerManager) publishObserved() error {
	snapshots := m.snapshots()
	resourceSample := m.sampleResourceTelemetry(snapshots)
	observedCurrent := m.applied
	if observedCurrent == nil {
		observedCurrent = m.current
	}
	state := buildObservedState(
		m.cfg,
		m.instanceID,
		m.managerStatus,
		observedCurrent,
		m.desiredStatus,
		snapshots,
		errors.Join(m.lastError, m.observedError),
		m.clock.now(),
	)
	state.Autoscaling.ScaleSetCount += len(m.pending)
	desiredKeys := m.desiredTargetKeys(observedCurrent)
	for targetKey, containers := range m.recovered {
		_, desired := desiredKeys[targetKey]
		_, retiring := m.retirementRecords[targetKey]
		for _, container := range containers {
			updated := container.createdAt
			if updated.IsZero() {
				updated = m.clock.now()
			}
			updatedAt := updated.UTC().Format(time.RFC3339)
			state.ActiveSlots++
			if retiring || !desired {
				state.DrainingSlots++
			}
			slotState := "starting"
			if retiring || !desired {
				slotState = "draining"
			}
			state.Slots = append(state.Slots, observedSlot{
				Key:            container.slotKey,
				Repository:     nil,
				Desired:        desired && !retiring,
				ProcessRunning: true,
				State:          slotState,
				FailureCount:   0,
				BackoffSeconds: 0,
				UpdatedAt:      &updatedAt,
				Resources:      nil,
				Activity:       "unknown",
				Target:         container.targetKey,
			})
		}
	}
	applyResourceSample(&state, resourceSample)
	sort.Slice(state.Slots, func(i, j int) bool {
		return state.Slots[i].Key < state.Slots[j].Key
	})
	if err := m.writeObserved(m.paths.observed, state); err != nil {
		return fmt.Errorf("publish observed state: %w", err)
	}
	return nil
}

func (m *autoscalerManager) sampleResourceTelemetry(
	snapshots []scalerSnapshot,
) resourceSample {
	now := m.clock.now().UTC()
	if m.managerStatus == "stopping" || m.managerStatus == "stopped" {
		if m.resourcesSampled {
			return m.latestResources
		}
		return unavailableResourceSample(now)
	}
	containers := m.resourceContainers(snapshots)
	inventory := resourceInventoryFingerprint(containers)
	sampleDue := !m.resourcesSampled ||
		inventory != m.resourceInventory ||
		now.Before(m.resourcesAt) ||
		now.Sub(m.resourcesAt) >= m.cfg.observedInterval
	if sampleDue {
		m.latestResources = m.docker.sampleResources(
			context.Background(),
			m.cfg.profileID,
			containers,
			now,
		)
		m.resourcesSampled = true
		m.resourcesAt = now
		m.resourceInventory = inventory
	}
	return m.latestResources
}

func (m *autoscalerManager) resourceContainers(
	snapshots []scalerSnapshot,
) []resourceContainer {
	containers := make(map[string]resourceContainer)
	for _, snapshot := range snapshots {
		for _, runner := range snapshot.runners {
			if runner.containerID == "" || runner.key == "" {
				continue
			}
			containers[runner.containerID] = resourceContainer{
				containerID:   runner.containerID,
				containerName: runner.container,
				slotKey:       runner.key,
			}
		}
	}
	for _, recovered := range m.recovered {
		for _, container := range recovered {
			if container.containerID == "" || container.slotKey == "" {
				continue
			}
			containers[container.containerID] = resourceContainer{
				containerID:   container.containerID,
				containerName: container.name,
				slotKey:       container.slotKey,
			}
		}
	}
	result := make([]resourceContainer, 0, len(containers))
	for _, container := range containers {
		result = append(result, container)
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].containerID == result[j].containerID {
			return result[i].slotKey < result[j].slotKey
		}
		return result[i].containerID < result[j].containerID
	})
	return result
}

func resourceInventoryFingerprint(containers []resourceContainer) string {
	digest := sha256.New()
	for _, container := range containers {
		_, _ = fmt.Fprintf(
			digest,
			"%s\x00%s\x00%s\n",
			container.containerID,
			container.containerName,
			container.slotKey,
		)
	}
	return hex.EncodeToString(digest.Sum(nil))
}

func (m *autoscalerManager) desiredTargetKeys(
	current *parsedDesiredState,
) map[string]struct{} {
	keys := make(map[string]struct{})
	if current == nil {
		return keys
	}
	targets, err := buildTargetSpecs(current.state, m.cfg)
	if err != nil {
		return keys
	}
	for _, target := range targets {
		keys[target.key] = struct{}{}
	}
	return keys
}

func (m *autoscalerManager) snapshots() []scalerSnapshot {
	keys := make([]string, 0, len(m.controllers)+len(m.retiring))
	for key := range m.controllers {
		keys = append(keys, key)
	}
	for key := range m.retiring {
		if _, active := m.controllers[key]; !active {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	snapshots := make([]scalerSnapshot, 0, len(keys))
	for _, key := range keys {
		if controller := m.controllers[key]; controller != nil {
			snapshots = append(snapshots, controller.snapshot())
		} else if controller := m.retiring[key]; controller != nil {
			snapshots = append(snapshots, controller.snapshot())
		}
	}
	return snapshots
}

func (m *autoscalerManager) aggregateMinimumIdle() int {
	if m.current == nil {
		return 0
	}
	total := 0
	switch m.current.state.Scope {
	case "repo":
		for _, repository := range m.current.state.Repositories {
			total += min(m.cfg.minimumIdle, repository.Workers)
		}
	default:
		if m.current.state.Replicas != nil {
			total = min(m.cfg.minimumIdle, *m.current.state.Replicas)
		}
	}
	return total
}

func (m *autoscalerManager) activeRunnerCount() int {
	total := 0
	for _, snapshot := range m.snapshots() {
		total += len(snapshot.runners)
	}
	for _, containers := range m.recovered {
		total += len(containers)
	}
	return total
}

func (m *autoscalerManager) reportError(err error) {
	if err == nil {
		return
	}
	select {
	case m.errors <- err:
	default:
		m.logger.Error("Autoscaler error queue is full", "error", err)
	}
}

func (m *autoscalerManager) reportListenerFailure(key string, err error) {
	if err == nil {
		return
	}
	m.listenerFailureMu.Lock()
	m.listenerFailureState[key] = errors.Join(
		m.listenerFailureState[key],
		err,
	)
	m.listenerFailureMu.Unlock()
	select {
	case m.listenerFailureSignal <- struct{}{}:
	default:
	}
}

func (m *autoscalerManager) processListenerFailures() bool {
	m.listenerFailureMu.Lock()
	failures := m.listenerFailureState
	m.listenerFailureState = make(map[string]error)
	m.listenerFailureMu.Unlock()
	keys := make([]string, 0, len(failures))
	for key := range failures {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		err := failures[key]
		m.lastError = err
		m.logger.Error(
			"Scale-set listener failed; restart scheduled",
			"targetKey", key,
			"error", err,
		)
		m.scheduleRestart(key)
	}
	return len(keys) > 0
}

func (m *autoscalerManager) listenerFailurePending(key string) bool {
	m.listenerFailureMu.Lock()
	defer m.listenerFailureMu.Unlock()
	_, exists := m.listenerFailureState[key]
	return exists
}

func (m *autoscalerManager) detectStoppedListeners() bool {
	controllers := make(map[string]*targetController)
	for key, controller := range m.controllers {
		controllers[key] = controller
	}
	for key, controller := range m.retiring {
		if controllers[key] == nil {
			controllers[key] = controller
		}
	}
	keys := make([]string, 0, len(controllers))
	for key := range controllers {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	detected := false
	for _, key := range keys {
		if !controllers[key].listenerStopped() ||
			m.listenerFailurePending(key) {
			continue
		}
		if _, scheduled := m.restarts[key]; scheduled {
			continue
		}
		err := fmt.Errorf("scale-set listener for %s is stopped", key)
		m.lastError = err
		m.logger.Error(
			"Stopped scale-set listener detected; restart scheduled",
			"targetKey", key,
		)
		m.scheduleRestart(key)
		detected = true
	}
	return detected
}

func (m *autoscalerManager) scheduleRestart(key string) {
	state := m.restarts[key]
	state.attempts++
	delay := time.Second << min(state.attempts-1, 5)
	if delay > 30*time.Second {
		delay = 30 * time.Second
	}
	state.at = m.clock.now().Add(delay)
	m.restarts[key] = state
}

func (m *autoscalerManager) restartFailedListeners(ctx context.Context) error {
	now := m.clock.now()
	keys := make([]string, 0, len(m.restarts))
	for key, state := range m.restarts {
		if !now.Before(state.at) {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	var restartErrors []error
	for _, key := range keys {
		controller := m.controllers[key]
		if controller == nil {
			controller = m.retiring[key]
		}
		if controller == nil {
			delete(m.restarts, key)
			continue
		}
		if err := controller.restartListener(ctx); err != nil {
			restartErrors = append(restartErrors, fmt.Errorf(
				"restart listener for %s: %w",
				key,
				err,
			))
			m.scheduleRestart(key)
			continue
		}
		delete(m.restarts, key)
	}
	return errors.Join(restartErrors...)
}

func (m *autoscalerManager) markDirty() {
	select {
	case m.dirty <- struct{}{}:
	default:
	}
}

func runControllerOperations(
	keys []string,
	controllers map[string]*targetController,
	operation func(*targetController) error,
) []error {
	results := make([]error, len(keys))
	var waitGroup sync.WaitGroup
	waitGroup.Add(len(keys))
	for index, key := range keys {
		index := index
		controller := controllers[key]
		go func() {
			defer waitGroup.Done()
			results[index] = operation(controller)
		}()
	}
	waitGroup.Wait()
	return results
}

func runRecoveredContainerStops(
	containers []recoveredContainer,
	operation func(recoveredContainer) error,
) []error {
	results := make([]error, len(containers))
	var waitGroup sync.WaitGroup
	waitGroup.Add(len(containers))
	for index, container := range containers {
		index := index
		container := container
		go func() {
			defer waitGroup.Done()
			results[index] = operation(container)
		}()
	}
	waitGroup.Wait()
	return results
}

func (m *autoscalerManager) shutdown() error {
	m.shutdownMu.Lock()
	defer m.shutdownMu.Unlock()
	m.managerStatus = "stopping"
	var shutdownErrors []error
	if err := m.publishObserved(); err != nil {
		shutdownErrors = append(shutdownErrors, err)
	}

	allControllers := make(map[string]*targetController)
	for key, controller := range m.controllers {
		allControllers[key] = controller
	}
	for key, controller := range m.retiring {
		allControllers[key] = controller
	}
	keys := make([]string, 0, len(allControllers))
	for key := range allControllers {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	shutdownContext, cancel := context.WithTimeout(
		context.Background(),
		m.shutdownTimeout,
	)
	defer cancel()

	shutdownErrors = append(
		shutdownErrors,
		runControllerOperations(keys, allControllers, func(
			controller *targetController,
		) error {
			return controller.closeSession(shutdownContext)
		})...,
	)
	shutdownErrors = append(
		shutdownErrors,
		runControllerOperations(keys, allControllers, func(
			controller *targetController,
		) error {
			return controller.cleanupRunners(shutdownContext)
		})...,
	)
	remaining, err := m.docker.listManaged(shutdownContext, m.cfg.profileID)
	if err != nil {
		shutdownErrors = append(shutdownErrors, err)
	} else {
		stopErrors := runRecoveredContainerStops(
			remaining,
			func(container recoveredContainer) error {
				return m.docker.stop(shutdownContext, container.containerID)
			},
		)
		failedRemaining := make(map[string][]recoveredContainer)
		for index, err := range stopErrors {
			if err == nil {
				continue
			}
			shutdownErrors = append(shutdownErrors, err)
			container := remaining[index]
			failedRemaining[container.targetKey] = append(
				failedRemaining[container.targetKey],
				container,
			)
		}
		m.recovered = failedRemaining
	}
	for _, key := range keys {
		controller := allControllers[key]
		handle, exists, err := controller.api.findScaleSet(
			shutdownContext,
			controller.target.scaleSetName,
			m.cfg.runnerGroup,
		)
		if err != nil {
			shutdownErrors = append(shutdownErrors, err)
			continue
		}
		if exists {
			if err := controller.api.deleteScaleSet(shutdownContext, handle.id); err != nil {
				shutdownErrors = append(shutdownErrors, err)
			}
		}
	}
	handledScaleSets := make(map[string]struct{}, len(allControllers)+len(m.pending))
	for key := range allControllers {
		handledScaleSets[key] = struct{}{}
	}
	pendingKeys := make([]string, 0, len(m.pending))
	for key := range m.pending {
		pendingKeys = append(pendingKeys, key)
	}
	sort.Strings(pendingKeys)
	for _, key := range pendingKeys {
		pending := m.pending[key]
		if err := pending.api.deleteScaleSet(shutdownContext, pending.handle.id); err != nil {
			shutdownErrors = append(shutdownErrors, err)
		}
		handledScaleSets[key] = struct{}{}
	}
	retirementKeys := make([]string, 0, len(m.retirementRecords))
	for key := range m.retirementRecords {
		if _, handled := handledScaleSets[key]; !handled {
			retirementKeys = append(retirementKeys, key)
		}
	}
	sort.Strings(retirementKeys)
	for _, key := range retirementKeys {
		record := m.retirementRecords[key]
		api, err := m.factory.newService(record.RegistrationURL)
		if err != nil {
			shutdownErrors = append(shutdownErrors, err)
			continue
		}
		handle, exists, err := api.findScaleSet(
			shutdownContext,
			record.ScaleSetName,
			m.cfg.runnerGroup,
		)
		if err != nil {
			shutdownErrors = append(shutdownErrors, err)
			continue
		}
		if exists {
			if err := api.deleteScaleSet(shutdownContext, handle.id); err != nil {
				shutdownErrors = append(shutdownErrors, err)
			}
		}
	}
	clear(m.controllers)
	clear(m.retiring)
	clear(m.pending)
	m.lastError = errors.Join(shutdownErrors...)
	m.managerStatus = "stopped"
	if err := m.publishObserved(); err != nil {
		shutdownErrors = append(shutdownErrors, err)
	}
	return errors.Join(shutdownErrors...)
}
