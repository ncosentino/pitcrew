package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

func TestJobContextPublishesOnlyBoundedTriageMetadata(t *testing.T) {
	observedAt := time.Date(2026, 8, 6, 3, 42, 3, 0, time.UTC)
	context := jobContextFromStarted(&scaleset.JobStarted{
		RunnerID:   17,
		RunnerName: "raw-runner-name",
		JobMessageBase: scaleset.JobMessageBase{
			RepositoryName:     "genesis",
			OwnerName:          "ncosentino",
			JobID:              "92513140749",
			JobWorkflowRef:     "ncosentino/genesis/.github/workflows/ci.yml@refs/heads/private",
			JobDisplayName:     "Android\n debug\tbuild",
			WorkflowRunID:      31068390178,
			EventName:          "pull_request",
			RequestLabels:      []string{"secret-label"},
			QueueTime:          observedAt.Add(-2 * time.Minute),
			ScaleSetAssignTime: observedAt.Add(-time.Minute),
			RunnerAssignTime:   observedAt.Add(-30 * time.Second),
		},
	}, observedAt)
	if context == nil {
		t.Fatal("valid job metadata was discarded")
	}
	if context.Repository != "https://github.com/ncosentino/genesis" ||
		context.WorkflowRunID != 31068390178 ||
		context.JobID != "92513140749" ||
		context.DisplayName == nil ||
		*context.DisplayName != "Android debug build" ||
		context.EventName == nil ||
		*context.EventName != "pull_request" ||
		context.StartedAt != "2026-08-06T03:42:03Z" {
		t.Fatalf("unexpected job context: %#v", context)
	}

	data, err := json.Marshal(context)
	if err != nil {
		t.Fatal(err)
	}
	for _, excluded := range []string{
		"raw-runner-name",
		"JobWorkflowRef",
		"private",
		"secret-label",
		"RunnerID",
		"RunnerName",
		"RequestLabels",
	} {
		if strings.Contains(string(data), excluded) {
			t.Fatalf("job context exposed excluded metadata %q: %s", excluded, data)
		}
	}
}

func TestJobCompletionPreservesIdentityAndAddsBoundedOutcome(t *testing.T) {
	startedAt := time.Date(2026, 8, 6, 3, 42, 3, 0, time.UTC)
	finishedAt := time.Date(2026, 8, 6, 4, 25, 29, 0, time.UTC)
	started := jobContextFromStarted(&scaleset.JobStarted{
		JobMessageBase: scaleset.JobMessageBase{
			RepositoryName: "genesis",
			OwnerName:      "ncosentino",
			JobID:          "92513140749",
			WorkflowRunID:  31068390178,
		},
	}, startedAt)
	completed := jobContextFromCompleted(&scaleset.JobCompleted{
		Result: "Cancelled\nby operator",
		JobMessageBase: scaleset.JobMessageBase{
			RepositoryName: "genesis",
			OwnerName:      "ncosentino",
			JobID:          "92513140749",
			WorkflowRunID:  31068390178,
			FinishTime:     finishedAt,
		},
	}, finishedAt.Add(time.Second), started)
	if completed == nil ||
		completed.StartedAt != startedAt.Format(time.RFC3339) ||
		completed.FinishedAt == nil ||
		*completed.FinishedAt != finishedAt.Format(time.RFC3339) ||
		completed.Result == nil ||
		*completed.Result != "Cancelled by operator" {
		t.Fatalf("unexpected completed job context: %#v", completed)
	}
}

