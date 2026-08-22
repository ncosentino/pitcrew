package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

func contractInputs() map[string]string {
	return map[string]string{
		"ACCESS_TOKEN":            "pat-value",
		"RUNNER_PROFILE_ID":       "profile-a",
		"RUNNER_IMAGE":            "example/runner:latest",
		"PITCREW_WORKER_REVISION": testWorkerRevision,
		"PITCREW_SESSION_OWNER":   "pitcrew-profile-a",
		"RUNNER_SCOPE":            "repo",
		"RUNNER_NAME_PREFIX":      "runner",
	}
}

func loadContractConfig(values map[string]string) (config, error) {
	return loadConfig(func(name string) (string, bool) {
		value, exists := values[name]
		return value, exists
	}, "amd64")
}

func TestLoadConfigReadsResourcePolicyAndCeiling(t *testing.T) {
	values := contractInputs()
	values["PITCREW_WORKER_IMAGE_ID"] = "sha256:" + strings.Repeat("1", 64)
	values["PITCREW_WORKER_MEMORY_BYTES"] = "8589934592"
	values["PITCREW_WORKER_MEMORY_SWAP_BYTES"] = "10737418240"
	values["PITCREW_WORKER_CPU_CORES"] = "2.5"
	values["PITCREW_WORKER_PIDS_LIMIT"] = "1024"
	values["PITCREW_AUTOSCALING_MAX_ACTIVE_WORKERS"] = "6"

	cfg, err := loadContractConfig(values)
	if err != nil {
		t.Fatalf("loadConfig returned an error: %v", err)
	}
	if cfg.maximumActiveWorkers != 6 {
		t.Fatalf("unexpected ceiling %d", cfg.maximumActiveWorkers)
	}
	if cfg.workerImageID != values["PITCREW_WORKER_IMAGE_ID"] {
		t.Fatalf("unexpected image identity %q", cfg.workerImageID)
	}
	if cfg.resources.memoryBytes == nil || *cfg.resources.memoryBytes != 8589934592 ||
		cfg.resources.memorySwapBytes == nil || *cfg.resources.memorySwapBytes != 10737418240 ||
		cfg.resources.cpuCores != "2.5" ||
		cfg.resources.pids == nil || *cfg.resources.pids != 1024 {
		t.Fatalf("unexpected resource policy %+v", cfg.resources)
	}
}

func TestLoadConfigTreatsEmptyContractInputsAsUnconfigured(t *testing.T) {
	values := contractInputs()
	values["PITCREW_WORKER_IMAGE_ID"] = ""
	values["PITCREW_WORKER_MEMORY_BYTES"] = ""
	values["PITCREW_WORKER_MEMORY_SWAP_BYTES"] = ""
	values["PITCREW_WORKER_CPU_CORES"] = ""
	values["PITCREW_WORKER_PIDS_LIMIT"] = ""
	values["PITCREW_AUTOSCALING_MAX_ACTIVE_WORKERS"] = ""

	cfg, err := loadContractConfig(values)
	if err != nil {
		t.Fatalf("loadConfig returned an error: %v", err)
	}
	if cfg.resources.configured() {
		t.Fatalf("empty inputs became a resource policy: %+v", cfg.resources)
	}
	if cfg.maximumActiveWorkers != 0 || cfg.workerImageID != "" {
		t.Fatal("empty inputs became configured values")
	}
	if len(cfg.resources.dockerArguments()) != 0 {
		t.Fatal("unconfigured policy produced Docker arguments")
	}
}

func TestLoadConfigRejectsInvalidResourcePolicy(t *testing.T) {
	tests := []struct {
		name  string
		key   string
		value string
	}{
		{name: "memory below floor", key: "PITCREW_WORKER_MEMORY_BYTES", value: "1048576"},
		{name: "memory zero", key: "PITCREW_WORKER_MEMORY_BYTES", value: "0"},
		{name: "memory unlimited", key: "PITCREW_WORKER_MEMORY_BYTES", value: "-1"},
		{name: "swap without memory", key: "PITCREW_WORKER_MEMORY_SWAP_BYTES", value: "10737418240"},
		{name: "cpu zero", key: "PITCREW_WORKER_CPU_CORES", value: "0"},
		{name: "cpu unlimited", key: "PITCREW_WORKER_CPU_CORES", value: "-1"},
		{name: "cpu too precise", key: "PITCREW_WORKER_CPU_CORES", value: "1.0123456789"},
		{name: "cpu leading zero", key: "PITCREW_WORKER_CPU_CORES", value: "01"},
		{name: "pids zero", key: "PITCREW_WORKER_PIDS_LIMIT", value: "0"},
		{name: "pids unlimited", key: "PITCREW_WORKER_PIDS_LIMIT", value: "-1"},
		{name: "ceiling zero", key: "PITCREW_AUTOSCALING_MAX_ACTIVE_WORKERS", value: "0"},
		{name: "ceiling negative", key: "PITCREW_AUTOSCALING_MAX_ACTIVE_WORKERS", value: "-2"},
		{name: "image identity", key: "PITCREW_WORKER_IMAGE_ID", value: "latest"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			values := contractInputs()
			values[test.key] = test.value
			if _, err := loadContractConfig(values); err == nil {
				t.Fatalf("%s=%s was accepted", test.key, test.value)
			}
		})
	}
}

