package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/actions/scaleset"
	"github.com/actions/scaleset/listener"
	"github.com/google/uuid"
)

type fakeClock struct {
	mu      sync.Mutex
	current time.Time
}

func (c *fakeClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.current
}

func (c *fakeClock) advance(duration time.Duration) {
	c.mu.Lock()
	c.current = c.current.Add(duration)
	c.mu.Unlock()
}

type eventRecorder struct {
	mu     sync.Mutex
	events []string
}

func (r *eventRecorder) add(event string) {
	r.mu.Lock()
	r.events = append(r.events, event)
	r.mu.Unlock()
}

func (r *eventRecorder) snapshot() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.events...)
}

type fakeScaleSetService struct {
	mu               sync.Mutex
	nextRunnerID     int64
	jitCalls         int
	generateErrors   []error
	generateStarted  chan struct{}
	generateContinue <-chan struct{}
	removeCalls      []int64
	removeErrors     map[int64]error
	removeStarted    chan struct{}
	removeContinue   <-chan struct{}
	events           *eventRecorder
	ensureHandle     scaleSetHandle
	ensureCalls      int
	ensureErrors     []error
	deletedScaleSet  []int
	scaleSetExists   bool
	openSessionCalls int
	sessionFactory   func() messageSession
}

func newFakeScaleSetService(events *eventRecorder) *fakeScaleSetService {
	return &fakeScaleSetService{
		nextRunnerID:   1,
		removeErrors:   make(map[int64]error),
		events:         events,
		ensureHandle:   scaleSetHandle{id: 42, name: "pitcrew-test"},
		scaleSetExists: true,
	}
}

func (s *fakeScaleSetService) findScaleSet(
	_ context.Context,
	_ string,
	_ string,
) (scaleSetHandle, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.ensureHandle, s.scaleSetExists, nil
}

func (s *fakeScaleSetService) ensureScaleSet(
	_ context.Context,
	_ string,
	_ string,
	_ []string,
) (scaleSetHandle, error) {
	s.mu.Lock()
	s.ensureCalls++
	if len(s.ensureErrors) > 0 {
		err := s.ensureErrors[0]
		s.ensureErrors = s.ensureErrors[1:]
		s.mu.Unlock()
		return scaleSetHandle{}, err
	}
	s.scaleSetExists = true
	s.mu.Unlock()
	return s.ensureHandle, nil
}

func (s *fakeScaleSetService) generateJIT(
	_ context.Context,
	_ int,
	runnerName string,
) (jitRunnerConfig, error) {
	s.mu.Lock()
	s.jitCalls++
	var err error
	if len(s.generateErrors) > 0 {
		err = s.generateErrors[0]
		s.generateErrors = s.generateErrors[1:]
	}
	started := s.generateStarted
	continued := s.generateContinue
	id := s.nextRunnerID
	if err == nil {
		s.nextRunnerID++
	}
	s.mu.Unlock()
	if started != nil {
		select {
		case started <- struct{}{}:
		default:
		}
	}
	if continued != nil {
		<-continued
	}
	if err != nil {
		return jitRunnerConfig{}, err
	}
	return jitRunnerConfig{
		runnerID:   id,
		runnerName: runnerName,
		encoded:    fmt.Sprintf("jit-secret-%d", id),
	}, nil
}

func (s *fakeScaleSetService) removeRunner(_ context.Context, runnerID int64) error {
	s.mu.Lock()
	s.removeCalls = append(s.removeCalls, runnerID)
	err := s.removeErrors[runnerID]
	started := s.removeStarted
	continued := s.removeContinue
	s.mu.Unlock()
	if started != nil {
		select {
		case started <- struct{}{}:
		default:
		}
	}
	if continued != nil {
		<-continued
	}
	if s.events != nil {
		s.events.add(fmt.Sprintf("api-remove-%d", runnerID))
	}
	return err
}

func (s *fakeScaleSetService) openSession(
	_ context.Context,
	_ int,
	_ string,
) (messageSession, error) {
	s.mu.Lock()
	s.openSessionCalls++
	factory := s.sessionFactory
	s.mu.Unlock()
	if factory != nil {
		return factory(), nil
	}
	return newFakeMessageSession(), nil
}

func (s *fakeScaleSetService) deleteScaleSet(_ context.Context, scaleSetID int) error {
	s.mu.Lock()
	s.deletedScaleSet = append(s.deletedScaleSet, scaleSetID)
	s.scaleSetExists = false
	s.mu.Unlock()
	return nil
}

type fakeDockerClient struct {
	mu               sync.Mutex
	nextID           int
	launches         []containerLaunch
	stopRemove       []string
	stops            []string
	stopStarted      chan string
	stopContinue     <-chan struct{}
	events           *eventRecorder
	recovered        []recoveredContainer
	logs             map[string][]string
	readLogErrors    map[string]error
	followLines      map[string][]string
	followObserved   chan fakeFollowRequest
	stopRemoveErrors map[string][]error
	waitResults      map[string][]fakeWaitResult
	waitObserved     chan string
	running          map[string]bool
	runningErrors    map[string][]error
	runningObserved  chan string
	resourceResult   resourceSample
	resourceSet      bool
	resourceCalls    int
	resourceRequests [][]resourceContainer
}

