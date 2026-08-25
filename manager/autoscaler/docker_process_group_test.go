//go:build !windows

package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// stubbornDockerScriptBody is a fake "docker" CLI that reproduces the exact
// process-tree shape a wedged docker logs/wait invocation can leave behind:
// it ignores SIGTERM at the shell level and spawns a grandchild that
// outlives it unless the whole process group is killed. Both PIDs are
// reported through env-var-named files so the test can independently verify
// each one actually exits.
const stubbornDockerScriptBody = `#!/bin/sh
trap '' TERM
sleep 30 &
echo $! > "$DOCKER_TEST_GRANDCHILD_PID_FILE"
echo $$ > "$DOCKER_TEST_PARENT_PID_FILE"
`

func writeStubbornDockerScript(t *testing.T, dir string, tail string) {
	t.Helper()
	path := filepath.Join(dir, "docker")
	if err := os.WriteFile(path, []byte(stubbornDockerScriptBody+tail+"\n"), 0o755); err != nil {
		t.Fatalf("write fake docker script: %v", err)
	}
}

func readPIDFile(t *testing.T, path string) int {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(path)
		if err == nil {
			if pid, convErr := strconv.Atoi(strings.TrimSpace(string(data))); convErr == nil {
				return pid
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("pid file %s was never written by the fake docker CLI", path)
	return 0
}

func processAlive(pid int) bool {
	return syscall.Kill(pid, 0) == nil
}

func requireProcessDeath(t *testing.T, pid int, label string) {
	t.Helper()
	deadline := time.Now().Add(processTeardownGrace + 3*time.Second)
	for time.Now().Before(deadline) {
		if !processAlive(pid) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("%s (pid %d) survived context cancellation", label, pid)
}

// preparePIDCapture points DOCKER_TEST_PARENT_PID_FILE and
// DOCKER_TEST_GRANDCHILD_PID_FILE at fresh paths under dir and puts dir
// first on PATH, so the exact same "docker" lookup execCommandExecutor uses
// in production resolves to the fake CLI.
func preparePIDCapture(t *testing.T, dir string) (parentPath, grandchildPath string) {
	t.Helper()
	parentPath = filepath.Join(dir, "parent.pid")
	grandchildPath = filepath.Join(dir, "grandchild.pid")
	t.Setenv("DOCKER_TEST_PARENT_PID_FILE", parentPath)
	t.Setenv("DOCKER_TEST_GRANDCHILD_PID_FILE", grandchildPath)
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return parentPath, grandchildPath
}

// TestExecCommandExecutorRunKillsStubbornProcessGroupOnCancellation proves
// the docker.wait code path (execCommandExecutor.run, used by dockerCLI.wait
// and dockerCLI.isRunning) bounds a docker CLI invocation that ignores
// SIGTERM and outlives its own child: both the CLI process and its
// grandchild must be gone once the call returns, and the call itself must
// return once the context is cancelled rather than blocking on Wait forever.
func TestExecCommandExecutorRunKillsStubbornProcessGroupOnCancellation(t *testing.T) {
	dir := t.TempDir()
	writeStubbornDockerScript(t, dir, "wait")
	parentPath, grandchildPath := preparePIDCapture(t, dir)

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	executor := execCommandExecutor{}
	startedAt := time.Now()
	_, err := executor.run(ctx, "wait", "fake-container")
	elapsed := time.Since(startedAt)

	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("bounded run call did not report its own context deadline: %v", err)
	}
	if elapsed > processTeardownGrace+3*time.Second {
		t.Fatalf("bounded run call did not return within its teardown grace: %s", elapsed)
	}

	requireProcessDeath(t, readPIDFile(t, parentPath), "docker CLI process")
	requireProcessDeath(t, readPIDFile(t, grandchildPath), "docker CLI grandchild process")
}

// TestExecCommandExecutorStreamKillsStubbornProcessGroupOnCancellation is the
// followLogs/readLogs counterpart: it proves the streaming code path (used
// for docker logs --follow) applies the identical process-group teardown
// while continuously producing output, matching a real "docker logs
// --follow" invocation more closely than a silent command.
func TestExecCommandExecutorStreamKillsStubbornProcessGroupOnCancellation(t *testing.T) {
	dir := t.TempDir()
	writeStubbornDockerScript(t, dir, `while true; do echo tick; sleep 0.05; done`)
	parentPath, grandchildPath := preparePIDCapture(t, dir)

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	executor := execCommandExecutor{}
	lines := 0
	startedAt := time.Now()
	err := executor.stream(ctx, []string{"logs", "--follow", "fake-container"}, func(string) {
		lines++
	})
	elapsed := time.Since(startedAt)

	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("bounded stream call did not report its own context deadline: %v", err)
	}
	if elapsed > processTeardownGrace+3*time.Second {
		t.Fatalf("bounded stream call did not return within its teardown grace: %s", elapsed)
	}
	if lines == 0 {
		t.Fatal("stream call never observed any output from the fake CLI before cancellation")
	}

	requireProcessDeath(t, readPIDFile(t, parentPath), "docker CLI process")
	requireProcessDeath(t, readPIDFile(t, grandchildPath), "docker CLI grandchild process")
}

// TestExecCommandExecutorRepeatedCyclesLeaveNoSurvivingProcesses simulates
// long manager uptime: many independent bounded calls against a stubborn
// CLI in a row must each independently converge to zero surviving
// processes, proving cancellation teardown does not degrade, slow down, or
// leak across repeated monitor cycles.
func TestExecCommandExecutorRepeatedCyclesLeaveNoSurvivingProcesses(t *testing.T) {
	executor := execCommandExecutor{}
	for cycle := 0; cycle < 5; cycle++ {
		dir := t.TempDir()
		writeStubbornDockerScript(t, dir, "wait")
		parentPath, grandchildPath := preparePIDCapture(t, dir)

		ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
		_, err := executor.run(ctx, "wait", "fake-container")
		cancel()

		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("cycle %d: bounded call did not report its own context deadline: %v", cycle, err)
		}
		requireProcessDeath(t, readPIDFile(t, parentPath), "docker CLI process")
		requireProcessDeath(t, readPIDFile(t, grandchildPath), "docker CLI grandchild process")
	}
}
