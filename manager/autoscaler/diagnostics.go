package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/actions/scaleset"
)

// Manager contract 12 publishes durable operation evidence. The journal keeps a
// bounded window of failures, retries, recoveries, and meaningful transitions
// rather than every reconciliation pass, and the whole projection is capped so
// observed state can never grow without bound.
const (
	journalCapacity      = 64
	journalMaximumBytes  = 16384
	evidenceMaximumRunes = 160
	identityMaximumRunes = 128
	subsystemFailureBand = 3
)

// Journal subsystems.
const (
	subsystemDocker         = "docker"
	subsystemRegistration   = "registration"
	subsystemSession        = "scale-set-session"
	subsystemListener       = "listener"
	subsystemJIT            = "jit"
	subsystemWorkerLaunch   = "worker-launch"
	subsystemWorkerExit     = "worker-exit"
	subsystemTelemetry      = "telemetry"
	subsystemReconciliation = "reconciliation"
	subsystemCleanup        = "cleanup"
	subsystemAdmission      = "admission"
	subsystemRecovery       = "recovery"
)

// Journal operations. The vocabulary is closed by the contract; a new operation
// requires a new manager contract version.
const (
	operationDockerPing            = "docker-ping"
	operationDockerRun             = "docker-run"
	operationDockerInspect         = "docker-inspect"
	operationDockerRemove          = "docker-remove"
	operationRunnerRemoval         = "runner-removal"
	operationSessionCreate         = "session-create"
	operationSessionDelete         = "session-delete"
	operationMessagePoll           = "message-poll"
	operationMessageAcknowledge    = "message-acknowledge"
	operationJITConfigGenerate     = "jit-config-generate"
	operationWorkerLaunch          = "worker-launch"
	operationWorkerExit            = "worker-exit"
	operationTelemetrySample       = "telemetry-sample"
	operationDesiredStateLoad      = "desired-state-load"
	operationDesiredStateApply     = "desired-state-apply"
	operationCapacityAcknowledge   = "capacity-acknowledge"
	operationObservedStatePublish  = "observed-state-publish"
	operationRegistrationCleanup   = "registration-cleanup"
	operationContainerCleanup      = "container-cleanup"
	operationAdmissionReserve      = "admission-reserve"
	operationAdmissionSettle       = "admission-settle"
	operationManagerStart          = "manager-start"
	operationManagerShutdown       = "manager-shutdown"
	operationJournalRestore        = "journal-restore"
	operationRegistrationTokenCall = "registration-token-request"
)

// Journal outcomes.
const (
	outcomeSucceeded     = "succeeded"
	outcomeFailed        = "failed"
	outcomeTimedOut      = "timed-out"
	outcomeRetry         = "retry-scheduled"
	outcomeBlocked       = "blocked"
	outcomeRecovered     = "recovered"
	outcomeUnknownResult = "unknown"
)

// Journal reasons.
const (
	reasonNone                 = "none"
	reasonDockerUnavailable    = "docker-unavailable"
	reasonDockerFailed         = "docker-failed"
	reasonTimeout              = "timeout"
	reasonRateLimited          = "rate-limited"
	reasonAuthorizationFailed  = "authorization-failed"
	reasonNotFound             = "not-found"
	reasonConflict             = "conflict"
	reasonInvalidState         = "invalid-state"
	reasonCapacityCeiling      = "capacity-ceiling"
	reasonRetryBackoff         = "retry-backoff"
	reasonCancelled            = "cancelled"
	reasonRecovered            = "recovered"
	reasonUnknown              = "unknown"
	subsystemHealthy           = "healthy"
	subsystemDegraded          = "degraded"
	subsystemUnavailable       = "unavailable"
	subsystemUnknown           = "unknown"
	journalStatusCurrent       = "current"
	journalStatusTruncated     = "truncated"
	journalStatusUnavailable   = "unavailable"
	diagnosticsSchemaVersion   = 1
	diagnosticsJournalFileName = "operation-journal.json"
)

