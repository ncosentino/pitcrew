package main

import (
	"context"
	"sync"
	"time"

	"github.com/actions/scaleset"
)

// The instrumenting decorators publish operation evidence for the Docker and
// GitHub work this manager actually performs. They observe outcomes only; they
// never change demand semantics, admission decisions, or cleanup fencing, and a
// nil recorder disables them entirely.

type instrumentedDockerClient struct {
	inner           dockerClient
	diagnostics     *diagnosticsRecorder
	telemetryMu     sync.Mutex
	telemetryStatus string
}

func instrumentDockerClient(
	client dockerClient,
	diagnostics *diagnosticsRecorder,
) dockerClient {
	if diagnostics == nil {
		return client
	}
	if _, instrumented := client.(*instrumentedDockerClient); instrumented {
		return client
	}
	return &instrumentedDockerClient{inner: client, diagnostics: diagnostics}
}

func (d *instrumentedDockerClient) observe(
	operation string,
	target string,
	startedAt time.Time,
	err error,
) {
	duration := time.Since(startedAt)
	observation := diagnosticsObservation{
		subsystem:  subsystemDocker,
		operation:  operation,
		target:     target,
		outcome:    outcomeSucceeded,
		reason:     reasonNone,
		duration:   &duration,
		healthKind: healthDocker,
	}
	if err != nil {
		observation.outcome = failureOutcome(err)
		observation.reason = dockerFailureReason(err)
		observation.evidence = "a Docker " + operation + " operation failed"
	}
	d.diagnostics.record(observation)
}

func (d *instrumentedDockerClient) run(
	ctx context.Context,
	launch containerLaunch,
) (string, error) {
	startedAt := time.Now()
	containerID, err := d.inner.run(ctx, launch)
	d.observe(operationDockerRun, "", startedAt, err)
	return containerID, err
}

func (d *instrumentedDockerClient) create(
	ctx context.Context,
	launch containerLaunch,
) (string, error) {
	startedAt := time.Now()
	containerID, err := d.inner.create(ctx, launch)
	d.observe(operationDockerRun, "", startedAt, err)
	return containerID, err
}

func (d *instrumentedDockerClient) start(
	ctx context.Context,
	containerID string,
) error {
	startedAt := time.Now()
	err := d.inner.start(ctx, containerID)
	d.observe(operationDockerRun, "", startedAt, err)
	return err
}

func (d *instrumentedDockerClient) wait(
	ctx context.Context,
	containerID string,
) (int, error) {
	return d.inner.wait(ctx, containerID)
}

func (d *instrumentedDockerClient) isRunning(
	ctx context.Context,
	containerID string,
) (bool, error) {
	startedAt := time.Now()
	running, err := d.inner.isRunning(ctx, containerID)
	d.observe(operationDockerInspect, "", startedAt, err)
	return running, err
}

func (d *instrumentedDockerClient) inspectExit(
	ctx context.Context,
	containerID string,
) (containerExitState, bool) {
	return d.inner.inspectExit(ctx, containerID)
}

func (d *instrumentedDockerClient) readLogs(
	ctx context.Context,
	containerID string,
) ([]string, error) {
	return d.inner.readLogs(ctx, containerID)
}

func (d *instrumentedDockerClient) followLogs(
	ctx context.Context,
	containerID string,
	since time.Time,
	onLine func(string),
) error {
	return d.inner.followLogs(ctx, containerID, since, onLine)
}

func (d *instrumentedDockerClient) stopAndRemove(
	ctx context.Context,
	containerID string,
) error {
	startedAt := time.Now()
	err := d.inner.stopAndRemove(ctx, containerID)
	d.observe(operationDockerRemove, "", startedAt, err)
	return err
}

func (d *instrumentedDockerClient) stop(
	ctx context.Context,
	containerID string,
) error {
	startedAt := time.Now()
	err := d.inner.stop(ctx, containerID)
	d.observe(operationContainerCleanup, "", startedAt, err)
	return err
}

func (d *instrumentedDockerClient) listManaged(
	ctx context.Context,
	profileID string,
) ([]recoveredContainer, error) {
	startedAt := time.Now()
	containers, err := d.inner.listManaged(ctx, profileID)
	d.observe(operationDockerPing, "", startedAt, err)
	return containers, err
}

