package main

import (
	"sort"
	"time"
)

type resourceTelemetry struct {
	SampledAt string                `json:"sampledAt"`
	Status    string                `json:"status"`
	Host      *hostResourceCapacity `json:"host"`
	Manager   *resourceUsage        `json:"manager"`
}

type observedSlot struct {
	Key                string              `json:"key"`
	Repository         *string             `json:"repository"`
	Desired            bool                `json:"desired"`
	ProcessRunning     bool                `json:"processRunning"`
	State              string              `json:"state"`
	FailureCount       int                 `json:"failureCount"`
	BackoffSeconds     int                 `json:"backoffSeconds"`
	UpdatedAt          *string             `json:"updatedAt"`
	Resources          *resourceUsage      `json:"resources"`
	Activity           string              `json:"activity,omitempty"`
	Target             string              `json:"target,omitempty"`
	RegistrationStatus string              `json:"registrationStatus"`
	ImageID            *string             `json:"imageId"`
	LastExit           *lastExitDiagnostic `json:"lastExit"`
}

// observedResourcePolicy publishes the configured per-worker limits. A null
// field means unconfigured; it never means zero.
type observedResourcePolicy struct {
	MemoryBytes     *int64  `json:"memoryBytes"`
	MemorySwapBytes *int64  `json:"memorySwapBytes"`
	CPUCores        *string `json:"cpuCores"`
	PIDs            *int64  `json:"pids"`
}

// observedScaleSetStatistics carries timestamped GitHub evidence. It is never a
// count of local Docker workers.
type observedScaleSetStatistics struct {
	ObservedAt        string `json:"observedAt"`
	AvailableJobs     int    `json:"availableJobs"`
	AcquiredJobs      int    `json:"acquiredJobs"`
	AssignedJobs      int    `json:"assignedJobs"`
	RunningJobs       int    `json:"runningJobs"`
	RegisteredRunners int    `json:"registeredRunners"`
	BusyRunners       int    `json:"busyRunners"`
	IdleRunners       int    `json:"idleRunners"`
}

// observedTarget separates each target's local Docker worker counts from the
// GitHub scale-set statistics observed for the same target.
type observedTarget struct {
	Key                  string                      `json:"key"`
	Repository           *string                     `json:"repository"`
	MaximumSlots         int                         `json:"maximumSlots"`
	TargetSlots          int                         `json:"targetSlots"`
	LocalActiveWorkers   int                         `json:"localActiveWorkers"`
	LocalIdleWorkers     int                         `json:"localIdleWorkers"`
	LocalBusyWorkers     int                         `json:"localBusyWorkers"`
	LocalDrainingWorkers int                         `json:"localDrainingWorkers"`
	Statistics           *observedScaleSetStatistics `json:"statistics"`
}

type observedAutoscaling struct {
	Mode                  string  `json:"mode"`
	Status                string  `json:"status"`
	MinimumIdleSlots      int     `json:"minimumIdleSlots"`
	MaximumSlots          int     `json:"maximumSlots"`
	TargetSlots           int     `json:"targetSlots"`
	AssignedJobs          int     `json:"assignedJobs"`
	RunningJobs           int     `json:"runningJobs"`
	AvailableJobs         int     `json:"availableJobs"`
	IdleRunners           int     `json:"idleRunners"`
	BusyRunners           int     `json:"busyRunners"`
	ScaleDownDelaySeconds int     `json:"scaleDownDelaySeconds"`
	ScaleDownAt           *string `json:"scaleDownAt"`
	ScaleSetCount         int     `json:"scaleSetCount"`
	LastError             *string `json:"lastError"`

	MaximumActiveWorkers int              `json:"maximumActiveWorkers"`
	Targets              []observedTarget `json:"targets"`
}

type observedUpdate struct {
	Status         string  `json:"status"`
	TargetImage    string  `json:"targetImage"`
	TargetImageID  *string `json:"targetImageId"`
	TargetRevision string  `json:"targetRevision"`
	CurrentWorkers int     `json:"currentWorkers"`
	StaleWorkers   int     `json:"staleWorkers"`
	LastError      *string `json:"lastError"`
}

