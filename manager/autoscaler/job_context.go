package main

import (
	"strings"
	"time"
	"unicode"

	"github.com/actions/scaleset"
)

const (
	maxGitHubOwnerLength      = 39
	maxGitHubRepositoryLength = 100
	maxJobIDLength            = 32
	maxJobDisplayNameLength   = 256
	maxJobEventNameLength     = 64
	maxJobResultLength        = 64
)

type observedJobContext struct {
	Repository         string  `json:"repository"`
	WorkflowRunID      int64   `json:"workflowRunId"`
	JobID              string  `json:"jobId"`
	DisplayName        *string `json:"displayName"`
	EventName          *string `json:"eventName"`
	QueuedAt           *string `json:"queuedAt"`
	ScaleSetAssignedAt *string `json:"scaleSetAssignedAt"`
	RunnerAssignedAt   *string `json:"runnerAssignedAt"`
	StartedAt          string  `json:"startedAt"`
	FinishedAt         *string `json:"finishedAt"`
	Result             *string `json:"result"`
}

func jobContextFromStarted(
	job *scaleset.JobStarted,
	observedAt time.Time,
) *observedJobContext {
	if job == nil {
		return nil
	}
	return jobContextFromMessage(job.JobMessageBase, observedAt)
}

func mergeStartedJobContext(
	existing *observedJobContext,
	next *observedJobContext,
) *observedJobContext {
	if next == nil {
		return cloneJobContext(existing)
	}
	if !sameJobContext(existing, next) {
		return next
	}
	next.StartedAt = existing.StartedAt
	next.DisplayName = firstString(next.DisplayName, existing.DisplayName)
	next.EventName = firstString(next.EventName, existing.EventName)
	next.QueuedAt = firstString(next.QueuedAt, existing.QueuedAt)
	next.ScaleSetAssignedAt = firstString(
		next.ScaleSetAssignedAt,
		existing.ScaleSetAssignedAt,
	)
	next.RunnerAssignedAt = firstString(
		next.RunnerAssignedAt,
		existing.RunnerAssignedAt,
	)
	return next
}

func jobContextFromCompleted(
	job *scaleset.JobCompleted,
	observedAt time.Time,
	existing *observedJobContext,
) *observedJobContext {
	if job == nil {
		return nil
	}
	next := cloneJobContext(existing)
	if next == nil {
		return nil
	}
	completed := jobContextFromMessage(job.JobMessageBase, observedAt)
	if !sameJobContext(next, completed) {
		return next
	}
	if finishedAt := timestampPointer(job.FinishTime); finishedAt != nil {
		next.FinishedAt = finishedAt
	} else if next.FinishedAt == nil {
		next.FinishedAt = timestampPointer(observedAt)
	}
	if result := boundedTextPointer(job.Result, maxJobResultLength); result != nil {
		next.Result = result
	}
	return next
}

func jobContextFromMessage(
	message scaleset.JobMessageBase,
	observedAt time.Time,
) *observedJobContext {
	owner := githubPathSegment(message.OwnerName, maxGitHubOwnerLength)
	repository := githubPathSegment(
		message.RepositoryName,
		maxGitHubRepositoryLength,
	)
	jobID := numericIdentifier(message.JobID, maxJobIDLength)
	if owner == "" ||
		repository == "" ||
		jobID == "" ||
		message.WorkflowRunID <= 0 {
		return nil
	}
	return &observedJobContext{
		Repository:         "https://github.com/" + owner + "/" + repository,
		WorkflowRunID:      message.WorkflowRunID,
		JobID:              jobID,
		DisplayName:        boundedTextPointer(message.JobDisplayName, maxJobDisplayNameLength),
		EventName:          boundedTextPointer(message.EventName, maxJobEventNameLength),
		QueuedAt:           timestampPointer(message.QueueTime),
		ScaleSetAssignedAt: timestampPointer(message.ScaleSetAssignTime),
		RunnerAssignedAt:   timestampPointer(message.RunnerAssignTime),
		StartedAt:          observedAt.UTC().Format(time.RFC3339),
		FinishedAt:         nil,
		Result:             nil,
	}
}

func githubPathSegment(value string, maximum int) string {
	if value == "" ||
		len(value) > maximum ||
		strings.TrimSpace(value) != value {
		return ""
	}
	for _, character := range value {
		if (character >= 'a' && character <= 'z') ||
			(character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') ||
			character == '-' ||
			character == '_' ||
			character == '.' {
			continue
		}
		return ""
	}
	return value
}

func numericIdentifier(value string, maximum int) string {
	if value == "" ||
		len(value) > maximum ||
		strings.TrimSpace(value) != value ||
		value[0] == '0' {
		return ""
	}
	for _, character := range value {
		if character < '0' || character > '9' {
			return ""
		}
	}
	return value
}

func boundedTextPointer(value string, maximum int) *string {
	fields := strings.FieldsFunc(value, func(character rune) bool {
		return unicode.IsSpace(character) || unicode.IsControl(character)
	})
	if len(fields) == 0 {
		return nil
	}
	normalized := strings.Join(fields, " ")
	runes := []rune(normalized)
	if len(runes) > maximum {
		normalized = string(runes[:maximum])
	}
	return &normalized
}

func timestampPointer(value time.Time) *string {
	if value.IsZero() {
		return nil
	}
	formatted := value.UTC().Format(time.RFC3339)
	return &formatted
}

func cloneJobContext(value *observedJobContext) *observedJobContext {
	if value == nil {
		return nil
	}
	cloned := *value
	return &cloned
}

func sameJobContext(left, right *observedJobContext) bool {
	return left != nil &&
		right != nil &&
		left.Repository == right.Repository &&
		left.WorkflowRunID == right.WorkflowRunID &&
		left.JobID == right.JobID
}

func firstString(current, fallback *string) *string {
	if current != nil {
		return current
	}
	return fallback
}
