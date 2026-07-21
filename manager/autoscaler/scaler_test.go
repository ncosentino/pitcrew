package main

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

func TestCalculateTarget(t *testing.T) {
	tests := []struct {
		name         string
		maximum      int
		minimumIdle  int
		assignedJobs int
		expected     int
	}{
		{name: "zero", maximum: 5, minimumIdle: 0, assignedJobs: 0, expected: 0},
		{name: "idle plus demand", maximum: 5, minimumIdle: 1, assignedJobs: 2, expected: 3},
		{name: "hard maximum", maximum: 3, minimumIdle: 2, assignedJobs: 5, expected: 3},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if actual := calculateTarget(test.maximum, test.minimumIdle, test.assignedJobs); actual != test.expected {
				t.Fatalf("expected %d, got %d", test.expected, actual)
			}
		})
	}
}

func TestImmediateScaleUpHasNoCooldownOrBatch(t *testing.T) {
	scaler, api, docker, _, cancel := newTestScaler(t, 5, 0, 10*time.Minute)
	defer cancel()
	count, err := scaler.HandleDesiredRunnerCount(context.Background(), 4)
	if err != nil {
		t.Fatalf("scale up failed: %v", err)
	}
	if count != 4 || scaler.runnerCount() != 4 {
		t.Fatalf("expected four runners immediately, got %d", count)
	}
	if api.jitCalls != 4 || len(docker.launches) != 4 {
		t.Fatalf("expected four immediate JIT launches, got jit=%d docker=%d", api.jitCalls, len(docker.launches))
	}
}

func TestScaleDownDelayCancelsAndDebounces(t *testing.T) {
	scaler, api, docker, clock, cancel := newTestScaler(t, 2, 0, 10*time.Second)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 2); err != nil {
		t.Fatal(err)
	}
	markAllRunnersIdle(scaler)

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	firstDeadline := scaler.snapshot().scaleDownAt
	if firstDeadline == nil {
		t.Fatal("expected scale-down deadline")
	}
	clock.advance(5 * time.Second)
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 2); err != nil {
		t.Fatal(err)
	}
	if scaler.snapshot().scaleDownAt != nil {
		t.Fatal("demand recovery did not cancel scale down")
	}

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	secondDeadline := scaler.snapshot().scaleDownAt
	if secondDeadline == nil || !secondDeadline.After(*firstDeadline) {
		t.Fatal("a new low-demand period did not restart the debounce")
	}
	clock.advance(9 * time.Second)
	if err := scaler.tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(api.removeCalls) != 0 {
		t.Fatal("runner was removed before the stabilization delay")
	}
	clock.advance(time.Second)
	if err := scaler.tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(api.removeCalls) != 2 || len(docker.stopRemove) != 2 {
		t.Fatalf("expected all surplus runners to drain after one delay, got api=%d docker=%d", len(api.removeCalls), len(docker.stopRemove))
	}
}

func TestScaleDownRemovesRegistrationBeforeContainer(t *testing.T) {
	scaler, api, _, clock, cancel := newTestScaler(t, 1, 0, time.Second)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	markAllRunnersIdle(scaler)
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	clock.advance(time.Second)
	if err := scaler.tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	events := api.events.snapshot()
	if !reflect.DeepEqual(events, []string{"api-remove-1", "docker-stop-remove-container-1"}) {
		t.Fatalf("unexpected removal order: %#v", events)
	}
}