type observedState struct {
	SchemaVersion          int                     `json:"schemaVersion"`
	ManagerContractVersion int                     `json:"managerContractVersion"`
	ProfileID              string                  `json:"profileId"`
	ManagerInstanceID      string                  `json:"managerInstanceId"`
	ManagerStatus          string                  `json:"managerStatus"`
	ObservedAt             string                  `json:"observedAt"`
	Scope                  string                  `json:"scope"`
	Generation             int                     `json:"generation"`
	DesiredStateHash       *string                 `json:"desiredStateHash"`
	DesiredStateStatus     string                  `json:"desiredStateStatus"`
	DesiredSlots           int                     `json:"desiredSlots"`
	ActiveSlots            int                     `json:"activeSlots"`
	EligibleSlots          int                     `json:"eligibleSlots"`
	DrainingSlots          int                     `json:"drainingSlots"`
	ConfiguredSlots        int                     `json:"configuredSlots"`
	Slots                  []observedSlot          `json:"slots"`
	ResourceTelemetry      resourceTelemetry       `json:"resourceTelemetry"`
	Host                   observedHost            `json:"host"`
	ResourcePolicy         *observedResourcePolicy `json:"resourcePolicy"`
	Autoscaling            observedAutoscaling     `json:"autoscaling"`
	Update                 observedUpdate          `json:"update"`

	// Contract-12 diagnostics stay additive until every manager mode
	// publishes them, so a connector built for an earlier contract keeps
	// working while these fields are populated.
	OperationJournal *managerOperationJournal `json:"operationJournal,omitempty"`
	SubsystemHealth  *managerSubsystemHealth  `json:"subsystemHealth,omitempty"`
	CapacityEvidence *managerCapacityEvidence `json:"capacityEvidence,omitempty"`
}

