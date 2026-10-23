package main

import (
	"strings"
	"testing"
)

func nestedDockerLaunch() containerLaunch {
	memory := int64(3221225472)
	storage := int64(2147483648)
	pids := int64(1024)
	return containerLaunch{
		name: "test-worker", image: "example/runner:qualification", jitConfig: "synthetic",
		resources: workerResourcePolicy{
			memoryBytes: &memory, memorySwapBytes: &memory, cpuCores: "1", pids: &pids,
		},
		runtime: workerRuntimePolicy{dockerMode: "privileged-local", dockerStorageBytes: &storage},
	}
}

func TestNestedDockerLaunchKeepsTheDaemonInsideTheDisposableWorker(t *testing.T) {
	launch := nestedDockerLaunch()
	for _, arguments := range [][]string{buildDockerRunArguments(launch), buildDockerCreateArguments(launch)} {
		joined := strings.Join(arguments, " ")
		for _, expected := range []string{
			"--rm", "--init", "--privileged --cgroupns private",
			"--memory 3221225472 --memory-swap 3221225472 --cpus 1 --pids-limit 1024",
			"--tmpfs /var/lib/pitcrew-docker:rw,exec,nosuid,nodev,size=2147483648",
			"--entrypoint /bin/sh", "DOCKER_HOST=unix:///run/pitcrew-docker/docker.sock",
			"PITCREW_NESTED_DOCKER_VERIFY_ONLY=0",
			"pitcrew-nested-docker run",
		} {
			if !strings.Contains(joined, expected) {
				t.Fatalf("nested launch omitted %q", expected)
			}
		}
		for _, forbidden := range []string{
			"/var/run/docker.sock:", "--network host", "--pid host", "--publish", "tcp://",
		} {
			if strings.Contains(joined, forbidden) {
				t.Fatalf("nested launch exposed forbidden authority %q", forbidden)
			}
		}
		if strings.Index(nestedDockerBootstrap, "status=ready") >
			strings.Index(nestedDockerBootstrap, `/actions-runner/bin/Runner.Listener "$@"`) {
			t.Fatal("runner can start before daemon readiness")
		}
	}
}

func TestNestedDockerRejectsUnsupportedBudgetsBeforeCallingDocker(t *testing.T) {
	cases := []struct {
		name   string
		change func(*containerLaunch)
	}{
		{"arbitrary mode", func(l *containerLaunch) { l.runtime.dockerMode = "host" }},
		{"missing storage", func(l *containerLaunch) { l.runtime.dockerStorageBytes = nil }},
		{"storage without mode", func(l *containerLaunch) { l.runtime.dockerMode = "" }},
		{"missing memory", func(l *containerLaunch) { l.resources.memoryBytes = nil }},
		{"missing swap", func(l *containerLaunch) { l.resources.memorySwapBytes = nil }},
		{"swapping", func(l *containerLaunch) { swap := int64(4294967296); l.resources.memorySwapBytes = &swap }},
		{"missing cpu", func(l *containerLaunch) { l.resources.cpuCores = "" }},
		{"missing pids", func(l *containerLaunch) { l.resources.pids = nil }},
		{"storage over budget", func(l *containerLaunch) { l.runtime.dockerStorageBytes = l.resources.memoryBytes }},
		{"device", func(l *containerLaunch) { l.runtime.devices = []string{"kvm"} }},
		{"network", func(l *containerLaunch) { l.network = "other-services" }},
		{"volume", func(l *containerLaunch) { l.volumes = []externalVolume{{name: "data", source: "data"}} }},
	}
	for _, scenario := range cases {
		t.Run(scenario.name, func(t *testing.T) {
			launch := nestedDockerLaunch()
			scenario.change(&launch)
			executor := newScriptedCommandExecutor(map[string][]scriptedCommandResult{})
			client := &dockerCLI{executor: executor}
			if _, err := client.run(t.Context(), launch); err == nil {
				t.Fatal("invalid nested runtime reached docker run")
			}
			if _, err := client.create(t.Context(), launch); err == nil {
				t.Fatal("invalid nested runtime reached docker create")
			}
			if len(executor.calls) != 0 {
				t.Fatal("invalid nested runtime called the Docker boundary")
			}
		})
	}
}

func TestOrdinaryWorkersRetainTheDirectListenerAndNoNestedAuthority(t *testing.T) {
	arguments := buildDockerRunArguments(containerLaunch{name: "ordinary", image: "example/runner:1"})
	joined := strings.Join(arguments, " ")
	if !strings.Contains(joined, "--entrypoint /actions-runner/bin/Runner.Listener") ||
		arguments[len(arguments)-1] != "run" {
		t.Fatal("ordinary worker no longer starts the listener directly")
	}
	for _, forbidden := range []string{"--privileged", "--cgroupns", "--tmpfs", "DOCKER_HOST", "dockerd"} {
		if strings.Contains(joined, forbidden) {
			t.Fatalf("ordinary worker acquired nested capability %q", forbidden)
		}
	}
}

func TestNestedDockerEnvironmentParsingFailsClosed(t *testing.T) {
	for _, inputs := range []map[string]string{
		{"PITCREW_WORKER_DOCKER_MODE": "rootless"},
		{"PITCREW_WORKER_DOCKER_MODE": "privileged-local"},
		{"PITCREW_WORKER_DOCKER_STORAGE_BYTES": "1073741824"},
		{"PITCREW_WORKER_DOCKER_MODE": "privileged-local", "PITCREW_WORKER_DOCKER_STORAGE_BYTES": "-1"},
	} {
		_, err := loadWorkerRuntimePolicy(func(key, fallback string) string {
			if value, found := inputs[key]; found {
				return value
			}
			return fallback
		})
		if err == nil {
			t.Fatal("invalid nested Docker environment was accepted")
		}
	}
}

func TestNestedDockerMetadataPreflightRejectsUnsupportedHostsAndImages(t *testing.T) {
	for _, scenario := range []struct {
		name  string
		host  string
		image string
		valid bool
	}{
		{"supported", "linux|x86_64|2|name=seccomp", "linux|amd64||0", true},
		{"non-root", "linux|x86_64|2|", "linux|amd64|1001|0", false},
		{"anonymous-volume", "linux|x86_64|2|", "linux|amd64|root|1", false},
		{"emulation", "linux|x86_64|2|", "linux|arm64|root|0", false},
		{"rootless", "linux|x86_64|2|name=rootless", "", false},
		{"user-namespace", "linux|x86_64|2|name=userns", "", false},
		{"cgroup-v1", "linux|x86_64|1|", "", false},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			executor := newScriptedCommandExecutor(map[string][]scriptedCommandResult{
				"info":  {{output: scenario.host}},
				"image": {{output: scenario.image}},
			})
			client := &dockerCLI{executor: executor}
			err := client.validateNestedDockerImage(t.Context(), "example/fixture")
			if (err == nil) != scenario.valid {
				t.Fatalf("metadata validation result did not match supported contract: %v", err)
			}
			for _, call := range executor.calls {
				if !call.hasDeadline {
					t.Fatal("metadata preflight omitted its external-call deadline")
				}
			}
		})
	}
}