type fakeWaitResult struct {
	exitCode int
	err      error
}

type fakeFollowRequest struct {
	containerID string
	since       time.Time
}

type fakeMessageSession struct {
	mu         sync.Mutex
	session    scaleset.RunnerScaleSetSession
	getError   error
	closeCalls int
}

func newFakeMessageSession() *fakeMessageSession {
	return &fakeMessageSession{
		session: scaleset.RunnerScaleSetSession{
			SessionID:  uuid.New(),
			Statistics: &scaleset.RunnerScaleSetStatistic{},
		},
	}
}

func (s *fakeMessageSession) GetMessage(
	ctx context.Context,
	_ int,
	_ int,
) (*scaleset.RunnerScaleSetMessage, error) {
	if s.getError != nil {
		return nil, s.getError
	}
	<-ctx.Done()
	return nil, ctx.Err()
}

func (s *fakeMessageSession) DeleteMessage(context.Context, int) error {
	return nil
}

func (s *fakeMessageSession) AcquireJobs(
	context.Context,
	[]int64,
) ([]int64, error) {
	return nil, nil
}

func (s *fakeMessageSession) Session() scaleset.RunnerScaleSetSession {
	return s.session
}

func (s *fakeMessageSession) Close(context.Context) error {
	s.mu.Lock()
	s.closeCalls++
	s.mu.Unlock()
	return nil
}

type fakeScaleSetServiceFactory struct {
	mu       sync.Mutex
	services map[string]*fakeScaleSetService
}

func newFakeScaleSetServiceFactory() *fakeScaleSetServiceFactory {
	return &fakeScaleSetServiceFactory{
		services: make(map[string]*fakeScaleSetService),
	}
}

func (f *fakeScaleSetServiceFactory) newService(
	registrationURL string,
) (scaleSetService, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	service := f.services[registrationURL]
	if service == nil {
		service = newFakeScaleSetService(&eventRecorder{})
		service.ensureHandle = scaleSetHandle{
			id:   len(f.services) + 1,
			name: registrationURL,
		}
		f.services[registrationURL] = service
	}
	return service, nil
}

func newFakeDockerClient(events *eventRecorder) *fakeDockerClient {
	return &fakeDockerClient{
		events:           events,
		logs:             make(map[string][]string),
		readLogErrors:    make(map[string]error),
		followLines:      make(map[string][]string),
		stopRemoveErrors: make(map[string][]error),
		waitResults:      make(map[string][]fakeWaitResult),
		running:          make(map[string]bool),
		runningErrors:    make(map[string][]error),
	}
}

func (d *fakeDockerClient) run(
	_ context.Context,
	launch containerLaunch,
) (string, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.nextID++
	d.launches = append(d.launches, launch)
	containerID := fmt.Sprintf("container-%d", d.nextID)
	d.running[containerID] = true
	return containerID, nil
}

func (d *fakeDockerClient) wait(ctx context.Context, containerID string) (int, error) {
	d.mu.Lock()
	if results := d.waitResults[containerID]; len(results) > 0 {
		result := results[0]
		d.waitResults[containerID] = results[1:]
		observed := d.waitObserved
		d.mu.Unlock()
		if observed != nil {
			select {
			case observed <- containerID:
			default:
			}
		}
		return result.exitCode, result.err
	}
	d.mu.Unlock()
	<-ctx.Done()
	return 0, ctx.Err()
}

func (d *fakeDockerClient) isRunning(
	_ context.Context,
	containerID string,
) (bool, error) {
	d.mu.Lock()
	if results := d.runningErrors[containerID]; len(results) > 0 {
		err := results[0]
		d.runningErrors[containerID] = results[1:]
		observed := d.runningObserved
		d.mu.Unlock()
		if observed != nil {
			select {
			case observed <- containerID:
			default:
			}
		}
		return false, err
	}
	running, exists := d.running[containerID]
	observed := d.runningObserved
	d.mu.Unlock()
	if observed != nil {
		select {
		case observed <- containerID:
		default:
		}
	}
	if !exists {
		return true, nil
	}
	return running, nil
}

func (d *fakeDockerClient) followLogs(
	ctx context.Context,
	containerID string,
	since time.Time,
	onLine func(string),
) error {
	d.mu.Lock()
	lines := append([]string(nil), d.followLines[containerID]...)
	observed := d.followObserved
	d.mu.Unlock()
	for _, line := range lines {
		onLine(line)
	}
	if observed != nil {
		select {
		case observed <- fakeFollowRequest{
			containerID: containerID,
			since:       since,
		}:
		default:
		}
	}
	<-ctx.Done()
	return ctx.Err()
}