func TestLoadConfigRejectsSwapBelowMemory(t *testing.T) {
	values := contractInputs()
	values["PITCREW_WORKER_MEMORY_BYTES"] = "10737418240"
	values["PITCREW_WORKER_MEMORY_SWAP_BYTES"] = "8589934592"
	if _, err := loadContractConfig(values); err == nil {
		t.Fatal("memory-swap below memory was accepted")
	}
}

func TestWorkerLaunchCarriesCanonicalResourceArguments(t *testing.T) {
	memory := int64(8589934592)
	swap := int64(10737418240)
	pids := int64(1024)
	arguments := buildDockerRunArguments(containerLaunch{
		name:      "worker",
		image:     "example/runner:latest",
		jitConfig: "encoded",
		resources: workerResourcePolicy{
			memoryBytes:     &memory,
			memorySwapBytes: &swap,
			cpuCores:        "2.5",
			pids:            &pids,
		},
		volumes: []readOnlyVolume{
			{name: "reference-data", source: "pitcrew-reference-data-v1"},
		},
		network: "pitcrew-profile-a-services",
	})
	joined := strings.Join(arguments, " ")
	for _, expected := range []string{
		"--memory 8589934592",
		"--memory-swap 10737418240",
		"--cpus 2.5",
		"--pids-limit 1024",
		"--network pitcrew-profile-a-services",
		"--mount type=volume,src=pitcrew-reference-data-v1,dst=/mnt/pitcrew-data/reference-data,readonly,volume-nocopy",
	} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("expected %q in %q", expected, joined)
		}
	}
	if strings.Index(joined, "--memory ") > strings.Index(joined, "--cpus") {
		t.Fatal("resource arguments are not in canonical order")
	}
	plain := buildDockerRunArguments(containerLaunch{name: "worker", image: "example/runner:latest"})
	if strings.Contains(strings.Join(plain, " "), "--memory") {
		t.Fatal("unconfigured policy produced resource arguments")
	}
	if strings.Contains(strings.Join(plain, " "), "--network") {
		t.Fatal("unconfigured service network produced a Docker argument")
	}
}

func TestDockerRunRejectsInvalidResourcePolicyBeforeLaunch(t *testing.T) {
	swap := int64(8589934592)
	client := &dockerCLI{executor: failingExecutor{}}
	_, err := client.run(context.Background(), containerLaunch{
		name:      "worker",
		image:     "example/runner:latest",
		resources: workerResourcePolicy{memorySwapBytes: &swap},
	})
	if err == nil {
		t.Fatal("invalid resource policy reached docker run")
	}
}

func TestWorkerLaunchCarriesBoundedRuntimeArguments(t *testing.T) {
	sharedMemory := int64(2147483648)
	arguments := buildDockerRunArguments(containerLaunch{
		name:      "worker",
		image:     "example/runner:latest",
		jitConfig: "encoded",
		runtime: workerRuntimePolicy{
			devices:           []string{"kvm"},
			sharedMemoryBytes: &sharedMemory,
		},
	})
	joined := strings.Join(arguments, " ")
	for _, expected := range []string{
		"--device /dev/kvm:/dev/kvm:rwm",
		"--shm-size 2147483648",
	} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("expected %q in %q", expected, joined)
		}
	}
	for _, forbidden := range []string{"--privileged", "/var/run/docker.sock"} {
		if strings.Contains(joined, forbidden) {
			t.Fatalf("runtime policy exposed forbidden Docker argument %q: %q", forbidden, joined)
		}
	}
}

func TestDockerRunRejectsInvalidRuntimePolicyBeforeLaunch(t *testing.T) {
	client := &dockerCLI{executor: failingExecutor{}}
	_, err := client.run(context.Background(), containerLaunch{
		name:    "worker",
		image:   "example/runner:latest",
		runtime: workerRuntimePolicy{devices: []string{"raw-device"}},
	})
	if err == nil {
		t.Fatal("invalid runtime policy reached docker run")
	}
}