func TestCleanupPendingRetriesAndDoesNotBlockReplacementCapacity(t *testing.T) {
	scaler, api, docker, _, cancel := newTestScaler(t, 2, 0, 0)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	markAllRunnersIdle(scaler)
	docker.stopRemoveErrors["container-1"] = []error{
		errors.New("docker removal failed"),
		errors.New("docker removal still failing"),
		nil,
	}

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 0); err == nil {
		t.Fatal("expected the first Docker cleanup failure to be reported")
	}
	runner := findRunner(t, scaler)
	if runner.state != runnerCleanupPending || !runner.registrationRemoved {
		t.Fatalf("runner was not preserved as cleanup-pending: %#v", runner)
	}
	if !reflect.DeepEqual(api.removeCalls, []int64{1}) {
		t.Fatalf("registration removal was not performed exactly once: %#v", api.removeCalls)
	}

	usable, err := scaler.HandleDesiredRunnerCount(context.Background(), 1)
	if err == nil {
		t.Fatal("expected the cleanup retry failure to remain visible")
	}
	if usable != 1 {
		t.Fatalf("cleanup-pending runner was reported as usable capacity: %d", usable)
	}
	snapshot := scaler.snapshot()
	if len(snapshot.runners) != 2 || api.jitCalls != 2 {
		t.Fatalf("cleanup-pending runner blocked replacement capacity: %#v", snapshot)
	}
	if !reflect.DeepEqual(api.removeCalls, []int64{1}) {
		t.Fatalf("cleanup retry repeated API removal: %#v", api.removeCalls)
	}

	if err := scaler.tick(context.Background()); err != nil {
		t.Fatalf("final Docker cleanup retry failed: %v", err)
	}
	snapshot = scaler.snapshot()
	if len(snapshot.runners) != 1 ||
		snapshot.runners[0].state == runnerCleanupPending {
		t.Fatalf("cleanup-pending runner was not removed after retry: %#v", snapshot)
	}
}

func TestJobStillRunningErrorIsPreserved(t *testing.T) {
	scaler, api, docker, _, cancel := newTestScaler(t, 1, 0, 0)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	markAllRunnersIdle(scaler)
	api.removeErrors[1] = scaleset.JobStillRunningError
	_, err := scaler.HandleDesiredRunnerCount(context.Background(), 0)
	if !errors.Is(err, scaleset.JobStillRunningError) {
		t.Fatalf("expected JobStillRunningError, got %v", err)
	}
	if len(docker.stopRemove) != 0 {
		t.Fatal("container was stopped after JobStillRunningError")
	}
	if runner := findRunner(t, scaler); runner.state != runnerBusy {
		t.Fatalf("runner was not preserved as busy: %s", runner.state)
	}
}

func TestConcurrentJobStartCannotRaceRunnerRemoval(t *testing.T) {
	scaler, api, docker, _, cancel := newTestScaler(t, 1, 0, 0)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	markAllRunnersIdle(scaler)
	runner := findRunner(t, scaler)
	api.removeErrors[runner.runnerID] = scaleset.JobStillRunningError
	api.removeStarted = make(chan struct{}, 1)
	removeContinue := make(chan struct{})
	api.removeContinue = removeContinue

	scaleResult := make(chan error, 1)
	go func() {
		_, err := scaler.HandleDesiredRunnerCount(context.Background(), 0)
		scaleResult <- err
	}()
	select {
	case <-api.removeStarted:
	case <-time.After(time.Second):
		t.Fatal("runner removal did not start")
	}

	jobResult := make(chan error, 1)
	jobAttempted := make(chan struct{})
	go func() {
		close(jobAttempted)
		jobResult <- scaler.HandleJobStarted(
			context.Background(),
			&scaleset.JobStarted{
				RunnerID:   int(runner.runnerID),
				RunnerName: runner.runnerName,
			},
		)
	}()
	<-jobAttempted
	select {
	case err := <-jobResult:
		t.Fatalf("job lifecycle raced runner removal: %v", err)
	case <-time.After(20 * time.Millisecond):
	}

	close(removeContinue)
	if err := <-scaleResult; !errors.Is(err, scaleset.JobStillRunningError) {
		t.Fatalf("expected JobStillRunningError, got %v", err)
	}
	if err := <-jobResult; err != nil {
		t.Fatal(err)
	}
	if len(docker.stopRemove) != 0 {
		t.Fatal("container was stopped while a job was starting")
	}
	if current := findRunner(t, scaler); current.state != runnerBusy {
		t.Fatalf("runner was not preserved as busy: %#v", current)
	}
}