// managerEvent is one bounded, sanitized record of a manager operation or state
// transition. Its identity is the profile plus the durable sequence, so a
// connector can deduplicate across manager restarts and hot swaps.
type managerEvent struct {
	Sequence             int     `json:"sequence"`
	ManagerInstanceID    string  `json:"managerInstanceId"`
	ObservedAt           string  `json:"observedAt"`
	Subsystem            string  `json:"subsystem"`
	Operation            string  `json:"operation"`
	Target               *string `json:"target"`
	Outcome              string  `json:"outcome"`
	DurationMilliseconds *int    `json:"durationMilliseconds"`
	Attempt              *int    `json:"attempt"`
	ConsecutiveFailures  *int    `json:"consecutiveFailures"`
	RetryAt              *string `json:"retryAt"`
	Reason               string  `json:"reason"`
	Evidence             *string `json:"evidence"`
}

type managerOperationJournal struct {
	Status          string         `json:"status"`
	Capacity        int            `json:"capacity"`
	HighestSequence *int           `json:"highestSequence"`
	DroppedEvents   int            `json:"droppedEvents"`
	Events          []managerEvent `json:"events"`
}

// subsystemOperationEvidence describes one operation this manager performed. It
// never claims that Docker, the network, or GitHub as a whole is healthy.
type subsystemOperationEvidence struct {
	Operation            string  `json:"operation"`
	ObservedAt           string  `json:"observedAt"`
	DurationMilliseconds *int    `json:"durationMilliseconds"`
	Reason               string  `json:"reason"`
	Evidence             *string `json:"evidence"`
}

type subsystemHealthSummary struct {
	State               string                      `json:"state"`
	ObservedAt          string                      `json:"observedAt"`
	ConsecutiveFailures int                         `json:"consecutiveFailures"`
	RetryAt             *string                     `json:"retryAt"`
	LastSuccess         *subsystemOperationEvidence `json:"lastSuccess"`
	LastFailure         *subsystemOperationEvidence `json:"lastFailure"`
}

type managerSubsystemHealth struct {
	Docker subsystemHealthSummary `json:"docker"`
	GitHub subsystemHealthSummary `json:"github"`
}

// journalDocument is the durable on-disk form of the journal. It survives
// manager restart so listener and Docker failures that preceded a recovery are
// still visible to an operator.
type journalDocument struct {
	SchemaVersion   int            `json:"schemaVersion"`
	HighestSequence int            `json:"highestSequence"`
	DroppedEvents   int            `json:"droppedEvents"`
	Events          []managerEvent `json:"events"`
}

// diagnosticsObservation carries one completed operation into the recorder.
type diagnosticsObservation struct {
	subsystem  string
	operation  string
	target     string
	outcome    string
	reason     string
	evidence   string
	duration   *time.Duration
	attempt    int
	retryAt    *time.Time
	healthKind string
}

// healthKind selects which subsystem summary an observation updates. Operations
// that do not describe Docker or GitHub availability update neither.
const (
	healthNone   = ""
	healthDocker = "docker"
	healthGitHub = "github"
)

type subsystemHealthState struct {
	consecutiveFailures int
	observedAt          time.Time
	retryAt             *time.Time
	lastSuccess         *subsystemOperationEvidence
	lastFailure         *subsystemOperationEvidence
	observed            bool
}

// diagnosticsRecorder owns the durable operation journal and the subsystem
// health summaries. Every method is safe on a nil receiver so diagnostics can
// never become a precondition for running workers, and persistence failures are
// recorded rather than propagated: losing evidence must never tear down a pool.
type diagnosticsRecorder struct {
	mu         sync.Mutex
	clock      clock
	instanceID string
	path       string
	write      func(string, []byte, os.FileMode) error
	read       func(string) ([]byte, bool, error)

	events          []managerEvent
	highestSequence int
	droppedEvents   int
	restoreFailed   bool
	persistFailed   bool

	docker subsystemHealthState
	github subsystemHealthState
}