func TestDockerVolumePreflightRequiresExactExistingNames(t *testing.T) {
	executor := newScriptedCommandExecutor(map[string][]scriptedCommandResult{
		"volume": {
			{output: "pitcrew-reference-data-v1\n"},
			{output: "wrong-volume\n"},
		},
	})
	client := &dockerCLI{executor: executor}
	volumes := []readOnlyVolume{
		{name: "reference-data", source: "pitcrew-reference-data-v1"},
	}
	if err := client.validateVolumes(context.Background(), volumes); err != nil {
		t.Fatalf("valid external volume was rejected: %v", err)
	}
	if err := client.validateVolumes(context.Background(), volumes); err == nil {
		t.Fatal("ambiguous external volume identity was accepted")
	}
	if len(executor.calls) != 2 {
		t.Fatalf("unexpected volume preflight calls: %#v", executor.calls)
	}
	for _, call := range executor.calls {
		joined := strings.Join(call.arguments, " ")
		if joined != "volume inspect --format {{.Name}} pitcrew-reference-data-v1" {
			t.Fatalf("unexpected volume preflight command: %s", joined)
		}
		if !call.hasDeadline {
			t.Fatal("external volume preflight had no deadline")
		}
	}
}

func TestDockerNetworkPreflightRequiresCompatibleExactNetwork(t *testing.T) {
	executor := newScriptedCommandExecutor(map[string][]scriptedCommandResult{
		"network": {
			{output: "pitcrew-profile-a-services|bridge|local|false\n"},
			{output: "pitcrew-profile-a-services|bridge|local|true\n"},
		},
	})
	client := &dockerCLI{executor: executor}
	if err := client.validateNetwork(
		context.Background(),
		"pitcrew-profile-a-services",
	); err != nil {
		t.Fatalf("valid external service network was rejected: %v", err)
	}
	if err := client.validateNetwork(
		context.Background(),
		"pitcrew-profile-a-services",
	); err == nil {
		t.Fatal("incompatible external service network was accepted")
	}
	if len(executor.calls) != 2 {
		t.Fatalf("unexpected service network preflight calls: %#v", executor.calls)
	}
	for _, call := range executor.calls {
		joined := strings.Join(call.arguments, " ")
		if joined != "network inspect --format {{.Name}}|{{.Driver}}|{{.Scope}}|{{.Internal}} pitcrew-profile-a-services" {
			t.Fatalf("unexpected service network preflight command: %s", joined)
		}
		if !call.hasDeadline {
			t.Fatal("external service network preflight had no deadline")
		}
	}
}

type failingExecutor struct{}

func (failingExecutor) run(context.Context, ...string) ([]byte, error) {
	return nil, errors.New("docker must not be invoked")
}

func (failingExecutor) stream(context.Context, []string, func(string)) error {
	return errors.New("docker must not be invoked")
}

func TestScalerLaunchesWorkersUnderConfiguredResourcePolicy(t *testing.T) {
	memory := int64(6291456)
	pids := int64(512)
	scaler, _, docker, cancel := newCeilingTestScaler(
		t,
		"repo-1234",
		2,
		newAdmissionController(0),
		func(cfg *config) {
			cfg.resources = workerResourcePolicy{memoryBytes: &memory, pids: &pids}
			cfg.workerImageID = "sha256:" + strings.Repeat("a", 64)
			cfg.readOnlyVolumes = []readOnlyVolume{
				{name: "reference-data", source: "pitcrew-reference-data-v1"},
			}
			cfg.serviceNetwork = "pitcrew-profile-a-services"
		},
	)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	if len(docker.launches) != 1 {
		t.Fatalf("expected one launch, got %d", len(docker.launches))
	}
	launch := docker.launches[0]
	if launch.resources.memoryBytes == nil || *launch.resources.memoryBytes != memory ||
		launch.resources.pids == nil || *launch.resources.pids != pids {
		t.Fatalf("worker launched without the configured policy: %+v", launch.resources)
	}
	if len(launch.volumes) != 1 ||
		launch.volumes[0].source != "pitcrew-reference-data-v1" {
		t.Fatalf("worker launched without the configured read-only volume: %+v", launch.volumes)
	}
	if launch.network != "pitcrew-profile-a-services" {
		t.Fatalf("worker launched without the configured service network: %q", launch.network)
	}
}