func TestRetirementPreservesBusyRunnerUntilCompletionAndExit(t *testing.T) {
	scaler, api, docker, _, cancel := newTestScaler(t, 1, 0, 0)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	runner := findRunner(t, scaler)
	if err := scaler.HandleJobStarted(context.Background(), &scaleset.JobStarted{
		RunnerID:   int(runner.runnerID),
		RunnerName: runner.runnerName,
	}); err != nil {
		t.Fatal(err)
	}

	if err := scaler.beginRetirement(context.Background()); err != nil {
		t.Fatal(err)
	}
	snapshot := scaler.snapshot()
	if !snapshot.retiring || snapshot.targetSlots != 0 ||
		snapshot.runners[0].state != runnerBusy {
		t.Fatalf("busy retirement state is unsafe: %#v", snapshot)
	}
	if len(api.removeCalls) != 0 || len(docker.stopRemove) != 0 {
		t.Fatal("retirement removed a busy runner")
	}

	if err := scaler.HandleJobCompleted(context.Background(), &scaleset.JobCompleted{
		RunnerID:   int(runner.runnerID),
		RunnerName: runner.runnerName,
	}); err != nil {
		t.Fatal(err)
	}
	if err := scaler.tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(api.removeCalls) != 0 || len(docker.stopRemove) != 0 {
		t.Fatal("completed ephemeral runner was killed before its container exited")
	}
	scaler.handleContainerExit(runner.containerID, 0)
	if scaler.runnerCount() != 0 {
		t.Fatal("retirement did not finish after the completed runner exited")
	}
}

func TestJobLifecycleChangesStateWithoutChangingDemand(t *testing.T) {
	scaler, _, _, _, cancel := newTestScaler(t, 2, 0, time.Minute)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	markAllRunnersIdle(scaler)
	runner := findRunner(t, scaler)
	if err := scaler.HandleJobStarted(context.Background(), &scaleset.JobStarted{
		RunnerID:   int(runner.runnerID),
		RunnerName: runner.runnerName,
	}); err != nil {
		t.Fatal(err)
	}
	snapshot := scaler.snapshot()
	if snapshot.runners[0].state != runnerBusy || snapshot.statistics.assignedJobs != 1 {
		t.Fatalf("job start changed the wrong state: %#v", snapshot)
	}
	if err := scaler.HandleJobCompleted(context.Background(), &scaleset.JobCompleted{
		RunnerID:   int(runner.runnerID),
		RunnerName: runner.runnerName,
	}); err != nil {
		t.Fatal(err)
	}
	snapshot = scaler.snapshot()
	if snapshot.runners[0].state != runnerDraining || snapshot.statistics.assignedJobs != 1 {
		t.Fatalf("job completion changed demand or failed to drain: %#v", snapshot)
	}
}