func newDiagnosticsRecorder(
	stateDirectory string,
	instanceID string,
	recorderClock clock,
) *diagnosticsRecorder {
	recorder := &diagnosticsRecorder{
		clock:      recorderClock,
		instanceID: instanceID,
		write:      writeBytesAtomically,
		read:       readOptionalFile,
	}
	if stateDirectory != "" {
		recorder.path = stateDirectory + string(os.PathSeparator) + diagnosticsJournalFileName
	}
	return recorder
}

// restore reloads the durable journal so a manager restart retains listener and
// Docker failures that preceded recovery. Malformed entries are discarded into
// the dropped counter; they never destroy retirement state, cleanup state,
// workers, or accepted desired capacity.
func (r *diagnosticsRecorder) restore() {
	if r == nil || r.path == "" {
		return
	}
	data, exists, err := r.read(r.path)
	r.mu.Lock()
	if err != nil {
		r.restoreFailed = true
		r.droppedEvents++
		r.mu.Unlock()
		return
	}
	if !exists {
		r.mu.Unlock()
		return
	}
	var document journalDocument
	if err := json.Unmarshal(data, &document); err != nil {
		r.restoreFailed = true
		r.droppedEvents++
		r.mu.Unlock()
		return
	}
	retained := make([]managerEvent, 0, len(document.Events))
	dropped := max(document.DroppedEvents, 0)
	for _, event := range document.Events {
		if !validJournalEvent(event) {
			dropped++
			continue
		}
		retained = append(retained, event)
	}
	sort.SliceStable(retained, func(i, j int) bool {
		return retained[i].Sequence < retained[j].Sequence
	})
	highest := max(document.HighestSequence, 0)
	for _, event := range retained {
		highest = max(highest, event.Sequence)
	}
	for len(retained) > journalCapacity {
		retained = retained[1:]
		dropped++
	}
	r.events = retained
	r.highestSequence = highest
	r.droppedEvents = dropped
	restored := len(retained)
	r.mu.Unlock()
	if restored > 0 {
		r.record(diagnosticsObservation{
			subsystem: subsystemRecovery,
			operation: operationJournalRestore,
			outcome:   outcomeSucceeded,
			reason:    reasonNone,
			evidence:  "restored durable operation evidence after manager restart",
		})
	}
}

// validJournalEvent rejects persisted entries that no longer satisfy the
// contract, so one malformed record cannot invalidate the whole projection.
func validJournalEvent(event managerEvent) bool {
	if event.Sequence < 1 ||
		event.ManagerInstanceID == "" ||
		event.ObservedAt == "" ||
		event.Subsystem == "" ||
		event.Operation == "" ||
		event.Outcome == "" ||
		event.Reason == "" {
		return false
	}
	if _, err := time.Parse(time.RFC3339, event.ObservedAt); err != nil {
		return false
	}
	return true
}

// record observes one completed operation. Successes update health summaries
// only, so routine statistics polls and reconciliation ticks never fill the
// journal; failures, timeouts, blocks, retries, recoveries, and meaningful
// transitions are appended.
func (r *diagnosticsRecorder) record(observation diagnosticsObservation) {
	if r == nil {
		return
	}
	now := r.currentTime()
	r.mu.Lock()
	recovered := r.updateHealthLocked(observation, now)
	journaled := journalWorthy(observation) || recovered
	if journaled {
		if recovered && observation.outcome == outcomeSucceeded {
			observation.outcome = outcomeRecovered
			observation.reason = reasonRecovered
			if observation.evidence == "" {
				observation.evidence = "operation recovered after consecutive failures"
			}
		}
		r.appendLocked(r.buildEventLocked(observation, now))
	}
	document := r.documentLocked()
	r.mu.Unlock()
	if journaled {
		r.persist(document)
	}
}

// journalWorthy keeps successful, unremarkable polling out of the journal while
// retaining every failure, timeout, block, retry, and deliberate transition.
func journalWorthy(observation diagnosticsObservation) bool {
	switch observation.outcome {
	case outcomeFailed, outcomeTimedOut, outcomeBlocked, outcomeRetry, outcomeRecovered:
		return true
	case outcomeUnknownResult:
		return true
	}
	switch observation.operation {
	case operationManagerStart,
		operationManagerShutdown,
		operationDesiredStateApply,
		operationWorkerLaunch,
		operationWorkerExit,
		operationRegistrationCleanup,
		operationJournalRestore:
		return true
	}
	return false
}

