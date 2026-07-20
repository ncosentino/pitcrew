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
	Key            string         `json:"key"`
	Repository     *string        `json:"repository"`
	Desired        bool           `json:"desired"`
	ProcessRunning bool           `json:"processRunning"`
	State          string         `json:"state"`
	FailureCount   int            `json:"failureCount"`
	BackoffSeconds int            `json:"backoffSeconds"`
	UpdatedAt      *string        `json:"updatedAt"`
	Resources      *resourceUsage `json:"resources"`
	Activity       string         `json:"activity,omitempty"`
	Target         string         `json:"target,omitempty"`
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
}

type observedState struct {
	SchemaVersion          int                 `json:"schemaVersion"`
	ManagerContractVersion int                 `json:"managerContractVersion"`
	ProfileID              string              `json:"profileId"`
	ManagerInstanceID      string              `json:"managerInstanceId"`
	ManagerStatus          string              `json:"managerStatus"`
	ObservedAt             string              `json:"observedAt"`
	Scope                  string              `json:"scope"`
	Generation             int                 `json:"generation"`
	DesiredStateHash       *string             `json:"desiredStateHash"`
	DesiredStateStatus     string              `json:"desiredStateStatus"`
	DesiredSlots           int                 `json:"desiredSlots"`
	ActiveSlots            int                 `json:"activeSlots"`
	DrainingSlots          int                 `json:"drainingSlots"`
	ConfiguredSlots        int                 `json:"configuredSlots"`
	Slots                  []observedSlot      `json:"slots"`
	ResourceTelemetry      resourceTelemetry   `json:"resourceTelemetry"`
	Autoscaling            observedAutoscaling `json:"autoscaling"`
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
		Autoscaling: observedAutoscaling{
			Mode:                  "scale-set",
			Status:                autoscalingStatus(managerStatus, lastError),
			MinimumIdleSlots:      0,
			MaximumSlots:          configuredSlots,
			ScaleDownDelaySeconds: int(cfg.scaleDownDelay / time.Second),
			ScaleSetCount:         len(snapshots),
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
		if snapshot.scaleDownAt != nil &&
			(earliestScaleDown == nil || snapshot.scaleDownAt.Before(*earliestScaleDown)) {
			value := *snapshot.scaleDownAt
			earliestScaleDown = &value
		}
		for _, runner := range snapshot.runners {
			state.ActiveSlots++
			if snapshot.retiring ||
				runner.state == runnerDraining ||
				runner.state == runnerCleanupPending {
				state.DrainingSlots++
			}
			state.Slots = append(
				state.Slots,
				observedRunnerSlot(runner, snapshot.retiring),
			)
		}
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

func observedRunnerSlot(runner runnerRecord, retiring bool) observedSlot {
	state := "starting"
	activity := string(runner.state)
	switch runner.state {
	case runnerIdle, runnerBusy:
		state = "online"
	case runnerDraining, runnerCleanupPending:
		state = "draining"
		activity = "draining"
	}
	if retiring {
		state = "draining"
	}
	if runner.recovered && runner.protected {
		activity = "unknown"
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
		ProcessRunning: true,
		State:          state,
		FailureCount:   0,
		BackoffSeconds: 0,
		UpdatedAt:      &updatedAt,
		Resources:      nil,
		Activity:       activity,
		Target:         runner.targetKey,
	}
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