func buildObservedState(
	cfg config,
	instanceID string,
	managerStatus string,
	current *parsedDesiredState,
	desiredStateStatus string,
	snapshots []scalerSnapshot,
	lastError error,
	now time.Time,
) observedState {
	now = now.UTC()
	scope := cfg.scope
	generation := 0
	var desiredStateHash *string
	configuredSlots := 0
	if current != nil {
		scope = current.state.Scope
		generation = current.state.Generation
		hash := current.stateHash
		desiredStateHash = &hash
		configuredSlots = len(configuredSlotKeys(current.state))
	}

	state := observedState{
		SchemaVersion:          1,
		ManagerContractVersion: managerContractVersion,
		ProfileID:              cfg.profileID,
		ManagerInstanceID:      instanceID,
		ManagerStatus:          managerStatus,
		ObservedAt:             now.Format(time.RFC3339),
		Scope:                  scope,
		Generation:             generation,
		DesiredStateHash:       desiredStateHash,
		DesiredStateStatus:     desiredStateStatus,
		ConfiguredSlots:        configuredSlots,
		Slots:                  []observedSlot{},
		ResourceTelemetry: resourceTelemetry{
			SampledAt: now.Format(time.RFC3339),
			Status:    "unavailable",
			Host:      nil,
			Manager:   nil,
		},
		Host: observedHost{
			Hardware: unavailableHostHardwareInventory(now),
		},
		ResourcePolicy: observedResourcePolicyFrom(cfg.resources),
		Autoscaling: observedAutoscaling{
			Mode:                  "scale-set",
			Status:                autoscalingStatus(managerStatus, lastError),
			MinimumIdleSlots:      0,
			MaximumSlots:          configuredSlots,
			ScaleDownDelaySeconds: int(cfg.scaleDownDelay / time.Second),
			ScaleSetCount:         len(snapshots),
			MaximumActiveWorkers:  cfg.maximumActiveWorkers,
			Targets:               []observedTarget{},
		},
		Update: observedUpdate{
			Status:         "current",
			TargetImage:    cfg.runnerImage,
			TargetImageID:  slotImageID(cfg.workerImageID),
			TargetRevision: cfg.workerRevision,
		},
	}
	if lastError != nil {
		message := lastError.Error()
		state.Autoscaling.LastError = &message
	}

	var earliestScaleDown *time.Time
	controllerMaximumSlots := 0
	for _, snapshot := range snapshots {
		if snapshot.target.maximum > 0 {
			controllerMaximumSlots += snapshot.target.maximum
		}
		state.Autoscaling.MinimumIdleSlots += snapshot.minimumIdleSlots
		state.Autoscaling.TargetSlots += snapshot.targetSlots
		state.Autoscaling.AssignedJobs += snapshot.statistics.assignedJobs
		state.Autoscaling.RunningJobs += snapshot.statistics.runningJobs
		state.Autoscaling.AvailableJobs += snapshot.statistics.availableJobs
		state.Autoscaling.IdleRunners += snapshot.idleRunners
		state.Autoscaling.BusyRunners += snapshot.busyRunners
		state.Update.StaleWorkers += snapshot.staleRunners
		state.Update.CurrentWorkers += len(snapshot.runners) - snapshot.staleRunners
		if snapshot.scaleDownAt != nil &&
			(earliestScaleDown == nil || snapshot.scaleDownAt.Before(*earliestScaleDown)) {
			value := *snapshot.scaleDownAt
			earliestScaleDown = &value
		}
		state.Autoscaling.Targets = append(
			state.Autoscaling.Targets,
			observedTargetState(snapshot),
		)
		for _, cleanup := range snapshot.pendingCleanups {
			if slotKeyHeldByRunner(snapshot, cleanup.SlotKey) {
				continue
			}
			state.DrainingSlots++
			state.Slots = append(
				state.Slots,
				observedCleanupSlot(cleanup, snapshot),
			)
		}
		for _, runner := range snapshot.runners {
			state.ActiveSlots++
			if snapshot.retiring ||
				runner.state == runnerDraining ||
				runner.state == runnerCleanupPending {
				state.DrainingSlots++
			}
			slot := observedRunnerSlot(runner, snapshot.retiring, cfg.workerImageID)
			if slot.RegistrationStatus == "connected" {
				state.EligibleSlots++
			}
			state.Slots = append(
				state.Slots,
				slot,
			)
		}
	}
	if state.Update.StaleWorkers > 0 {
		state.Update.Status = "rolling"
	}
	if lastError != nil {
		message := lastError.Error()
		state.Update.LastError = &message
		state.Update.Status = "degraded"
	}
	if controllerMaximumSlots > state.ConfiguredSlots {
		state.ConfiguredSlots = controllerMaximumSlots
	}
	state.Autoscaling.MaximumSlots = state.ConfiguredSlots
	if state.Autoscaling.TargetSlots > state.Autoscaling.MaximumSlots {
		state.Autoscaling.MaximumSlots = state.Autoscaling.TargetSlots
		state.ConfiguredSlots = state.Autoscaling.MaximumSlots
	}
	state.DesiredSlots = state.Autoscaling.TargetSlots
	if earliestScaleDown != nil {
		value := earliestScaleDown.UTC().Format(time.RFC3339)
		state.Autoscaling.ScaleDownAt = &value
	}
	sort.Slice(state.Slots, func(i, j int) bool {
		return state.Slots[i].Key < state.Slots[j].Key
	})
	return state
}

func applyResourceSample(state *observedState, sample resourceSample) {
	state.ResourceTelemetry = sample.telemetry
	for index := range state.Slots {
		state.Slots[index].Resources = nil
		if usage, exists := sample.slots[state.Slots[index].Key]; exists {
			value := usage
			state.Slots[index].Resources = &value
		}
	}
}

// observedResourcePolicyFrom projects the configured worker limits, keeping an
// unconfigured policy null rather than reporting zero limits.
func observedResourcePolicyFrom(policy workerResourcePolicy) *observedResourcePolicy {
	if !policy.configured() {
		return nil
	}
	projected := observedResourcePolicy{
		MemoryBytes:     policy.memoryBytes,
		MemorySwapBytes: policy.memorySwapBytes,
		PIDs:            policy.pids,
	}
	if policy.cpuCores != "" {
		value := policy.cpuCores
		projected.CPUCores = &value
	}
	return &projected
}

