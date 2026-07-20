package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/actions/scaleset"
	"github.com/actions/scaleset/listener"
)

type targetController struct {
	mu                sync.Mutex
	target            targetSpec
	handle            scaleSetHandle
	api               scaleSetService
	context           context.Context
	session           messageSession
	listener          *listener.Listener
	listenerScaler    *listenerScaler
	scaler            *runnerScaler
	cancel            context.CancelFunc
	done              chan struct{}
	tickDone          chan struct{}
	retiring          bool
	instanceID        string
	logger            *slog.Logger
	onError           func(error)
	onListenerFailure func(string, error)
}

func (c *targetController) matches(target targetSpec) bool {
	c.mu.Lock()
	controllerTarget := c.target
	c.mu.Unlock()
	return controllerTarget == target && c.scaler.snapshot().target == target
}

func startTargetController(
	parent context.Context,
	cfg config,
	target targetSpec,
	api scaleSetService,
	handle scaleSetHandle,
	docker dockerClient,
	scalerClock clock,
	instanceID string,
	recovered []recoveredContainer,
	logger *slog.Logger,
	onChange func(),
	onError func(error),
	onListenerFailure func(string, error),
) (*targetController, error) {
	api = boundScaleSetService(api)
	docker = boundDockerClient(docker)
	session, err := api.openSession(parent, handle.id, instanceID)
	if err != nil {
		return nil, err
	}
	controllerContext, cancel := context.WithCancel(parent)
	scaler := newRunnerScaler(
		controllerContext,
		cfg,
		target,
		handle.id,
		api,
		docker,
		scalerClock,
		onChange,
		onError,
	)
	for _, container := range recovered {
		if err := scaler.recover(container); err != nil {
			cancel()
			closeContext, closeCancel := detachedCleanupContext(parent)
			closeErr := session.Close(closeContext)
			closeCancel()
			if closeErr != nil {
				closeErr = fmt.Errorf("close failed target session: %w", closeErr)
			}
			return nil, errors.Join(err, closeErr)
		}
	}
	scaleSetListener, err := listener.New(
		session,
		listener.Config{
			ScaleSetID: handle.id,
			MaxRunners: target.maximum,
			Logger:     logger.With("targetKey", target.key, "component", "listener"),
		},
		listener.WithMetricsRecorder(scaler),
	)
	if err != nil {
		cancel()
		closeContext, closeCancel := detachedCleanupContext(parent)
		closeErr := session.Close(closeContext)
		closeCancel()
		if closeErr != nil {
			closeErr = fmt.Errorf("close failed target session: %w", closeErr)
		}
		return nil, errors.Join(
			fmt.Errorf("create scale-set listener for %s: %w", target.key, err),
			closeErr,
		)
	}
	controller := &targetController{
		target:            target,
		handle:            handle,
		api:               api,
		context:           controllerContext,
		session:           session,
		listener:          scaleSetListener,
		scaler:            scaler,
		cancel:            cancel,
		done:              make(chan struct{}),
		tickDone:          make(chan struct{}),
		instanceID:        instanceID,
		logger:            logger,
		onError:           onError,
		onListenerFailure: onListenerFailure,
	}
	controller.listenerScaler = &listenerScaler{
		scaler:  scaler,
		onError: onError,
	}
	controller.run(controllerContext)
	return controller, nil
}

func (c *targetController) run(ctx context.Context) {
	targetKey := c.target.key
	c.runListener(ctx, targetKey, c.session, c.listener, c.done)
	go func() {
		defer close(c.tickDone)
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if err := c.scaler.tick(ctx); err != nil {
					c.onError(fmt.Errorf("reconcile target %s: %w", targetKey, err))
				}
			}
		}
	}()
}

func (c *targetController) runListener(
	ctx context.Context,
	targetKey string,
	session messageSession,
	scaleSetListener *listener.Listener,
	done chan struct{},
) {
	go func() {
		runErr := scaleSetListener.Run(ctx, c.listenerScaler)
		closeContext, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		closeErr := session.Close(closeContext)
		cancel()
		close(done)
		if ctx.Err() != nil {
			return
		}
		if runErr == nil {
			runErr = errors.New("listener stopped unexpectedly")
		}
		err := errors.Join(runErr, closeErr)
		if err != nil {
			c.onListenerFailure(
				targetKey,
				fmt.Errorf("scale-set listener for %s stopped: %w", targetKey, err),
			)
		}
	}()
}

func (c *targetController) restartListener(ctx context.Context) error {
	c.mu.Lock()
	done := c.done
	controllerContext := c.context
	maximum := c.target.maximum
	handleID := c.handle.id
	targetKey := c.target.key
	if c.retiring {
		maximum = 0
	}
	c.mu.Unlock()
	select {
	case <-done:
	default:
		return nil
	}
	if controllerContext.Err() != nil {
		return errors.New("controller is closed")
	}
	session, err := c.api.openSession(ctx, handleID, c.instanceID)
	if err != nil {
		return err
	}
	scaleSetListener, err := listener.New(
		session,
		listener.Config{
			ScaleSetID: handleID,
			MaxRunners: maximum,
			Logger: c.logger.With(
				"targetKey", targetKey,
				"component", "listener",
			),
		},
		listener.WithMetricsRecorder(c.scaler),
	)
	if err != nil {
		closeContext, closeCancel := detachedCleanupContext(ctx)
		closeErr := session.Close(closeContext)
		closeCancel()
		return errors.Join(err, closeErr)
	}
	nextDone := make(chan struct{})
	c.mu.Lock()
	c.session = session
	c.listener = scaleSetListener
	c.done = nextDone
	c.mu.Unlock()
	c.runListener(controllerContext, targetKey, session, scaleSetListener, nextDone)
	return nil
}

