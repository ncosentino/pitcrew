package main

import "time"

// Capacity deficit reasons. A configured autoscaling maximum is never a health
// target, so it can never create a deficit by itself.
const (
	deficitNone                = "none"
	deficitAdmissionCeiling    = "admission-ceiling"
	deficitLaunchPending       = "launch-pending"
	deficitDockerUnavailable   = "docker-unavailable"
	deficitDockerFailed        = "docker-failed"
	deficitJITPending          = "jit-pending"
	deficitJITFailed           = "jit-failed"
	deficitListenerUnavailable = "listener-unavailable"
	deficitSessionUnavailable  = "session-unavailable"
	deficitCleanupPending      = "registration-cleanup-pending"
	deficitWorkerDraining      = "worker-draining"
	deficitInvalidDesiredState = "invalid-desired-state"
	deficitRetryBackoff        = "retry-backoff"
	deficitUnknown             = "unknown"
)

// Statistics freshness classifications.
const (
	freshnessCurrent     = "current"
	freshnessStale       = "stale"
	freshnessUnavailable = "unavailable"
)

// statisticsStaleAfter bounds how long GitHub scale-set statistics remain
// current evidence. Older statistics stay published but are marked stale rather
// than silently trusted.
const statisticsStaleAfter = 2 * time.Minute

// capacityDeficitCore reports one capacity target's evidence. Local Docker
// counts and timestamped GitHub evidence stay independent: registered-runner
// statistics never substitute for local active capacity.
type capacityDeficitCore struct {
	ObservedAt            string  `json:"observedAt"`
	Freshness             string  `json:"freshness"`
	TargetSlots           int     `json:"targetSlots"`
	ActiveWorkers         int     `json:"activeWorkers"`
	StartingWorkers       int     `json:"startingWorkers"`
	DrainingWorkers       int     `json:"drainingWorkers"`
	CleanupPendingWorkers int     `json:"cleanupPendingWorkers"`
	EligibleWorkers       *int    `json:"eligibleWorkers"`
	LocalDeficit          int     `json:"localDeficit"`
	EligibilityDeficit    *int    `json:"eligibilityDeficit"`
	Reason                string  `json:"reason"`
	Evidence              *string `json:"evidence"`
}

type targetCapacityDeficitEvidence struct {
	Key        string  `json:"key"`
	Repository *string `json:"repository"`
	capacityDeficitCore
}

type managerCapacityEvidence struct {
	Fixed   *capacityDeficitCore            `json:"fixed"`
	Targets []targetCapacityDeficitEvidence `json:"targets"`
}

// targetCapacityCondition carries the manager-owned state a scaler snapshot
// cannot see, so the published reason is the manager's actual blocking reason
// rather than a dashboard's guess.
type targetCapacityCondition struct {
	listenerStopped bool
	sessionMissing  bool
	restartPending  bool
	desiredStatus   string
}

// buildCapacityEvidence projects per-target deficit evidence for an autoscaled
// profile. Fixed evidence stays null because an autoscaled profile reports
// per-target evidence instead.
func buildCapacityEvidence(
	snapshots []scalerSnapshot,
	conditions map[string]targetCapacityCondition,
	health managerSubsystemHealth,
	now time.Time,
) managerCapacityEvidence {
	evidence := managerCapacityEvidence{
		Fixed:   nil,
		Targets: make([]targetCapacityDeficitEvidence, 0, len(snapshots)),
	}
	for _, snapshot := range snapshots {
		target := targetCapacityDeficitEvidence{
			Key: boundedIdentity(snapshot.target.key),
			capacityDeficitCore: targetDeficitCore(
				snapshot,
				conditions[snapshot.target.key],
				health,
				now,
			),
		}
		if snapshot.target.repository != "" {
			repository := snapshot.target.repository
			target.Repository = &repository
		}
		evidence.Targets = append(evidence.Targets, target)
	}
	return evidence
}