func (r *diagnosticsRecorder) buildEventLocked(
	observation diagnosticsObservation,
	now time.Time,
) managerEvent {
	r.highestSequence++
	event := managerEvent{
		Sequence:          r.highestSequence,
		ManagerInstanceID: boundedIdentity(r.instanceID),
		ObservedAt:        now.UTC().Format(time.RFC3339),
		Subsystem:         observation.subsystem,
		Operation:         observation.operation,
		Target:            optionalIdentity(observation.target),
		Outcome:           observation.outcome,
		Reason:            observation.reason,
		Evidence:          sanitizedEvidence(observation.evidence),
	}
	if event.Reason == "" {
		event.Reason = reasonNone
	}
	if event.Outcome == outcomeSucceeded {
		event.Reason = reasonNone
	}
	if observation.duration != nil {
		event.DurationMilliseconds = boundedDuration(*observation.duration)
	}
	if observation.attempt > 0 {
		attempt := min(observation.attempt, 1000)
		event.Attempt = &attempt
	}
	failures := r.failureCountLocked(observation.healthKind)
	if failures >= 0 {
		value := min(failures, 1000)
		event.ConsecutiveFailures = &value
	}
	if observation.retryAt != nil {
		retryAt := observation.retryAt.UTC().Format(time.RFC3339)
		event.RetryAt = &retryAt
	}
	return event
}

func (r *diagnosticsRecorder) failureCountLocked(kind string) int {
	switch kind {
	case healthDocker:
		return r.docker.consecutiveFailures
	case healthGitHub:
		return r.github.consecutiveFailures
	default:
		return -1
	}
}

func (r *diagnosticsRecorder) appendLocked(event managerEvent) {
	r.events = append(r.events, event)
	for len(r.events) > journalCapacity {
		r.events = r.events[1:]
		r.droppedEvents++
	}
}

// updateHealthLocked folds one observation into the relevant subsystem summary
// and reports whether the subsystem just recovered from consecutive failures.
func (r *diagnosticsRecorder) updateHealthLocked(
	observation diagnosticsObservation,
	now time.Time,
) bool {
	var state *subsystemHealthState
	switch observation.healthKind {
	case healthDocker:
		state = &r.docker
	case healthGitHub:
		state = &r.github
	default:
		return false
	}
	evidence := subsystemOperationEvidence{
		Operation:  observation.operation,
		ObservedAt: now.UTC().Format(time.RFC3339),
		Reason:     observation.reason,
		Evidence:   sanitizedEvidence(observation.evidence),
	}
	if observation.duration != nil {
		evidence.DurationMilliseconds = boundedDuration(*observation.duration)
	}
	state.observed = true
	state.observedAt = now
	switch observation.outcome {
	case outcomeSucceeded, outcomeRecovered:
		evidence.Reason = reasonNone
		recovered := state.consecutiveFailures > 0
		state.consecutiveFailures = 0
		state.retryAt = nil
		state.lastSuccess = &evidence
		return recovered
	case outcomeFailed, outcomeTimedOut:
		if evidence.Reason == "" || evidence.Reason == reasonNone {
			evidence.Reason = reasonUnknown
		}
		state.consecutiveFailures++
		state.lastFailure = &evidence
		state.retryAt = observation.retryAt
		return false
	default:
		return false
	}
}

// subsystemHealth projects the current Docker and GitHub summaries.
func (r *diagnosticsRecorder) subsystemHealth() managerSubsystemHealth {
	if r == nil {
		now := time.Now().UTC()
		return managerSubsystemHealth{
			Docker: unknownSubsystemHealth(now),
			GitHub: unknownSubsystemHealth(now),
		}
	}
	now := r.currentTime()
	r.mu.Lock()
	defer r.mu.Unlock()
	return managerSubsystemHealth{
		Docker: projectSubsystemHealth(r.docker, now),
		GitHub: projectSubsystemHealth(r.github, now),
	}
}