func (c *targetController) update(
	ctx context.Context,
	cfg config,
	target targetSpec,
) error {
	handle, err := c.api.ensureScaleSet(
		ctx,
		target.scaleSetName,
		cfg.runnerGroup,
		effectiveLabels(cfg),
	)
	if err != nil {
		return err
	}
	if handle.id != c.handle.id {
		return fmt.Errorf(
			"scale set %q changed ID from %d to %d",
			target.scaleSetName,
			c.handle.id,
			handle.id,
		)
	}
	c.mu.Lock()
	scaleSetListener := c.listener
	c.mu.Unlock()
	if err := c.scaler.setMaximum(ctx, target.maximum); err != nil {
		return err
	}
	scaleSetListener.SetMaxRunners(target.maximum)
	c.mu.Lock()
	c.target = target
	c.handle = handle
	c.mu.Unlock()
	return nil
}

func (c *targetController) beginRetirement(ctx context.Context) error {
	c.mu.Lock()
	c.retiring = true
	c.target.maximum = 0
	scaleSetListener := c.listener
	c.mu.Unlock()
	scaleSetListener.SetMaxRunners(0)
	return c.scaler.beginRetirement(ctx)
}

func (c *targetController) reactivate(
	ctx context.Context,
	cfg config,
	target targetSpec,
) error {
	handle, err := c.api.ensureScaleSet(
		ctx,
		target.scaleSetName,
		cfg.runnerGroup,
		effectiveLabels(cfg),
	)
	if err != nil {
		return err
	}
	if handle.id != c.handle.id {
		return fmt.Errorf(
			"scale set %q changed ID from %d to %d",
			target.scaleSetName,
			c.handle.id,
			handle.id,
		)
	}
	if err := c.scaler.reactivate(ctx, target); err != nil {
		return err
	}
	c.mu.Lock()
	c.retiring = false
	c.target = target
	c.handle = handle
	scaleSetListener := c.listener
	c.mu.Unlock()
	scaleSetListener.SetMaxRunners(target.maximum)
	return nil
}

func (c *targetController) shutdown(ctx context.Context) error {
	return errors.Join(
		c.closeSession(ctx),
		c.cleanupRunners(ctx),
		c.deleteScaleSet(ctx),
	)
}

func (c *targetController) closeSession(ctx context.Context) error {
	c.cancel()
	var closeErrors []error
	c.mu.Lock()
	done := c.done
	c.mu.Unlock()
	select {
	case <-done:
	case <-ctx.Done():
		closeErrors = append(closeErrors, fmt.Errorf(
			"wait for scale-set listener %s: %w",
			c.target.key,
			ctx.Err(),
		))
	}
	select {
	case <-c.tickDone:
	case <-ctx.Done():
		closeErrors = append(closeErrors, fmt.Errorf(
			"wait for scale-set reconciler %s: %w",
			c.target.key,
			ctx.Err(),
		))
	}
	return errors.Join(closeErrors...)
}

func (c *targetController) cleanupRunners(ctx context.Context) error {
	return c.scaler.shutdown(ctx)
}

func (c *targetController) deleteScaleSet(ctx context.Context) error {
	if err := c.api.deleteScaleSet(ctx, c.handle.id); err != nil {
		return fmt.Errorf(
			"delete runner scale set %s: %w",
			c.target.key,
			err,
		)
	}
	return nil
}

func (c *targetController) snapshot() scalerSnapshot {
	return c.scaler.snapshot()
}

func (c *targetController) runnerCount() int {
	return c.scaler.runnerCount()
}

func (c *targetController) closed() bool {
	return c.context.Err() != nil
}

func (c *targetController) listenerStopped() bool {
	c.mu.Lock()
	done := c.done
	controllerContext := c.context
	c.mu.Unlock()
	if controllerContext == nil || controllerContext.Err() != nil || done == nil {
		return true
	}
	select {
	case <-done:
		return true
	default:
		return false
	}
}

type listenerScaler struct {
	scaler  *runnerScaler
	onError func(error)
}

// HandleDesiredRunnerCount reports scaling failures without terminating message polling.
func (s *listenerScaler) HandleDesiredRunnerCount(
	ctx context.Context,
	count int,
) (int, error) {
	current, err := s.scaler.HandleDesiredRunnerCount(ctx, count)
	if err != nil {
		s.onError(err)
		return current, nil
	}
	return current, nil
}

// HandleJobStarted forwards runner lifecycle state to the core scaler.
func (s *listenerScaler) HandleJobStarted(
	ctx context.Context,
	job *scaleset.JobStarted,
) error {
	if err := s.scaler.HandleJobStarted(ctx, job); err != nil {
		s.onError(err)
	}
	return nil
}

// HandleJobCompleted forwards runner lifecycle state to the core scaler.
func (s *listenerScaler) HandleJobCompleted(
	ctx context.Context,
	job *scaleset.JobCompleted,
) error {
	if err := s.scaler.HandleJobCompleted(ctx, job); err != nil {
		s.onError(err)
	}
	return nil
}

var _ listener.Scaler = (*listenerScaler)(nil)