func TestRecoveredRunnerIsProtectedUntilLifecycleSignal(t *testing.T) {
	scaler, api, docker, _, cancel := newTestScaler(t, 1, 0, 0)
	defer cancel()
	err := scaler.recover(recoveredContainer{
		containerID: "recovered-container",
		name:        "recovered",
		runnerName:  "recovered-runner",
		runnerID:    77,
		targetKey:   "repo-1234",
		slotKey:     "repo-1234-77",
		createdAt:   time.Date(2026, 7, 20, 11, 0, 0, 0, time.UTC),
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	if len(api.removeCalls) != 0 {
		t.Fatal("protected recovered runner was removed")
	}
	scaler.handleLogSignal("recovered-container", "Listening for Jobs")
	if err := scaler.tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(api.removeCalls, []int64{77}) ||
		!reflect.DeepEqual(docker.stopRemove, []string{"recovered-container"}) {
		t.Fatalf("recovered runner was not removed after becoming safely idle")
	}
}

func TestStaleIdleRunnerRollsToCurrentRevision(t *testing.T) {
	scaler, api, docker, _, cancel := newTestScaler(t, 1, 1, 0)
	defer cancel()
	if err := scaler.recover(recoveredContainer{
		containerID: "stale-container",
		name:        "stale",
		runnerName:  "stale-runner",
		runnerID:    77,
		targetKey:   "repo-1234",
		slotKey:     "repo-1234-77",
		revision:    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		createdAt:   time.Date(2026, 7, 20, 11, 0, 0, 0, time.UTC),
	}); err != nil {
		t.Fatal(err)
	}

	if err := scaler.tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(api.removeCalls, []int64{77}) ||
		!reflect.DeepEqual(docker.stopRemove, []string{"stale-container"}) {
		t.Fatalf(
			"stale idle runner was not fenced and removed: api=%#v docker=%#v",
			api.removeCalls,
			docker.stopRemove,
		)
	}
	snapshot := scaler.snapshot()
	if len(snapshot.runners) != 1 ||
		snapshot.runners[0].stale ||
		snapshot.runners[0].revision != testWorkerRevision {
		t.Fatalf("replacement runner did not use the current revision: %#v", snapshot)
	}
}

func TestStaleBusyRunnerSurvivesRollingUpdate(t *testing.T) {
	scaler, api, docker, _, cancel := newTestScaler(t, 1, 1, 0)
	defer cancel()
	api.removeErrors[77] = scaleset.JobStillRunningError
	if err := scaler.recover(recoveredContainer{
		containerID: "busy-container",
		name:        "busy",
		runnerName:  "busy-runner",
		runnerID:    77,
		targetKey:   "repo-1234",
		slotKey:     "repo-1234-77",
		revision:    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		createdAt:   time.Date(2026, 7, 20, 11, 0, 0, 0, time.UTC),
	}); err != nil {
		t.Fatal(err)
	}

	if err := scaler.tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	runner := findRunner(t, scaler)
	if runner.state != runnerBusy || !runner.stale {
		t.Fatalf("busy stale runner was not preserved: %#v", runner)
	}
	if len(docker.stopRemove) != 0 || len(docker.stops) != 0 {
		t.Fatal("rolling update stopped a busy stale runner")
	}
	if err := scaler.tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(api.removeCalls, []int64{77}) {
		t.Fatalf("known-busy stale runner was repeatedly fenced: %#v", api.removeCalls)
	}
}

func TestStaleRunnerFenceFailureUsesRetryDelay(t *testing.T) {
	scaler, api, _, clock, cancel := newTestScaler(t, 1, 1, 0)
	defer cancel()
	api.removeErrors[77] = errors.New("temporary fence failure")
	if err := scaler.recover(recoveredContainer{
		containerID: "stale-container",
		name:        "stale",
		runnerName:  "stale-runner",
		runnerID:    77,
		targetKey:   "repo-1234",
		slotKey:     "repo-1234-77",
		revision:    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		createdAt:   time.Date(2026, 7, 20, 11, 0, 0, 0, time.UTC),
	}); err != nil {
		t.Fatal(err)
	}

	if err := scaler.tick(context.Background()); err == nil {
		t.Fatal("expected the first stale-runner fence to fail")
	}
	if err := scaler.tick(context.Background()); err != nil {
		t.Fatalf("retry delay should suppress the immediate retry: %v", err)
	}
	if !reflect.DeepEqual(api.removeCalls, []int64{77}) {
		t.Fatalf("stale runner was retried before its delay: %#v", api.removeCalls)
	}
	clock.advance(staleFenceRetryDelay)
	if err := scaler.tick(context.Background()); err == nil {
		t.Fatal("expected the delayed stale-runner fence to retry and fail")
	}
	if !reflect.DeepEqual(api.removeCalls, []int64{77, 77}) {
		t.Fatalf("stale runner did not retry after its delay: %#v", api.removeCalls)
	}
}

func TestRecoveredReadLogFailureReplaysFromCreationAndRetiresIdleRunner(t *testing.T) {
	scaler, api, docker, _, cancel := newTestScaler(t, 1, 0, 0)
	defer cancel()
	createdAt := time.Date(2026, 7, 20, 11, 0, 0, 0, time.UTC)
	docker.readLogErrors["recovered-container"] = errors.New("historical logs unavailable")
	docker.followLines["recovered-container"] = []string{"Listening for Jobs"}
	docker.followObserved = make(chan fakeFollowRequest, 1)
	api.removeErrors[77] = scaleset.RunnerNotFoundError
	if err := scaler.recover(recoveredContainer{
		containerID: "recovered-container",
		name:        "recovered",
		runnerName:  "recovered-runner",
		runnerID:    77,
		targetKey:   "repo-1234",
		slotKey:     "repo-1234-77",
		createdAt:   createdAt,
	}); err != nil {
		t.Fatal(err)
	}
	select {
	case request := <-docker.followObserved:
		if request.containerID != "recovered-container" ||
			!request.since.Equal(createdAt) {
			t.Fatalf("historical replay started at the wrong point: %#v", request)
		}
	case <-time.After(time.Second):
		t.Fatal("historical log replay did not start")
	}
	runner := findRunner(t, scaler)
	if runner.state != runnerIdle || runner.protected {
		t.Fatalf("replayed idle signal did not establish safe state: %#v", runner)
	}

	if err := scaler.beginRetirement(context.Background()); err != nil {
		t.Fatal(err)
	}
	if scaler.runnerCount() != 0 ||
		!reflect.DeepEqual(api.removeCalls, []int64{77}) ||
		!reflect.DeepEqual(docker.stopRemove, []string{"recovered-container"}) {
		t.Fatalf(
			"idle recovered runner was not retired safely: api=%#v docker=%#v",
			api.removeCalls,
			docker.stopRemove,
		)
	}
}

func TestProtectedRecoveredRetirementProbesAndPreservesBusyRunner(t *testing.T) {
	scaler, api, docker, _, cancel := newTestScaler(t, 1, 0, 0)
	defer cancel()
	docker.readLogErrors["recovered-container"] = errors.New("historical logs unavailable")
	api.removeErrors[77] = scaleset.JobStillRunningError
	if err := scaler.recover(recoveredContainer{
		containerID: "recovered-container",
		name:        "recovered",
		runnerName:  "recovered-runner",
		runnerID:    77,
		targetKey:   "repo-1234",
		slotKey:     "repo-1234-77",
		createdAt:   time.Date(2026, 7, 20, 11, 0, 0, 0, time.UTC),
	}); err != nil {
		t.Fatal(err)
	}

	err := scaler.beginRetirement(context.Background())
	if !errors.Is(err, scaleset.JobStillRunningError) {
		t.Fatalf("busy registration probe error was not preserved: %v", err)
	}
	runner := findRunner(t, scaler)
	if runner.state != runnerBusy || runner.protected {
		t.Fatalf("busy recovered runner was not preserved safely: %#v", runner)
	}
	if !reflect.DeepEqual(api.removeCalls, []int64{77}) {
		t.Fatalf("retirement did not probe the protected registration: %#v", api.removeCalls)
	}
	if len(docker.stopRemove) != 0 || len(docker.stops) != 0 {
		t.Fatal("busy recovered runner container was stopped")
	}
	if err := scaler.tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(api.removeCalls, []int64{77}) {
		t.Fatal("known-busy recovered runner was repeatedly probed")
	}
}

func TestRecoveredRunnerAlreadyRemovedFromGitHubStillCleansContainer(t *testing.T) {
	scaler, api, docker, _, cancel := newTestScaler(t, 1, 0, 0)
	defer cancel()
	docker.logs["recovered-container"] = []string{"Listening for Jobs"}
	api.removeErrors[77] = scaleset.RunnerNotFoundError
	if err := scaler.recover(recoveredContainer{
		containerID: "recovered-container",
		name:        "recovered",
		runnerName:  "recovered-runner",
		runnerID:    77,
		targetKey:   "repo-1234",
		slotKey:     "repo-1234-77",
		createdAt:   time.Date(2026, 7, 20, 11, 0, 0, 0, time.UTC),
	}); err != nil {
		t.Fatal(err)
	}

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 0); err != nil {
		t.Fatalf("already-absent registration blocked recovery cleanup: %v", err)
	}
	if scaler.runnerCount() != 0 ||
		!reflect.DeepEqual(api.removeCalls, []int64{77}) ||
		!reflect.DeepEqual(docker.stopRemove, []string{"recovered-container"}) {
		t.Fatalf(
			"crash-after-remove recovery did not clean the container: api=%#v docker=%#v",
			api.removeCalls,
			docker.stopRemove,
		)
	}
}

func TestRecoveredRunnerUsesLatestHistoricalLifecycleSignal(t *testing.T) {
	scaler, _, docker, _, cancel := newTestScaler(t, 1, 0, 0)
	defer cancel()
	docker.logs["recovered-container"] = []string{
		"Listening for Jobs",
		"Running job: build",
	}
	err := scaler.recover(recoveredContainer{
		containerID: "recovered-container",
		name:        "recovered",
		runnerName:  "recovered-runner",
		runnerID:    77,
		targetKey:   "repo-1234",
		slotKey:     "repo-1234-77",
		createdAt:   time.Date(2026, 7, 20, 11, 0, 0, 0, time.UTC),
	})
	if err != nil {
		t.Fatal(err)
	}
	runner := findRunner(t, scaler)
	if runner.state != runnerBusy || runner.protected {
		t.Fatalf("historical logs did not establish the latest recovered state: %#v", runner)
	}
}

func TestDockerWaitErrorPreservesStillRunningContainer(t *testing.T) {
	scaler, api, docker, _, cancel := newTestScaler(t, 1, 0, time.Minute)
	defer cancel()
	docker.waitResults["container-1"] = []fakeWaitResult{{
		err: errors.New("temporary Docker wait failure"),
	}}
	docker.waitObserved = make(chan string, 1)
	docker.runningObserved = make(chan string, 1)

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	select {
	case <-docker.waitObserved:
	case <-time.After(time.Second):
		t.Fatal("Docker wait failure was not observed")
	}
	select {
	case <-docker.runningObserved:
	case <-time.After(time.Second):
		t.Fatal("container running state was not checked after wait failure")
	}
	runner := findRunner(t, scaler)
	if runner.containerID != "container-1" || api.jitCalls != 1 {
		t.Fatalf("wait error discarded a live runner or launched a duplicate: %#v", runner)
	}
}

func TestUnexpectedStoppedRunnerIsRemovedAndRetried(t *testing.T) {
	scaler, api, _, _, cancel := newTestScaler(t, 1, 0, time.Minute)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	first := findRunner(t, scaler)
	scaler.handleContainerExit(first.containerID, 137)
	replacement := findRunner(t, scaler)
	if replacement.containerID == first.containerID {
		t.Fatal("unexpectedly exited runner was not replaced")
	}
	if api.jitCalls != 2 {
		t.Fatalf("expected demand retry to generate a second JIT runner, got %d", api.jitCalls)
	}
}

func TestCompletedRunnerExitRestoresMinimumIdle(t *testing.T) {
	scaler, api, _, _, cancel := newTestScaler(t, 2, 1, time.Minute)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	runner := findRunner(t, scaler)
	if err := scaler.HandleJobCompleted(context.Background(), &scaleset.JobCompleted{
		RunnerID:   int(runner.runnerID),
		RunnerName: runner.runnerName,
	}); err != nil {
		t.Fatal(err)
	}
	scaler.handleContainerExit(runner.containerID, 0)
	replacement := findRunner(t, scaler)
	if replacement.containerID == runner.containerID || api.jitCalls != 2 {
		t.Fatal("minimum-idle capacity was not restored after the ephemeral runner exited")
	}
}

func TestShutdownTreatsMissingRegistrationAsAlreadyRemoved(t *testing.T) {
	scaler, api, docker, _, cancel := newTestScaler(t, 1, 0, time.Minute)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	markAllRunnersIdle(scaler)
	runner := findRunner(t, scaler)
	api.removeErrors[runner.runnerID] = scaleset.RunnerNotFoundError

	if err := scaler.shutdown(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(docker.stopRemove, []string{runner.containerID}) {
		t.Fatalf("missing registration blocked shutdown cleanup: %#v", docker.stopRemove)
	}
}

func TestShutdownSignalsMultipleRunnersConcurrently(t *testing.T) {
	scaler, _, docker, _, cancel := newTestScaler(t, 3, 0, time.Minute)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 3); err != nil {
		t.Fatal(err)
	}
	docker.stopStarted = make(chan string, 3)
	stopContinue := make(chan struct{})
	docker.stopContinue = stopContinue
	result := make(chan error, 1)
	go func() {
		result <- scaler.shutdown(context.Background())
	}()

	started := make(map[string]struct{})
	for len(started) < 3 {
		select {
		case containerID := <-docker.stopStarted:
			started[containerID] = struct{}{}
		case <-time.After(time.Second):
			t.Fatalf(
				"runner stops were serialized; only %d started concurrently",
				len(started),
			)
		}
	}
	close(stopContinue)
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("concurrent shutdown did not complete")
	}
	if managerShutdownTimeout > 55*time.Second {
		t.Fatalf("manager shutdown timeout exceeds Compose budget: %s", managerShutdownTimeout)
	}
}