func targetDeficitCore(
	snapshot scalerSnapshot,
	condition targetCapacityCondition,
	health managerSubsystemHealth,
	now time.Time,
) capacityDeficitCore {
	starting := 0
	cleanupPending := 0
	draining := 0
	for _, runner := range snapshot.runners {
		switch runner.state {
		case runnerStarting:
			starting++
		case runnerCleanupPending:
			cleanupPending++
		case runnerDraining:
			draining++
		}
	}
	for _, pending := range snapshot.pendingCleanups {
		if slotKeyHeldByRunner(snapshot, pending.SlotKey) {
			continue
		}
		cleanupPending++
	}

	targetSlots := max(snapshot.targetSlots, 0)
	active := max(snapshot.activeRunners, 0)
	core := capacityDeficitCore{
		ObservedAt:            now.UTC().Format(time.RFC3339),
		Freshness:             statisticsFreshness(snapshot.statistics.observedAt, now),
		TargetSlots:           targetSlots,
		ActiveWorkers:         active,
		StartingWorkers:       starting,
		DrainingWorkers:       draining,
		CleanupPendingWorkers: cleanupPending,
		LocalDeficit:          max(targetSlots-active, 0),
	}
	if core.Freshness != freshnessUnavailable {
		eligible := max(snapshot.statistics.registeredRunners, 0)
		core.EligibleWorkers = &eligible
		eligibilityDeficit := max(targetSlots-eligible, 0)
		core.EligibilityDeficit = &eligibilityDeficit
	}
	core.Reason, core.Evidence = deficitReason(core, snapshot, condition, health)
	return core
}

// statisticsFreshness reports whether GitHub statistics are current evidence.
// Statistics that were never observed stay unavailable instead of being
// published as a measured zero.
func statisticsFreshness(observedAt time.Time, now time.Time) string {
	if observedAt.IsZero() {
		return freshnessUnavailable
	}
	if now.Sub(observedAt) > statisticsStaleAfter {
		return freshnessStale
	}
	return freshnessCurrent
}

// deficitReason reports why the manager has not reached the activation target.
// It never blames the configured maximum, and it never proposes removing a busy
// or assigned worker.
func deficitReason(
	core capacityDeficitCore,
	snapshot scalerSnapshot,
	condition targetCapacityCondition,
	health managerSubsystemHealth,
) (string, *string) {
	if core.Freshness == freshnessUnavailable {
		return deficitUnknown, sanitizedEvidence(
			"no scale-set statistics have been observed for this target yet",
		)
	}
	if core.LocalDeficit == 0 {
		return deficitNone, nil
	}
	switch condition.desiredStatus {
	case "invalid", "stale", "conflict":
		return deficitInvalidDesiredState, sanitizedEvidence(
			"desired capacity was rejected as " + condition.desiredStatus,
		)
	}
	if snapshot.retiring {
		return deficitWorkerDraining, sanitizedEvidence(
			"target is retiring and its workers are draining",
		)
	}
	if core.CleanupPendingWorkers > 0 {
		return deficitCleanupPending, sanitizedEvidence(
			"replacement capacity waits for exact registration cleanup",
		)
	}
	if condition.sessionMissing {
		return deficitSessionUnavailable, sanitizedEvidence(
			"scale-set session is unavailable for this target",
		)
	}
	if condition.listenerStopped {
		return deficitListenerUnavailable, sanitizedEvidence(
			"scale-set listener is stopped for this target",
		)
	}
	if condition.restartPending {
		return deficitRetryBackoff, sanitizedEvidence(
			"listener restart is waiting on retry backoff",
		)
	}
	if reason, evidence := snapshot.blocking.reason, snapshot.blocking.evidence; reason != "" {
		return reason, sanitizedEvidence(evidence)
	}
	if health.Docker.State == subsystemUnavailable {
		return deficitDockerUnavailable, sanitizedEvidence(
			"recent Docker operations from this manager failed repeatedly",
		)
	}
	if health.Docker.State == subsystemDegraded {
		return deficitDockerFailed, sanitizedEvidence(
			"a recent Docker operation from this manager failed",
		)
	}
	if health.GitHub.State == subsystemUnavailable ||
		health.GitHub.State == subsystemDegraded {
		return deficitJITFailed, sanitizedEvidence(
			"a recent scale-set operation from this manager failed",
		)
	}
	if core.StartingWorkers > 0 {
		return deficitLaunchPending, sanitizedEvidence(
			"admitted workers are still starting",
		)
	}
	return deficitUnknown, nil
}