// newCeilingTestScaler builds a scaler bound to a shared admission controller so
// tests can prove profile-wide behavior across several targets.
func newCeilingTestScaler(
	t *testing.T,
	key string,
	maximum int,
	admission *admissionController,
	customize func(*config),
) (*runnerScaler, *fakeScaleSetService, *fakeDockerClient, context.CancelFunc) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	clock := &fakeClock{current: time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)}
	api := newFakeScaleSetService(&eventRecorder{})
	docker := newFakeDockerClient(&eventRecorder{})
	cfg := config{
		profileID:         "profile-a",
		runnerImage:       "example/runner:latest",
		workerRevision:    testWorkerRevision,
		sessionOwner:      "pitcrew-profile-a",
		assumeUnversioned: true,
		namePrefix:        "pitcrew-runner",
		scaleDownDelay:    10 * time.Minute,
	}
	if customize != nil {
		customize(&cfg)
	}
	scaler := newRunnerScaler(
		ctx,
		cfg,
		targetSpec{
			key:             key,
			registrationURL: "https://github.com/example/" + key,
			repository:      "https://github.com/example/" + key,
			maximum:         maximum,
			scaleSetName:    "pitcrew-profile-a-" + key,
		},
		42,
		api,
		docker,
		clock,
		admission,
		newHostAdmissionCoordinator(hostAdmissionConfig{}, cfg.profileID),
		newDiagnosticsRecorder("", "manager-instance", clock),
		testLogger(),
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
		return fmt.Sprintf("%s-suffix%02d", key, suffix), nil
	}
	return scaler, api, docker, cancel
}

func TestAdmissionCeilingBoundsAggregateWorkersAcrossTargets(t *testing.T) {
	admission := newAdmissionController(3)
	first, _, _, cancelFirst := newCeilingTestScaler(t, "repo-one", 5, admission, nil)
	defer cancelFirst()
	second, _, _, cancelSecond := newCeilingTestScaler(t, "repo-two", 5, admission, nil)
	defer cancelSecond()

	if _, err := first.HandleDesiredRunnerCount(context.Background(), 5); err != nil {
		t.Fatal(err)
	}
	if _, err := second.HandleDesiredRunnerCount(context.Background(), 5); err != nil {
		t.Fatal(err)
	}
	total := first.runnerCount() + second.runnerCount()
	if total > 3 {
		t.Fatalf("aggregate workers %d exceeded the ceiling", total)
	}
	if total != 3 {
		t.Fatalf("ceiling capacity was left unused: %d", total)
	}
	if first.runnerCount() > first.target.maximum ||
		second.runnerCount() > second.target.maximum {
		t.Fatal("a target exceeded its configured maximum")
	}
}

func TestFreedCeilingCapacityGoesToTheStarvedTarget(t *testing.T) {
	admission := newAdmissionController(3)
	first, _, _, cancelFirst := newCeilingTestScaler(t, "repo-one", 5, admission, nil)
	defer cancelFirst()
	second, _, _, cancelSecond := newCeilingTestScaler(t, "repo-two", 5, admission, nil)
	defer cancelSecond()

	if _, err := first.HandleDesiredRunnerCount(context.Background(), 5); err != nil {
		t.Fatal(err)
	}
	if _, err := second.HandleDesiredRunnerCount(context.Background(), 5); err != nil {
		t.Fatal(err)
	}
	if second.runnerCount() != 0 {
		t.Fatalf("expected the ceiling to be held by the first target, got %d", second.runnerCount())
	}

	exiting := first.snapshot().runners[0]
	first.handleContainerExit(exiting.containerID, exitStatus(0))
	if err := second.tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if second.runnerCount() == 0 {
		t.Fatal("freed ceiling capacity starved the waiting target")
	}
	if total := first.runnerCount() + second.runnerCount(); total > 3 {
		t.Fatalf("aggregate workers %d exceeded the ceiling", total)
	}
}

func TestSingleTargetUsesFullCeilingWhenOthersAreIdle(t *testing.T) {
	admission := newAdmissionController(4)
	busy, _, _, cancelBusy := newCeilingTestScaler(t, "repo-one", 6, admission, nil)
	defer cancelBusy()
	_, _, _, cancelIdle := newCeilingTestScaler(t, "repo-two", 6, admission, nil)
	defer cancelIdle()

	if _, err := busy.HandleDesiredRunnerCount(context.Background(), 6); err != nil {
		t.Fatal(err)
	}
	if busy.runnerCount() != 4 {
		t.Fatalf("expected the ceiling to be fully usable, got %d", busy.runnerCount())
	}
}