func (d *instrumentedDockerClient) sampleResources(
	ctx context.Context,
	profileID string,
	runners []resourceContainer,
	sampledAt time.Time,
) resourceSample {
	sample := d.inner.sampleResources(ctx, profileID, runners, sampledAt)
	d.telemetryMu.Lock()
	changed := d.telemetryStatus != sample.telemetry.Status
	d.telemetryStatus = sample.telemetry.Status
	d.telemetryMu.Unlock()
	if changed && sample.telemetry.Status == "unavailable" {
		d.diagnostics.record(diagnosticsObservation{
			subsystem: subsystemTelemetry,
			operation: operationTelemetrySample,
			outcome:   outcomeFailed,
			reason:    reasonDockerFailed,
			evidence:  "resource telemetry sampling reported no usage",
		})
	}
	return sample
}

func (d *instrumentedDockerClient) sampleHardware(
	ctx context.Context,
	attemptedAt time.Time,
) hostHardwareSample {
	return d.inner.sampleHardware(ctx, attemptedAt)
}

type instrumentedScaleSetServiceFactory struct {
	inner       scaleSetServiceFactory
	diagnostics *diagnosticsRecorder
}

func instrumentScaleSetServiceFactory(
	factory scaleSetServiceFactory,
	diagnostics *diagnosticsRecorder,
) scaleSetServiceFactory {
	if diagnostics == nil {
		return factory
	}
	if _, instrumented := factory.(*instrumentedScaleSetServiceFactory); instrumented {
		return factory
	}
	return &instrumentedScaleSetServiceFactory{
		inner:       factory,
		diagnostics: diagnostics,
	}
}

func (f *instrumentedScaleSetServiceFactory) newService(
	registrationURL string,
) (scaleSetService, error) {
	service, err := f.inner.newService(registrationURL)
	if err != nil {
		return nil, err
	}
	return instrumentScaleSetService(service, f.diagnostics), nil
}

type instrumentedScaleSetService struct {
	inner       scaleSetService
	diagnostics *diagnosticsRecorder
}

func instrumentScaleSetService(
	service scaleSetService,
	diagnostics *diagnosticsRecorder,
) scaleSetService {
	if diagnostics == nil {
		return service
	}
	if _, instrumented := service.(*instrumentedScaleSetService); instrumented {
		return service
	}
	return &instrumentedScaleSetService{inner: service, diagnostics: diagnostics}
}

func (s *instrumentedScaleSetService) observe(
	operation string,
	target string,
	evidence string,
	startedAt time.Time,
	err error,
) {
	duration := time.Since(startedAt)
	observation := diagnosticsObservation{
		subsystem:  subsystemSession,
		operation:  operation,
		target:     target,
		outcome:    outcomeSucceeded,
		reason:     reasonNone,
		duration:   &duration,
		healthKind: healthGitHub,
	}
	if err != nil {
		observation.outcome = failureOutcome(err)
		observation.reason = classifyFailure(err)
		observation.evidence = evidence
	}
	s.diagnostics.record(observation)
}

func (s *instrumentedScaleSetService) ensureScaleSet(
	ctx context.Context,
	name string,
	runnerGroup string,
	labels []string,
) (scaleSetHandle, error) {
	startedAt := time.Now()
	handle, err := s.inner.ensureScaleSet(ctx, name, runnerGroup, labels)
	s.observe(
		operationRegistrationTokenCall,
		"",
		"the scale set for this profile could not be ensured",
		startedAt,
		err,
	)
	return handle, err
}

func (s *instrumentedScaleSetService) findScaleSet(
	ctx context.Context,
	name string,
	runnerGroup string,
) (scaleSetHandle, bool, error) {
	return s.inner.findScaleSet(ctx, name, runnerGroup)
}

func (s *instrumentedScaleSetService) generateJIT(
	ctx context.Context,
	scaleSetID int,
	runnerName string,
) (jitRunnerConfig, error) {
	startedAt := time.Now()
	config, err := s.inner.generateJIT(ctx, scaleSetID, runnerName)
	duration := time.Since(startedAt)
	observation := diagnosticsObservation{
		subsystem:  subsystemJIT,
		operation:  operationJITConfigGenerate,
		outcome:    outcomeSucceeded,
		reason:     reasonNone,
		duration:   &duration,
		healthKind: healthGitHub,
	}
	if err != nil {
		observation.outcome = failureOutcome(err)
		observation.reason = classifyFailure(err)
		observation.evidence = "just-in-time runner configuration could not be generated"
	}
	s.diagnostics.record(observation)
	return config, err
}

func (s *instrumentedScaleSetService) removeRunner(
	ctx context.Context,
	runnerID int64,
) error {
	startedAt := time.Now()
	err := s.inner.removeRunner(ctx, runnerID)
	duration := time.Since(startedAt)
	observation := diagnosticsObservation{
		subsystem:  subsystemRegistration,
		operation:  operationRunnerRemoval,
		outcome:    outcomeSucceeded,
		reason:     reasonNone,
		duration:   &duration,
		healthKind: healthGitHub,
	}
	if err != nil {
		observation.outcome = failureOutcome(err)
		observation.reason = classifyFailure(err)
		observation.evidence = "an exact runner registration removal failed"
	}
	s.diagnostics.record(observation)
	return err
}