func TestShutdownDeadlineBoundsBlockedDockerOperation(t *testing.T) {
	scaler, _, docker, _, cancel := newTestScaler(t, 1, 0, time.Minute)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	docker.stopStarted = make(chan string, 1)
	stopContinue := make(chan struct{})
	docker.stopContinue = stopContinue
	shutdownContext, shutdownCancel := context.WithTimeout(
		context.Background(),
		30*time.Millisecond,
	)
	defer shutdownCancel()

	startedAt := time.Now()
	result := make(chan error, 1)
	go func() {
		result <- scaler.shutdown(shutdownContext)
	}()
	select {
	case <-docker.stopStarted:
	case <-time.After(time.Second):
		close(stopContinue)
		t.Fatal("shutdown did not attempt the blocked Docker operation")
	}
	var err error
	select {
	case err = <-result:
	case <-time.After(300 * time.Millisecond):
		close(stopContinue)
		t.Fatal("shutdown did not return after its context deadline")
	}
	elapsed := time.Since(startedAt)
	close(stopContinue)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("blocked Docker operation did not honor shutdown deadline: %v", err)
	}
	if elapsed > 300*time.Millisecond {
		t.Fatalf("shutdown exceeded its context deadline: %s", elapsed)
	}
}

func TestWorkerLaunchContainsNoAccessToken(t *testing.T) {
	launch := containerLaunch{
		name:      "runner-one",
		image:     "example/runner:latest",
		jitConfig: "encoded-jit-secret",
		labels: map[string]string{
			managedProfileLabelKey: "profile-a",
			managedSlotLabelKey:    "repo-1-99",
			autoscalerLabelKey:     "true",
			targetKeyLabelKey:      "repo-1",
			runnerNameLabelKey:     "runner-one",
			runnerIDLabelKey:       "99",
		},
	}
	arguments := buildDockerRunArguments(launch)
	command := strings.Join(arguments, " ")
	if strings.Contains(command, "ACCESS_TOKEN") ||
		strings.Contains(command, "pat-super-secret") {
		t.Fatalf("worker command contains a PAT: %s", command)
	}
	for _, expected := range []string{
		"--rm", "--detach", "--init", "--user runner",
		"--workdir /actions-runner",
		"--entrypoint /actions-runner/bin/Runner.Listener",
		"ACTIONS_RUNNER_INPUT_JITCONFIG=encoded-jit-secret",
		"example/runner:latest run",
		targetKeyLabelKey + "=repo-1",
		runnerNameLabelKey + "=runner-one",
		runnerIDLabelKey + "=99",
	} {
		if !strings.Contains(command, expected) {
			t.Fatalf("worker command omitted %q: %s", expected, command)
		}
	}
}