func TestRepeatedJobStartPreservesOriginalObservedStart(t *testing.T) {
	firstObservedAt := time.Date(2026, 8, 6, 3, 42, 3, 0, time.UTC)
	message := scaleset.JobMessageBase{
		RepositoryName: "genesis",
		OwnerName:      "ncosentino",
		JobID:          "92513140749",
		WorkflowRunID:  31068390178,
	}
	first := jobContextFromMessage(message, firstObservedAt)
	repeated := jobContextFromMessage(
		message,
		firstObservedAt.Add(10*time.Minute),
	)
	merged := mergeStartedJobContext(first, repeated)
	if merged == nil || merged.StartedAt != firstObservedAt.Format(time.RFC3339) {
		t.Fatalf("repeated start moved the observed boundary: %#v", merged)
	}
	if preserved := mergeStartedJobContext(first, nil); preserved == nil ||
		preserved.StartedAt != first.StartedAt {
		t.Fatalf("malformed repeated start erased valid context: %#v", preserved)
	}
}

func TestJobContextRejectsUnlinkableIdentity(t *testing.T) {
	now := time.Date(2026, 8, 6, 3, 42, 3, 0, time.UTC)
	tests := []scaleset.JobMessageBase{
		{
			RepositoryName: "repo/name",
			OwnerName:      "owner",
			JobID:          "1",
			WorkflowRunID:  1,
		},
		{
			RepositoryName: "repository",
			OwnerName:      "owner",
			JobID:          "0",
			WorkflowRunID:  1,
		},
		{
			RepositoryName: "repository",
			OwnerName:      "owner",
			JobID:          "not-numeric",
			WorkflowRunID:  1,
		},
		{
			RepositoryName: "repository",
			OwnerName:      "owner",
			JobID:          "1",
			WorkflowRunID:  0,
		},
	}
	for _, message := range tests {
		if context := jobContextFromMessage(message, now); context != nil {
			t.Fatalf("invalid job identity was published: %#v", context)
		}
	}
}

func TestJobCompletionDoesNotInventMissingStartContext(t *testing.T) {
	context := jobContextFromCompleted(&scaleset.JobCompleted{
		Result: "Succeeded",
		JobMessageBase: scaleset.JobMessageBase{
			RepositoryName: "repository",
			OwnerName:      "owner",
			JobID:          "1",
			WorkflowRunID:  1,
		},
	}, time.Date(2026, 8, 6, 4, 25, 29, 0, time.UTC), nil)
	if context != nil {
		t.Fatalf("completion invented a missing start context: %#v", context)
	}
}

func TestMismatchedJobCompletionDoesNotChangeTrackedJob(t *testing.T) {
	startedAt := time.Date(2026, 8, 6, 3, 42, 3, 0, time.UTC)
	existing := jobContextFromMessage(scaleset.JobMessageBase{
		RepositoryName: "genesis",
		OwnerName:      "ncosentino",
		JobID:          "92513140749",
		WorkflowRunID:  31068390178,
	}, startedAt)
	completed := jobContextFromCompleted(&scaleset.JobCompleted{
		Result: "Failed",
		JobMessageBase: scaleset.JobMessageBase{
			RepositoryName: "genesis",
			OwnerName:      "ncosentino",
			JobID:          "92510065242",
			WorkflowRunID:  31067679511,
			FinishTime:     startedAt.Add(time.Hour),
		},
	}, startedAt.Add(time.Hour), existing)
	if completed == nil ||
		completed.JobID != existing.JobID ||
		completed.FinishedAt != nil ||
		completed.Result != nil {
		t.Fatalf("mismatched completion contaminated job context: %#v", completed)
	}
}

func TestJobContextBoundsDisplayTextByRunes(t *testing.T) {
	context := jobContextFromMessage(scaleset.JobMessageBase{
		RepositoryName: "repository",
		OwnerName:      "owner",
		JobID:          "1",
		WorkflowRunID:  1,
		JobDisplayName: strings.Repeat("界", maxJobDisplayNameLength+10),
	}, time.Date(2026, 8, 6, 3, 42, 3, 0, time.UTC))
	if context == nil || context.DisplayName == nil {
		t.Fatal("bounded display name was discarded")
	}
	if length := len([]rune(*context.DisplayName)); length != maxJobDisplayNameLength {
		t.Fatalf("display name was not bounded by runes: %d", length)
	}
}