func (s *instrumentedScaleSetService) openSession(
	ctx context.Context,
	scaleSetID int,
	owner string,
) (messageSession, error) {
	startedAt := time.Now()
	session, err := s.inner.openSession(ctx, scaleSetID, owner)
	s.observe(
		operationSessionCreate,
		"",
		"a scale-set message session could not be opened",
		startedAt,
		err,
	)
	if err != nil {
		return nil, err
	}
	return instrumentMessageSession(session, s.diagnostics), nil
}

func (s *instrumentedScaleSetService) deleteScaleSet(
	ctx context.Context,
	scaleSetID int,
) error {
	startedAt := time.Now()
	err := s.inner.deleteScaleSet(ctx, scaleSetID)
	s.observe(
		operationSessionDelete,
		"",
		"a retired scale set could not be deleted",
		startedAt,
		err,
	)
	return err
}

type instrumentedMessageSession struct {
	inner       messageSession
	diagnostics *diagnosticsRecorder
}

func instrumentMessageSession(
	session messageSession,
	diagnostics *diagnosticsRecorder,
) messageSession {
	if diagnostics == nil {
		return session
	}
	if _, instrumented := session.(*instrumentedMessageSession); instrumented {
		return session
	}
	return &instrumentedMessageSession{inner: session, diagnostics: diagnostics}
}

// GetMessage observes statistics polling. A successful poll updates health only,
// so routine polling never fills the journal.
func (s *instrumentedMessageSession) GetMessage(
	ctx context.Context,
	lastMessageID int,
	maxCapacity int,
) (*scaleset.RunnerScaleSetMessage, error) {
	startedAt := time.Now()
	message, err := s.inner.GetMessage(ctx, lastMessageID, maxCapacity)
	duration := time.Since(startedAt)
	observation := diagnosticsObservation{
		subsystem:  subsystemListener,
		operation:  operationMessagePoll,
		outcome:    outcomeSucceeded,
		reason:     reasonNone,
		duration:   &duration,
		healthKind: healthGitHub,
	}
	if err != nil {
		observation.outcome = failureOutcome(err)
		observation.reason = classifyFailure(err)
		observation.evidence = "a scale-set message poll failed"
	}
	s.diagnostics.record(observation)
	return message, err
}

func (s *instrumentedMessageSession) DeleteMessage(
	ctx context.Context,
	messageID int,
) error {
	startedAt := time.Now()
	err := s.inner.DeleteMessage(ctx, messageID)
	duration := time.Since(startedAt)
	observation := diagnosticsObservation{
		subsystem:  subsystemListener,
		operation:  operationMessageAcknowledge,
		outcome:    outcomeSucceeded,
		reason:     reasonNone,
		duration:   &duration,
		healthKind: healthGitHub,
	}
	if err != nil {
		observation.outcome = failureOutcome(err)
		observation.reason = classifyFailure(err)
		observation.evidence = "a scale-set message acknowledgement failed"
	}
	s.diagnostics.record(observation)
	return err
}

func (s *instrumentedMessageSession) AcquireJobs(
	ctx context.Context,
	jobMessageIDs []int64,
) ([]int64, error) {
	return s.inner.AcquireJobs(ctx, jobMessageIDs)
}

func (s *instrumentedMessageSession) Session() scaleset.RunnerScaleSetSession {
	return s.inner.Session()
}

func (s *instrumentedMessageSession) Close(ctx context.Context) error {
	startedAt := time.Now()
	err := s.inner.Close(ctx)
	duration := time.Since(startedAt)
	observation := diagnosticsObservation{
		subsystem:  subsystemSession,
		operation:  operationSessionDelete,
		outcome:    outcomeSucceeded,
		reason:     reasonNone,
		duration:   &duration,
		healthKind: healthGitHub,
	}
	if err != nil {
		observation.outcome = failureOutcome(err)
		observation.reason = classifyFailure(err)
		observation.evidence = "a scale-set message session could not be closed"
	}
	s.diagnostics.record(observation)
	return err
}

var _ dockerClient = (*instrumentedDockerClient)(nil)
var _ scaleSetServiceFactory = (*instrumentedScaleSetServiceFactory)(nil)
var _ scaleSetService = (*instrumentedScaleSetService)(nil)
var _ messageSession = (*instrumentedMessageSession)(nil)
