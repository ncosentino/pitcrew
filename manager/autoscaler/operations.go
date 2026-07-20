package main

import (
	"context"
	"errors"
	"time"

	"github.com/actions/scaleset"
)

const (
	scaleSetOperationTimeout = 15 * time.Second
	dockerOperationTimeout   = 25 * time.Second
	cleanupOperationTimeout  = 10 * time.Second
)

type contextOperationResult[T any] struct {
	value T
	err   error
}

func runContextOperation[T any](
	parent context.Context,
	timeout time.Duration,
	operation func(context.Context) (T, error),
) (T, error) {
	var zero T
	if parent == nil {
		return zero, errors.New("operation context is required")
	}
	ctx := parent
	cancel := func() {}
	if timeout > 0 {
		ctx, cancel = context.WithTimeout(parent, timeout)
	}
	defer cancel()

	result := make(chan contextOperationResult[T], 1)
	go func() {
		value, err := operation(ctx)
		result <- contextOperationResult[T]{value: value, err: err}
	}()
	select {
	case completed := <-result:
		return completed.value, completed.err
	case <-ctx.Done():
		return zero, ctx.Err()
	}
}

func runContextError(
	parent context.Context,
	timeout time.Duration,
	operation func(context.Context) error,
) error {
	_, err := runContextOperation(
		parent,
		timeout,
		func(ctx context.Context) (struct{}, error) {
			return struct{}{}, operation(ctx)
		},
	)
	return err
}

func detachedCleanupContext(parent context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.WithoutCancel(parent), cleanupOperationTimeout)
}

type boundedScaleSetServiceFactory struct {
	inner scaleSetServiceFactory
}

func boundScaleSetServiceFactory(
	factory scaleSetServiceFactory,
) scaleSetServiceFactory {
	if _, bounded := factory.(*boundedScaleSetServiceFactory); bounded {
		return factory
	}
	return &boundedScaleSetServiceFactory{inner: factory}
}

func (f *boundedScaleSetServiceFactory) newService(
	registrationURL string,
) (scaleSetService, error) {
	service, err := f.inner.newService(registrationURL)
	if err != nil {
		return nil, err
	}
	return boundScaleSetService(service), nil
}

type boundedScaleSetService struct {
	inner scaleSetService
}

func boundScaleSetService(service scaleSetService) scaleSetService {
	if _, bounded := service.(*boundedScaleSetService); bounded {
		return service
	}
	return &boundedScaleSetService{inner: service}
}

func (s *boundedScaleSetService) ensureScaleSet(
	ctx context.Context,
	name string,
	runnerGroup string,
	labels []string,
) (scaleSetHandle, error) {
	return runContextOperation(
		ctx,
		scaleSetOperationTimeout,
		func(operationContext context.Context) (scaleSetHandle, error) {
			return s.inner.ensureScaleSet(
				operationContext,
				name,
				runnerGroup,
				labels,
			)
		},
	)
}

func (s *boundedScaleSetService) findScaleSet(
	ctx context.Context,
	name string,
	runnerGroup string,
) (scaleSetHandle, bool, error) {
	type findResult struct {
		handle scaleSetHandle
		exists bool
	}
	result, err := runContextOperation(
		ctx,
		scaleSetOperationTimeout,
		func(operationContext context.Context) (findResult, error) {
			handle, exists, findErr := s.inner.findScaleSet(
				operationContext,
				name,
				runnerGroup,
			)
			return findResult{handle: handle, exists: exists}, findErr
		},
	)
	return result.handle, result.exists, err
}

func (s *boundedScaleSetService) generateJIT(
	ctx context.Context,
	scaleSetID int,
	runnerName string,
) (jitRunnerConfig, error) {
	return runContextOperation(
		ctx,
		scaleSetOperationTimeout,
		func(operationContext context.Context) (jitRunnerConfig, error) {
			return s.inner.generateJIT(operationContext, scaleSetID, runnerName)
		},
	)
}

func (s *boundedScaleSetService) removeRunner(
	ctx context.Context,
	runnerID int64,
) error {
	return runContextError(
		ctx,
		scaleSetOperationTimeout,
		func(operationContext context.Context) error {
			return s.inner.removeRunner(operationContext, runnerID)
		},
	)
}

func (s *boundedScaleSetService) openSession(
	ctx context.Context,
	scaleSetID int,
	owner string,
) (messageSession, error) {
	session, err := runContextOperation(
		ctx,
		scaleSetOperationTimeout,
		func(operationContext context.Context) (messageSession, error) {
			return s.inner.openSession(operationContext, scaleSetID, owner)
		},
	)
	if err != nil {
		return nil, err
	}
	return boundMessageSession(session), nil
}

func (s *boundedScaleSetService) deleteScaleSet(
	ctx context.Context,
	scaleSetID int,
) error {
	return runContextError(
		ctx,
		scaleSetOperationTimeout,
		func(operationContext context.Context) error {
			return s.inner.deleteScaleSet(operationContext, scaleSetID)
		},
	)
}

type boundedMessageSession struct {
	inner messageSession
}

