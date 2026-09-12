package main

import (
	"context"
	"errors"
	"testing"
)

func TestStopAndRemoveTreatsExactPostFailureAbsenceAsSuccess(t *testing.T) {
	executor := newScriptedCommandExecutor(map[string][]scriptedCommandResult{
		"rm": {{err: errors.New("container already absent")}},
		"ps": {{output: ""}},
	})
	docker := &dockerCLI{executor: executor}

	if err := docker.stopAndRemove(context.Background(), "container-1"); err != nil {
		t.Fatalf("exact absent container was not idempotent: %v", err)
	}
}

func TestStopAndRemovePreservesFailureWhenContainerStillExists(t *testing.T) {
	executor := newScriptedCommandExecutor(map[string][]scriptedCommandResult{
		"rm": {{err: errors.New("remove failed")}},
		"ps": {{output: "container-1\n"}},
	})
	docker := &dockerCLI{executor: executor}

	if err := docker.stopAndRemove(context.Background(), "container-1"); err == nil {
		t.Fatal("failed removal of an existing container was reported as success")
	}
}