func unknownSubsystemHealth(now time.Time) subsystemHealthSummary {
	return subsystemHealthSummary{
		State:               subsystemUnknown,
		ObservedAt:          now.UTC().Format(time.RFC3339),
		ConsecutiveFailures: 0,
		RetryAt:             nil,
		LastSuccess:         nil,
		LastFailure:         nil,
	}
}

func projectSubsystemHealth(
	state subsystemHealthState,
	now time.Time,
) subsystemHealthSummary {
	if !state.observed {
		return unknownSubsystemHealth(now)
	}
	observedAt := state.observedAt
	if observedAt.IsZero() {
		observedAt = now
	}
	summary := subsystemHealthSummary{
		ObservedAt:          observedAt.UTC().Format(time.RFC3339),
		ConsecutiveFailures: min(state.consecutiveFailures, 1000),
		LastSuccess:         state.lastSuccess,
		LastFailure:         state.lastFailure,
	}
	if state.retryAt != nil {
		retryAt := state.retryAt.UTC().Format(time.RFC3339)
		summary.RetryAt = &retryAt
	}
	switch {
	case state.consecutiveFailures >= subsystemFailureBand:
		summary.State = subsystemUnavailable
	case state.consecutiveFailures > 0:
		summary.State = subsystemDegraded
	case state.lastSuccess != nil:
		summary.State = subsystemHealthy
	default:
		return unknownSubsystemHealth(now)
	}
	if summary.State == subsystemDegraded || summary.State == subsystemUnavailable {
		if summary.LastFailure == nil {
			summary.State = subsystemUnknown
			summary.ConsecutiveFailures = 0
			summary.RetryAt = nil
			summary.LastSuccess = nil
		}
	}
	return summary
}

// journal projects the retained window, keeping the serialized projection
// within the contract's size budget.
func (r *diagnosticsRecorder) journal() managerOperationJournal {
	if r == nil {
		return managerOperationJournal{
			Status:        journalStatusCurrent,
			Capacity:      journalCapacity,
			DroppedEvents: 0,
			Events:        []managerEvent{},
		}
	}
	r.mu.Lock()
	events := append([]managerEvent(nil), r.events...)
	dropped := r.droppedEvents
	restoreFailed := r.restoreFailed
	r.mu.Unlock()

	for len(events) > 0 {
		encoded, err := json.Marshal(events)
		if err == nil && len(encoded) <= journalMaximumBytes {
			break
		}
		events = events[1:]
		dropped++
	}

	projected := managerOperationJournal{
		Capacity:      journalCapacity,
		DroppedEvents: dropped,
		Events:        events,
	}
	if projected.Events == nil {
		projected.Events = []managerEvent{}
	}
	if len(projected.Events) > 0 {
		highest := projected.Events[len(projected.Events)-1].Sequence
		projected.HighestSequence = &highest
	}
	switch {
	case len(projected.Events) == 0 && restoreFailed:
		projected.Status = journalStatusUnavailable
		projected.HighestSequence = nil
		if projected.DroppedEvents == 0 {
			projected.DroppedEvents = 1
		}
	case projected.DroppedEvents > 0:
		projected.Status = journalStatusTruncated
	default:
		projected.Status = journalStatusCurrent
	}
	return projected
}

func (r *diagnosticsRecorder) documentLocked() journalDocument {
	return journalDocument{
		SchemaVersion:   diagnosticsSchemaVersion,
		HighestSequence: r.highestSequence,
		DroppedEvents:   r.droppedEvents,
		Events:          append([]managerEvent(nil), r.events...),
	}
}