func TestConcurrentTargetAdmissionCannotOvershootCeiling(t *testing.T) {
	admission := newAdmissionController(4)
	scalers := make([]*runnerScaler, 0, 4)
	for index := range 4 {
		scaler, _, _, cancel := newCeilingTestScaler(
			t,
			fmt.Sprintf("repo-%d", index),
			4,
			admission,
			nil,
		)
		defer cancel()
		scalers = append(scalers, scaler)
	}

	var waitGroup sync.WaitGroup
	start := make(chan struct{})
	for _, scaler := range scalers {
		waitGroup.Add(1)
		go func() {
			defer waitGroup.Done()
			<-start
			if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 4); err != nil {
				t.Errorf("concurrent scale-up failed: %v", err)
			}
		}()
	}
	close(start)
	waitGroup.Wait()

	total := 0
	for _, scaler := range scalers {
		total += scaler.runnerCount()
	}
	if total > 4 {
		t.Fatalf("concurrent admission produced %d workers above the ceiling", total)
	}
}

func TestAdmissionRotatesRemainderSoNoTargetStarves(t *testing.T) {
	admission := newAdmissionController(1)
	live := map[string]int{"repo-one": 0, "repo-two": 0}
	for key := range live {
		admission.join(key, func() int { return live[key] })
	}
	granted := map[string]int{}
	for range 4 {
		for _, key := range []string{"repo-one", "repo-two"} {
			if admission.reserve(key, 1) == 1 {
				granted[key]++
				admission.settle(key, 1)
			}
		}
	}
	if granted["repo-one"] == 0 || granted["repo-two"] == 0 {
		t.Fatalf("contended admission starved a target: %+v", granted)
	}
}

func TestAdmissionWithoutCeilingIsUnlimited(t *testing.T) {
	admission := newAdmissionController(0)
	admission.join("repo-one", func() int { return 25 })
	if granted := admission.reserve("repo-one", 9); granted != 9 {
		t.Fatalf("unconfigured ceiling limited admission to %d", granted)
	}
}

func TestCeilingNeverRemovesLiveWorkers(t *testing.T) {
	admission := newAdmissionController(1)
	scaler, _, docker, cancel := newCeilingTestScaler(t, "repo-one", 2, admission, nil)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 2); err != nil {
		t.Fatal(err)
	}
	if scaler.runnerCount() != 1 {
		t.Fatalf("expected exactly one admitted worker, got %d", scaler.runnerCount())
	}
	runner := findRunner(t, scaler)
	scaler.handleLogSignal(runner.containerID, "Running job")
	if err := scaler.tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(docker.stopRemove) != 0 || len(docker.stops) != 0 {
		t.Fatal("the ceiling removed a busy worker")
	}
}

func TestLocalWorkersSurviveMismatchedRegisteredRunnerStatistics(t *testing.T) {
	for _, registered := range []int{0, 8} {
		t.Run(fmt.Sprintf("registered-%d", registered), func(t *testing.T) {
			scaler, api, docker, cancel := newCeilingTestScaler(
				t,
				"repo-one",
				2,
				newAdmissionController(0),
				nil,
			)
			defer cancel()
			if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 2); err != nil {
				t.Fatal(err)
			}
			markAllRunnersIdle(scaler)
			scaler.RecordStatistics(&scaleset.RunnerScaleSetStatistic{
				TotalAssignedJobs:      2,
				TotalRunningJobs:       2,
				TotalRegisteredRunners: registered,
				TotalBusyRunners:       registered,
			})
			if err := scaler.tick(context.Background()); err != nil {
				t.Fatal(err)
			}
			if scaler.runnerCount() != 2 {
				t.Fatalf("registered-runner statistics changed local capacity: %d", scaler.runnerCount())
			}
			if len(docker.stopRemove) != 0 || len(api.removeCalls) != 0 {
				t.Fatal("registered-runner statistics authorized a local removal")
			}
			snapshot := scaler.snapshot()
			target := observedTargetState(snapshot)
			if target.LocalActiveWorkers != 2 || target.LocalIdleWorkers != 2 {
				t.Fatalf("unexpected local counts %+v", target)
			}
			if target.Statistics == nil ||
				target.Statistics.RegisteredRunners != registered ||
				target.Statistics.ObservedAt == "" {
				t.Fatalf("scale-set statistics were not published separately: %+v", target.Statistics)
			}
		})
	}
}

func TestTargetStatisticsStayNullUntilGitHubReportsThem(t *testing.T) {
	target := observedTargetState(scalerSnapshot{
		target:        targetSpec{key: "repo-one", maximum: 3},
		targetSlots:   1,
		activeRunners: 1,
	})
	if target.Statistics != nil {
		t.Fatal("unobserved statistics were published as measured zeroes")
	}
	if target.LocalActiveWorkers != 1 || target.MaximumSlots != 3 {
		t.Fatalf("unexpected target projection %+v", target)
	}
}