func (d *fakeDockerClient) readLogs(
	_ context.Context,
	containerID string,
) ([]string, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if err := d.readLogErrors[containerID]; err != nil {
		return nil, err
	}
	return append([]string(nil), d.logs[containerID]...), nil
}

func (d *fakeDockerClient) stopAndRemove(
	_ context.Context,
	containerID string,
) error {
	d.mu.Lock()
	d.stopRemove = append(d.stopRemove, containerID)
	var err error
	if results := d.stopRemoveErrors[containerID]; len(results) > 0 {
		err = results[0]
		d.stopRemoveErrors[containerID] = results[1:]
	}
	if err == nil {
		d.running[containerID] = false
	}
	d.mu.Unlock()
	if d.events != nil {
		d.events.add("docker-stop-remove-" + containerID)
	}
	return err
}

func (d *fakeDockerClient) stop(_ context.Context, containerID string) error {
	d.mu.Lock()
	d.stops = append(d.stops, containerID)
	started := d.stopStarted
	continued := d.stopContinue
	d.mu.Unlock()
	if started != nil {
		started <- containerID
	}
	if continued != nil {
		<-continued
	}
	d.mu.Lock()
	d.running[containerID] = false
	d.mu.Unlock()
	return nil
}

func (d *fakeDockerClient) listManaged(
	_ context.Context,
	_ string,
) ([]recoveredContainer, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]recoveredContainer(nil), d.recovered...), nil
}

func (d *fakeDockerClient) sampleResources(
	_ context.Context,
	_ string,
	runners []resourceContainer,
	sampledAt time.Time,
) resourceSample {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.resourceCalls++
	d.resourceRequests = append(
		d.resourceRequests,
		append([]resourceContainer(nil), runners...),
	)
	if !d.resourceSet {
		return unavailableResourceSample(sampledAt)
	}
	result := d.resourceResult
	result.telemetry = d.resourceResult.telemetry
	if result.telemetry.SampledAt == "" {
		result.telemetry.SampledAt = sampledAt.UTC().Format(time.RFC3339)
	}
	result.slots = make(map[string]resourceUsage, len(d.resourceResult.slots))
	for key, usage := range d.resourceResult.slots {
		result.slots[key] = usage
	}
	return result
}

func newTestScaler(
	t *testing.T,
	maximum int,
	minimumIdle int,
	scaleDownDelay time.Duration,
) (*runnerScaler, *fakeScaleSetService, *fakeDockerClient, *fakeClock, context.CancelFunc) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	clock := &fakeClock{current: time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)}
	events := &eventRecorder{}
	api := newFakeScaleSetService(events)
	docker := newFakeDockerClient(events)
	cfg := config{
		profileID:       "profile-a",
		runnerImage:     "example/runner:latest",
		namePrefix:      "pitcrew-runner",
		minimumIdle:     minimumIdle,
		scaleDownDelay:  scaleDownDelay,
		noDefaultLabels: false,
	}
	target := targetSpec{
		key:             "repo-1234",
		registrationURL: "https://github.com/example/repository",
		repository:      "https://github.com/example/repository",
		maximum:         maximum,
		scaleSetName:    "pitcrew-profile-a-deadbeef",
	}
	scaler := newRunnerScaler(
		ctx,
		cfg,
		target,
		42,
		api,
		docker,
		clock,
		nil,
		func(err error) {
			if err != nil && !errors.Is(err, context.Canceled) {
				t.Logf("scaler background error: %v", err)
			}
		},
	)
	suffix := 0
	scaler.nameSuffix = func() (string, error) {
		suffix++
		return fmt.Sprintf("suffix%02d", suffix), nil
	}
	return scaler, api, docker, clock, cancel
}

func markAllRunnersIdle(scaler *runnerScaler) {
	snapshot := scaler.snapshot()
	for _, runner := range snapshot.runners {
		scaler.handleLogSignal(runner.containerID, "Listening for Jobs")
	}
}

func findRunner(t *testing.T, scaler *runnerScaler) runnerRecord {
	t.Helper()
	snapshot := scaler.snapshot()
	if len(snapshot.runners) != 1 {
		t.Fatalf("expected one runner, got %d", len(snapshot.runners))
	}
	return snapshot.runners[0]
}

func projectTestDirectory(t *testing.T) string {
	t.Helper()
	directory, err := os.MkdirTemp(".", ".pitcrew-autoscaler-test-*")
	if err != nil {
		t.Fatalf("create project-local test directory: %v", err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(directory); err != nil {
			t.Errorf("remove project-local test directory: %v", err)
		}
	})
	return directory
}

var _ scaleSetService = (*fakeScaleSetService)(nil)
var _ scaleSetServiceFactory = (*fakeScaleSetServiceFactory)(nil)
var _ dockerClient = (*fakeDockerClient)(nil)
var _ listener.Client = (*fakeMessageSession)(nil)
var _ = scaleset.JobStillRunningError