// persist writes the journal atomically. A persistence failure is retained as
// diagnostic state; it never surfaces as an operational error, because losing
// evidence must not endanger live workers.
func (r *diagnosticsRecorder) persist(document journalDocument) {
	if r.path == "" {
		return
	}
	data, err := json.MarshalIndent(document, "", "  ")
	if err == nil {
		data = append(data, '\n')
		err = r.write(r.path, data, 0o644)
	}
	r.mu.Lock()
	r.persistFailed = err != nil
	r.mu.Unlock()
}

// persistenceDegraded reports whether the last journal write failed, so callers
// can log the condition without treating it as a pool failure.
func (r *diagnosticsRecorder) persistenceDegraded() bool {
	if r == nil {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.persistFailed
}

func (r *diagnosticsRecorder) currentTime() time.Time {
	if r.clock == nil {
		return time.Now().UTC()
	}
	return r.clock.now().UTC()
}

func boundedDuration(duration time.Duration) *int {
	milliseconds := int(duration / time.Millisecond)
	if milliseconds < 0 {
		milliseconds = 0
	}
	if milliseconds > 86400000 {
		milliseconds = 86400000
	}
	return &milliseconds
}

func optionalIdentity(value string) *string {
	bounded := boundedIdentity(value)
	if bounded == "" {
		return nil
	}
	return &bounded
}

// boundedIdentity keeps identities to the contract's length budget. Callers
// only pass keys that already appear in non-secret observed state.
func boundedIdentity(value string) string {
	runes := []rune(strings.TrimSpace(value))
	if len(runes) > identityMaximumRunes {
		runes = runes[:identityMaximumRunes]
	}
	return string(runes)
}

// sanitizedEvidence reduces an operator-facing phrase to the contract's safe
// character set. Characters that could relay URLs, tokens, headers, or raw
// command output are removed rather than escaped, so no caller can leak them by
// accident.
func sanitizedEvidence(text string) *string {
	if text == "" {
		return nil
	}
	var builder strings.Builder
	for _, symbol := range text {
		switch {
		case symbol >= 'A' && symbol <= 'Z',
			symbol >= 'a' && symbol <= 'z',
			symbol >= '0' && symbol <= '9':
			builder.WriteRune(symbol)
		case strings.ContainsRune(" .,_()'-", symbol):
			builder.WriteRune(symbol)
		default:
			builder.WriteRune(' ')
		}
	}
	collapsed := strings.Join(strings.Fields(builder.String()), " ")
	collapsed = strings.TrimLeft(collapsed, " .,_()'-")
	runes := []rune(collapsed)
	if len(runes) > evidenceMaximumRunes {
		runes = runes[:evidenceMaximumRunes]
	}
	collapsed = strings.TrimRight(string(runes), " ")
	if collapsed == "" {
		return nil
	}
	return &collapsed
}

// classifyFailure maps an operation error to the contract's closed reason
// vocabulary without retaining the underlying message, HTTP body, or command
// output.
func classifyFailure(err error) string {
	switch {
	case err == nil:
		return reasonNone
	case errors.Is(err, context.DeadlineExceeded):
		return reasonTimeout
	case errors.Is(err, context.Canceled):
		return reasonCancelled
	case errors.Is(err, scaleset.RunnerNotFoundError):
		return reasonNotFound
	case errors.Is(err, scaleset.JobStillRunningError):
		return reasonConflict
	case errors.Is(err, os.ErrNotExist):
		return reasonNotFound
	case errors.Is(err, os.ErrPermission):
		return reasonAuthorizationFailed
	default:
		return reasonUnknown
	}
}

// failureOutcome distinguishes a timeout from any other failure so operators
// can tell a slow dependency from a rejected operation.
func failureOutcome(err error) string {
	if classifyFailure(err) == reasonTimeout {
		return outcomeTimedOut
	}
	return outcomeFailed
}

// dockerFailureReason keeps Docker failures inside the Docker-specific part of
// the vocabulary while preserving timeout and cancellation evidence.
func dockerFailureReason(err error) string {
	switch reason := classifyFailure(err); reason {
	case reasonUnknown:
		return reasonDockerFailed
	case reasonNotFound:
		return reasonDockerUnavailable
	default:
		return reason
	}
}
