//go:build nested_docker_integration

package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestNestedDockerIntegration(t *testing.T) {
	image := os.Getenv("PITCREW_TEST_NESTED_DOCKER_IMAGE")
	owner := os.Getenv("GITHUB_RUN_ID") + "-" + os.Getenv("GITHUB_RUN_ATTEMPT")
	if image == "" || owner == "-" {
		t.Fatal("controlled integration requires an explicit fixture image and workflow ownership")
	}
	client := newDockerCLI()
	var containers []string
	var followers sync.WaitGroup
	logContext, cancelLogs := context.WithCancel(t.Context())
	defer func() { cancelLogs(); followers.Wait() }()
	t.Cleanup(func() {
		cleanupContext, cancel := context.WithTimeout(context.WithoutCancel(t.Context()), dockerOperationTimeout)
		defer cancel()
		for _, id := range containers {
			if err := client.stopAndRemove(cleanupContext, id); err != nil {
				t.Errorf("exact test-owned cleanup failed: %v", err)
			}
		}
	})
	type fixtureWorker struct {
		id       string
		events   chan string
		daemonID string
	}
	start := func(index int, mode string) *fixtureWorker {
		launch := nestedDockerLaunch()
		launch.name = fmt.Sprintf("pitcrew-nested-proof-%s-%d", owner, index)
		launch.labels = map[string]string{"pitcrew-test-owner": owner}
		launch.image = image
		launch.jitConfig = mode
		if mode == "fixture-sentinel" {
			launch.runtime = workerRuntimePolicy{}
		}
		started := time.Now()
		var id string
		var err error
		if index == 2 {
			id, err = client.create(t.Context(), launch)
		} else {
			id, err = client.run(t.Context(), launch)
		}
		if err != nil {
			t.Fatalf("controlled nested worker launch failed: %v", err)
		}
		containers = append(containers, id)
		if index == 2 {
			if err := client.start(t.Context(), id); err != nil {
				t.Fatalf("controlled admission-style worker start failed: %v", err)
			}
		}
		worker := &fixtureWorker{id: id, events: make(chan string, 256)}
		followers.Add(1)
		go func() {
			defer followers.Done()
			err := client.followLogs(logContext, id, started, func(line string) {
				if len(line) <= 512 && strings.HasPrefix(line, "[pitcrew:nested-") {
					if !strings.Contains(line, "daemon_identity=") {
						t.Log(line)
					}
					select {
					case worker.events <- line:
					case <-logContext.Done():
					}
				}
			})
			if logContext.Err() == nil {
				if err != nil {
					t.Log("[pitcrew:nested-smoke] phase=log-follow status=failed")
				}
				select {
				case worker.events <- "stream-ended":
				case <-logContext.Done():
				}
			}
		}()
		t.Logf("[pitcrew:nested-smoke] phase=outer-worker-start worker=%d elapsed_ms=%d", index, time.Since(started).Milliseconds())
		return worker
	}
	waitFor := func(worker *fixtureWorker, marker string) {
		t.Helper()
		for {
			select {
			case line := <-worker.events:
				if strings.HasPrefix(line, "[pitcrew:nested-smoke] daemon_identity=") {
					worker.daemonID = strings.TrimPrefix(line, "[pitcrew:nested-smoke] daemon_identity=")
				}
				if strings.Contains(line, marker) {
					return
				}
				if line == "stream-ended" {
					t.Fatal("worker ended before its required bounded evidence")
				}
			case <-t.Context().Done():
				t.Fatal("controlled integration cancelled before its required evidence")
			}
		}
	}
	sentinel := start(0, "fixture-sentinel")
	normal := start(1, "fixture-normal")
	peer := start(2, "fixture-hold")
	waitFor(normal, "phase=runner status=exited exit_code=0")
	waitFor(peer, "phase=reaper-cleanup status=passed")
	if normal.daemonID == "" || peer.daemonID == "" || normal.daemonID == peer.daemonID {
		t.Fatal("concurrent workers did not have independent daemons")
	}
	t.Log("[pitcrew:nested-smoke] phase=concurrent-daemon-isolation status=passed workers=2")
	failed := start(3, "fixture-daemon-failure")
	waitFor(failed, "phase=execution status=failed reason=daemon-exited")
	timer := time.NewTicker(time.Second)
	defer timer.Stop()
	for {
		running, err := client.isRunning(t.Context(), failed.id)
		if err != nil {
			t.Fatalf("daemon-failure inspection failed: %v", err)
		}
		if !running {
			break
		}
		select {
		case <-t.Context().Done():
			t.Fatal("daemon failure did not terminate its runner")
		case <-timer.C:
		}
	}
	if running, err := client.isRunning(t.Context(), peer.id); err != nil || !running {
		t.Fatal("daemon failure affected its unrelated peer")
	}
	if err := client.stop(t.Context(), peer.id); err != nil {
		t.Fatalf("exact worker cancellation failed: %v", err)
	}
	if running, err := client.isRunning(t.Context(), sentinel.id); err != nil || !running {
		t.Fatal("worker cancellation affected the unrelated ordinary sentinel")
	}
	t.Log("[pitcrew:nested-smoke] phase=worker-cancellation status=passed")
	replacement := start(4, "fixture-normal")
	waitFor(replacement, "phase=runner status=exited exit_code=0")
	if replacement.daemonID == "" || replacement.daemonID == normal.daemonID {
		t.Fatal("replacement reused daemon state")
	}
	t.Log("[pitcrew:nested-smoke] phase=worker-replacement status=passed state=fresh")
}