// observedTargetState separates local Docker worker counts from timestamped
// GitHub scale-set statistics. Statistics stay null until GitHub has reported
// them, so an unavailable observation is never published as measured zero.
func observedTargetState(snapshot scalerSnapshot) observedTarget {
	target := observedTarget{
		Key:                  snapshot.target.key,
		MaximumSlots:         max(snapshot.target.maximum, 0),
		TargetSlots:          max(snapshot.targetSlots, 0),
		LocalActiveWorkers:   snapshot.activeRunners,
		LocalIdleWorkers:     snapshot.idleRunners,
		LocalBusyWorkers:     snapshot.busyRunners,
		LocalDrainingWorkers: snapshot.drainingRunners,
	}
	if snapshot.target.repository != "" {
		value := snapshot.target.repository
		target.Repository = &value
	}
	if !snapshot.statistics.observedAt.IsZero() {
		target.Statistics = &observedScaleSetStatistics{
			ObservedAt:        snapshot.statistics.observedAt.UTC().Format(time.RFC3339),
			AvailableJobs:     snapshot.statistics.availableJobs,
			AcquiredJobs:      snapshot.statistics.acquiredJobs,
			AssignedJobs:      snapshot.statistics.assignedJobs,
			RunningJobs:       snapshot.statistics.runningJobs,
			RegisteredRunners: snapshot.statistics.registeredRunners,
			BusyRunners:       snapshot.statistics.busyRunners,
			IdleRunners:       snapshot.statistics.idleRunners,
		}
	}
	return target
}

// slotKeyHeldByRunner reports whether a live worker still owns a slot key, so
// pending registration cleanup never publishes a duplicate slot.
func slotKeyHeldByRunner(snapshot scalerSnapshot, slotKey string) bool {
	for _, runner := range snapshot.runners {
		if runner.key == slotKey {
			return true
		}
	}
	return false
}

// observedCleanupSlot publishes a worker whose container has gone but whose
// exact JIT registration removal is still pending, carrying the exit evidence
// captured before removal.
func observedCleanupSlot(
	record registrationCleanupRecord,
	snapshot scalerSnapshot,
) observedSlot {
	updatedAt := record.FirstFailedAt
	if record.LastAttemptAt != "" {
		updatedAt = record.LastAttemptAt
	}
	var updated *string
	if updatedAt != "" {
		updated = &updatedAt
	}
	var repository *string
	if snapshot.target.repository != "" {
		value := snapshot.target.repository
		repository = &value
	}
	return observedSlot{
		Key:                record.SlotKey,
		Repository:         repository,
		Desired:            false,
		ProcessRunning:     false,
		State:              "draining",
		FailureCount:       record.Attempts,
		BackoffSeconds:     0,
		UpdatedAt:          updated,
		Resources:          nil,
		Activity:           "draining",
		Target:             record.TargetKey,
		RegistrationStatus: "unknown",
		ImageID:            nil,
		LastExit:           record.LastExit,
	}
}

func observedRunnerSlot(
	runner runnerRecord,
	retiring bool,
	imageID string,
) observedSlot {
	state := "starting"
	activity := string(runner.state)
	registrationStatus := "unknown"
	switch runner.state {
	case runnerIdle, runnerBusy:
		state = "online"
		registrationStatus = "connected"
	case runnerDraining, runnerCleanupPending:
		state = "draining"
		activity = "draining"
		registrationStatus = "disconnected"
	}
	if retiring {
		state = "draining"
	}
	if runner.recovered && runner.protected {
		activity = "unknown"
		registrationStatus = "unknown"
	}
	updatedAt := runner.updatedAt.UTC().Format(time.RFC3339)
	var repository *string
	if runner.repository != "" {
		value := runner.repository
		repository = &value
	}
	return observedSlot{
		Key:        runner.key,
		Repository: repository,
		Desired: !retiring &&
			runner.state != runnerDraining &&
			runner.state != runnerCleanupPending,
		ProcessRunning:     true,
		State:              state,
		FailureCount:       0,
		BackoffSeconds:     0,
		UpdatedAt:          &updatedAt,
		Resources:          nil,
		Activity:           activity,
		Target:             runner.targetKey,
		RegistrationStatus: registrationStatus,
		ImageID:            slotImageID(imageID),
		LastExit:           nil,
	}
}

// slotImageID reports the immutable local image identity a worker launched
// from, or null when the manager has no configured identity.
func slotImageID(imageID string) *string {
	if imageID == "" {
		return nil
	}
	value := imageID
	return &value
}

func autoscalingStatus(managerStatus string, lastError error) string {
	if lastError != nil {
		return "degraded"
	}
	switch managerStatus {
	case "starting", "stopping":
		return managerStatus
	case "stopped":
		return "stopping"
	default:
		return "running"
	}
}