func TestExitClassificationUsesDockerEvidence(t *testing.T) {
	observedAt := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	oom := true
	notOOM := false
	tests := []struct {
		name           string
		state          containerExitState
		inspected      bool
		classification string
		evidence       string
		expectOOMFlag  *bool
	}{
		{
			name:           "docker confirmed oom",
			state:          containerExitState{exitCode: 137, oomKilled: &oom},
			inspected:      true,
			classification: "oom-killed",
			evidence:       "docker-inspect",
			expectOOMFlag:  &oom,
		},
		{
			name:           "inspected sigkill without oom",
			state:          containerExitState{exitCode: 137, oomKilled: &notOOM},
			inspected:      true,
			classification: "sigkill",
			evidence:       "docker-inspect",
			expectOOMFlag:  &notOOM,
		},
		{
			name:           "wait only sigkill is not an oom",
			state:          containerExitState{exitCode: 137},
			classification: "sigkill",
			evidence:       "docker-wait",
		},
		{
			name:           "other signal",
			state:          containerExitState{exitCode: 143},
			classification: "signal",
			evidence:       "docker-wait",
		},
		{
			name:           "clean exit",
			state:          containerExitState{exitCode: 0},
			classification: "clean",
			evidence:       "docker-wait",
		},
		{
			name:           "ordinary error",
			state:          containerExitState{exitCode: 2},
			classification: "error",
			evidence:       "docker-wait",
		},
		{
			name:           "unobserved status",
			state:          containerExitState{exitCode: -1},
			classification: "unknown",
			evidence:       "unavailable",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			diagnostic := classifyContainerExit(test.state, test.inspected, observedAt)
			if diagnostic.Classification != test.classification {
				t.Fatalf("expected %q, got %q", test.classification, diagnostic.Classification)
			}
			if diagnostic.Evidence != test.evidence {
				t.Fatalf("expected evidence %q, got %q", test.evidence, diagnostic.Evidence)
			}
			if test.expectOOMFlag == nil && diagnostic.DockerOOMKilled != nil {
				t.Fatal("uninspected exit claimed Docker OOM evidence")
			}
			if test.expectOOMFlag != nil &&
				(diagnostic.DockerOOMKilled == nil ||
					*diagnostic.DockerOOMKilled != *test.expectOOMFlag) {
				t.Fatal("Docker OOM evidence was not preserved")
			}
			if diagnostic.ObservedAt != observedAt.Format(time.RFC3339) {
				t.Fatalf("unexpected observation time %q", diagnostic.ObservedAt)
			}
		})
	}
}

func TestLaunchFailureIsClassifiedSeparately(t *testing.T) {
	diagnostic := launchFailureDiagnostic(time.Now())
	if diagnostic.Classification != "launch-failure" || diagnostic.Evidence != "launch" {
		t.Fatalf("unexpected launch failure diagnostic %+v", diagnostic)
	}
	if diagnostic.ExitCode != nil || diagnostic.Signal != nil ||
		diagnostic.DockerOOMKilled != nil {
		t.Fatal("launch failure invented exit evidence")
	}
}

func TestExitEvidenceIsRetainedWithPendingRegistrationCleanup(t *testing.T) {
	directory := projectTestDirectory(t)
	scaler, api, docker, clock, cancel := newTestScalerInDirectory(
		t,
		1,
		0,
		10*time.Minute,
		directory,
	)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	runner := findRunner(t, scaler)
	oom := true
	docker.exitStates[runner.containerID] = containerExitState{exitCode: 137, oomKilled: &oom}
	api.removeErrors[runner.runnerID] = errors.New("registration removal failed")
	scaler.handleContainerExit(runner.containerID, exitStatus(137))

	snapshot := scaler.snapshot()
	if len(snapshot.pendingCleanups) != 1 {
		t.Fatalf("expected one pending cleanup, got %d", len(snapshot.pendingCleanups))
	}
	record := snapshot.pendingCleanups[0]
	if record.LastExit == nil || record.LastExit.Classification != "oom-killed" {
		t.Fatalf("exit evidence was not captured: %+v", record.LastExit)
	}

	restored := newRunnerScaler(
		scaler.lifecycleContext,
		config{
			profileID:      "profile-a",
			runnerImage:    "example/runner:latest",
			workerRevision: testWorkerRevision,
			namePrefix:     "pitcrew-runner",
			stateDirectory: directory,
			scaleDownDelay: 10 * time.Minute,
		},
		scaler.target,
		42,
		api,
		docker,
		clock,
		newAdmissionController(0),
		newHostAdmissionCoordinator(hostAdmissionConfig{}, "profile-a"),
		newDiagnosticsRecorder("", "manager-instance", clock),
		testLogger(),
		nil,
		func(error) {},
	)
	restoredSnapshot := restored.snapshot()
	if len(restoredSnapshot.pendingCleanups) != 1 {
		t.Fatalf("restart lost pending cleanup: %d", len(restoredSnapshot.pendingCleanups))
	}
	restoredRecord := restoredSnapshot.pendingCleanups[0]
	if restoredRecord.RunnerID != record.RunnerID ||
		restoredRecord.ContainerID != record.ContainerID {
		t.Fatal("restored evidence lost its worker identity")
	}
	if restoredRecord.LastExit == nil ||
		restoredRecord.LastExit.Classification != "oom-killed" {
		t.Fatalf("exit evidence did not survive restart: %+v", restoredRecord.LastExit)
	}
}