func boundMessageSession(session messageSession) messageSession {
	if _, bounded := session.(*boundedMessageSession); bounded {
		return session
	}
	return &boundedMessageSession{inner: session}
}

func (s *boundedMessageSession) GetMessage(
	ctx context.Context,
	lastMessageID int,
	maxCapacity int,
) (*scaleset.RunnerScaleSetMessage, error) {
	return runContextOperation(
		ctx,
		0,
		func(operationContext context.Context) (*scaleset.RunnerScaleSetMessage, error) {
			return s.inner.GetMessage(operationContext, lastMessageID, maxCapacity)
		},
	)
}

func (s *boundedMessageSession) DeleteMessage(
	ctx context.Context,
	messageID int,
) error {
	return runContextError(
		ctx,
		scaleSetOperationTimeout,
		func(operationContext context.Context) error {
			return s.inner.DeleteMessage(operationContext, messageID)
		},
	)
}

func (s *boundedMessageSession) AcquireJobs(
	ctx context.Context,
	jobMessageIDs []int64,
) ([]int64, error) {
	return runContextOperation(
		ctx,
		scaleSetOperationTimeout,
		func(operationContext context.Context) ([]int64, error) {
			return s.inner.AcquireJobs(operationContext, jobMessageIDs)
		},
	)
}

func (s *boundedMessageSession) Session() scaleset.RunnerScaleSetSession {
	return s.inner.Session()
}

func (s *boundedMessageSession) Close(ctx context.Context) error {
	return runContextError(
		ctx,
		scaleSetOperationTimeout,
		s.inner.Close,
	)
}

type boundedDockerClient struct {
	inner dockerClient
}

func boundDockerClient(client dockerClient) dockerClient {
	if _, bounded := client.(*boundedDockerClient); bounded {
		return client
	}
	return &boundedDockerClient{inner: client}
}

func (d *boundedDockerClient) run(
	ctx context.Context,
	launch containerLaunch,
) (string, error) {
	return runContextOperation(
		ctx,
		dockerOperationTimeout,
		func(operationContext context.Context) (string, error) {
			return d.inner.run(operationContext, launch)
		},
	)
}

func (d *boundedDockerClient) wait(
	ctx context.Context,
	containerID string,
) (int, error) {
	return runContextOperation(
		ctx,
		0,
		func(operationContext context.Context) (int, error) {
			return d.inner.wait(operationContext, containerID)
		},
	)
}

func (d *boundedDockerClient) isRunning(
	ctx context.Context,
	containerID string,
) (bool, error) {
	return runContextOperation(
		ctx,
		dockerOperationTimeout,
		func(operationContext context.Context) (bool, error) {
			return d.inner.isRunning(operationContext, containerID)
		},
	)
}

func (d *boundedDockerClient) readLogs(
	ctx context.Context,
	containerID string,
) ([]string, error) {
	return runContextOperation(
		ctx,
		dockerOperationTimeout,
		func(operationContext context.Context) ([]string, error) {
			return d.inner.readLogs(operationContext, containerID)
		},
	)
}

func (d *boundedDockerClient) followLogs(
	ctx context.Context,
	containerID string,
	since time.Time,
	onLine func(string),
) error {
	return runContextError(
		ctx,
		0,
		func(operationContext context.Context) error {
			return d.inner.followLogs(
				operationContext,
				containerID,
				since,
				onLine,
			)
		},
	)
}

func (d *boundedDockerClient) stopAndRemove(
	ctx context.Context,
	containerID string,
) error {
	return runContextError(
		ctx,
		dockerOperationTimeout,
		func(operationContext context.Context) error {
			return d.inner.stopAndRemove(operationContext, containerID)
		},
	)
}

func (d *boundedDockerClient) stop(
	ctx context.Context,
	containerID string,
) error {
	return runContextError(
		ctx,
		dockerOperationTimeout,
		func(operationContext context.Context) error {
			return d.inner.stop(operationContext, containerID)
		},
	)
}

func (d *boundedDockerClient) listManaged(
	ctx context.Context,
	profileID string,
) ([]recoveredContainer, error) {
	return runContextOperation(
		ctx,
		dockerOperationTimeout,
		func(operationContext context.Context) ([]recoveredContainer, error) {
			return d.inner.listManaged(operationContext, profileID)
		},
	)
}

func (d *boundedDockerClient) sampleResources(
	ctx context.Context,
	profileID string,
	runners []resourceContainer,
	sampledAt time.Time,
) resourceSample {
	sample, err := runContextOperation(
		ctx,
		dockerOperationTimeout,
		func(operationContext context.Context) (resourceSample, error) {
			return d.inner.sampleResources(
				operationContext,
				profileID,
				runners,
				sampledAt,
			), nil
		},
	)
	if err != nil {
		return unavailableResourceSample(sampledAt)
	}
	return sample
}

var _ scaleSetServiceFactory = (*boundedScaleSetServiceFactory)(nil)
var _ scaleSetService = (*boundedScaleSetService)(nil)
var _ messageSession = (*boundedMessageSession)(nil)
var _ dockerClient = (*boundedDockerClient)(nil)