func TestRegistrationCleanupBacklogKeepsAmbiguousRunnerRegistered(t *testing.T) {
	scaler, api, docker, _, cancel := newTestScalerInDirectory(
		t,
		2,
		0,
		10*time.Minute,
		projectTestDirectory(t),
	)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 2); err != nil {
		t.Fatal(err)
	}
	snapshot := scaler.snapshot()
	exited := snapshot.runners[0]
	live := snapshot.runners[1]
	scaler.handleLogSignal(live.containerID, "Running job")
	api.removeErrors[exited.runnerID] = errors.New("registration removal failed")
	scaler.handleContainerExit(exited.containerID, exitStatus(0))

	if err := scaler.tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, removed := range api.removeCalls {
		if removed == live.runnerID {
			t.Fatal("cleanup backlog deregistered a busy runner")
		}
	}
	if len(docker.stopRemove) != 0 {
		t.Fatal("cleanup backlog removed a live worker container")
	}
	if scaler.pendingRegistrationCount() != 1 {
		t.Fatalf("pending cleanup was dropped: %d", scaler.pendingRegistrationCount())
	}
	if scaler.runnerCount() != 1 {
		t.Fatalf("expected the busy runner to remain, got %d", scaler.runnerCount())
	}
}

func TestObservedStatePublishesContractElevenEvidence(t *testing.T) {
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	memory := int64(8589934592)
	cfg := config{
		profileID:            "profile-a",
		scope:                "repo",
		workerRevision:       testWorkerRevision,
		workerImageID:        "sha256:" + strings.Repeat("b", 64),
		maximumActiveWorkers: 6,
		resources:            workerResourcePolicy{memoryBytes: &memory, cpuCores: "2.5"},
		scaleDownDelay:       120 * time.Second,
	}
	snapshot := scalerSnapshot{
		target:        targetSpec{key: "repo-one", repository: "https://github.com/example/one", maximum: 8},
		targetSlots:   2,
		activeRunners: 1,
		busyRunners:   1,
		statistics: scalerStatistics{
			observedAt:        now,
			assignedJobs:      2,
			registeredRunners: 8,
			idleRunners:       6,
			busyRunners:       2,
		},
		runners: []runnerRecord{{
			key:              "repo-one-1",
			targetKey:        "repo-one",
			runnerName:       "runner-one",
			runnerID:         1,
			containerID:      "container-one",
			containerRunning: true,
			state:            runnerBusy,
			startedAt:        now.Add(-time.Minute),
			updatedAt:        now,
		}},
		pendingCleanups: []registrationCleanupRecord{{
			TargetKey:     "repo-one",
			SlotKey:       "repo-one-2",
			RunnerID:      2,
			RunnerName:    "runner-two",
			ContainerID:   "container-two",
			FirstFailedAt: now.Format(time.RFC3339),
			LastExit: &lastExitDiagnostic{
				ObservedAt:     now.Format(time.RFC3339),
				Classification: "oom-killed",
				Evidence:       "docker-inspect",
			},
		}},
	}
	state := buildObservedState(
		cfg,
		"instance",
		"running",
		nil,
		"accepted",
		[]scalerSnapshot{snapshot},
		nil,
		now,
	)
	if state.ResourcePolicy == nil || state.ResourcePolicy.MemoryBytes == nil ||
		*state.ResourcePolicy.MemoryBytes != memory ||
		state.ResourcePolicy.CPUCores == nil || *state.ResourcePolicy.CPUCores != "2.5" ||
		state.ResourcePolicy.PIDs != nil {
		t.Fatalf("unexpected resource policy projection %+v", state.ResourcePolicy)
	}
	if state.Autoscaling.MaximumActiveWorkers != 6 || len(state.Autoscaling.Targets) != 1 {
		t.Fatalf("unexpected aggregate autoscaling projection %+v", state.Autoscaling)
	}
	target := state.Autoscaling.Targets[0]
	if target.LocalActiveWorkers != 1 || target.LocalBusyWorkers != 1 ||
		target.Statistics == nil || target.Statistics.RegisteredRunners != 8 {
		t.Fatalf("local counts and statistics were not separated: %+v", target)
	}

	var live, cleanup *observedSlot
	for index := range state.Slots {
		switch state.Slots[index].Key {
		case "repo-one-1":
			live = &state.Slots[index]
		case "repo-one-2":
			cleanup = &state.Slots[index]
		}
	}
	if live == nil || live.ImageID == nil || *live.ImageID != cfg.workerImageID ||
		live.LastExit != nil {
		t.Fatalf("unexpected live slot evidence %+v", live)
	}
	if cleanup == nil || cleanup.LastExit == nil ||
		cleanup.LastExit.Classification != "oom-killed" || cleanup.Desired {
		t.Fatalf("unexpected cleanup slot evidence %+v", cleanup)
	}
	if state.EligibleSlots != 1 {
		t.Fatalf("cleanup slots changed eligible capacity: %d", state.EligibleSlots)
	}

	encoded, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{
		"\"maximumActiveWorkers\"",
		"\"targets\"",
		"\"resourcePolicy\"",
		"\"imageId\"",
		"\"lastExit\"",
	} {
		if !strings.Contains(string(encoded), field) {
			t.Fatalf("observed state omitted %s", field)
		}
	}
}

func TestUnconfiguredResourcePolicyPublishesNull(t *testing.T) {
	state := buildObservedState(
		config{profileID: "profile-a", scope: "repo", scaleDownDelay: time.Minute},
		"instance",
		"running",
		nil,
		"waiting",
		nil,
		nil,
		time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC),
	)
	if state.ResourcePolicy != nil {
		t.Fatal("unconfigured policy was published as a policy object")
	}
	if state.Autoscaling.MaximumActiveWorkers != 0 {
		t.Fatal("unconfigured ceiling was published as a limit")
	}
	encoded, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), "\"resourcePolicy\":null") {
		t.Fatal("resource policy was not published as null")
	}
}

func TestDockerStatsPublishCumulativeIOCounters(t *testing.T) {
	runners := []resourceContainer{{
		containerID:   "container-one",
		containerName: "worker-one",
		slotKey:       "repo-one-1",
	}}
	stats := `{"ID":"container-one","Name":"worker-one","CPUPerc":"25.00%","MemUsage":"512MiB / 8GiB","PIDs":"48","NetIO":"1.5MB / 512kB","BlockIO":"2MB / 0B"}`
	_, slots, err := parseDockerResourceStats([]byte(stats), "", runners)
	if err != nil {
		t.Fatal(err)
	}
	usage, exists := slots["repo-one-1"]
	if !exists {
		t.Fatal("worker usage was not matched")
	}
	if usage.NetworkRxBytes == nil || *usage.NetworkRxBytes != 1500000 ||
		usage.NetworkTxBytes == nil || *usage.NetworkTxBytes != 512000 ||
		usage.BlockReadBytes == nil || *usage.BlockReadBytes != 2000000 ||
		usage.BlockWriteBytes == nil || *usage.BlockWriteBytes != 0 {
		t.Fatalf("unexpected cumulative counters %+v", usage)
	}
}

func TestUnavailableIOCountersStayNull(t *testing.T) {
	runners := []resourceContainer{{containerID: "container-one", slotKey: "repo-one-1"}}
	stats := `{"ID":"container-one","CPUPerc":"25.00%","MemUsage":"512MiB / 8GiB","PIDs":"48","NetIO":"--","BlockIO":"0B / oops"}`
	_, slots, err := parseDockerResourceStats([]byte(stats), "", runners)
	if err != nil {
		t.Fatal(err)
	}
	usage := slots["repo-one-1"]
	if usage.NetworkRxBytes != nil || usage.NetworkTxBytes != nil {
		t.Fatal("unmeasured network counters were published")
	}
	if usage.BlockReadBytes == nil || *usage.BlockReadBytes != 0 {
		t.Fatal("a measured zero block counter was discarded")
	}
	if usage.BlockWriteBytes != nil {
		t.Fatal("an unparsable block counter was published")
	}
}
