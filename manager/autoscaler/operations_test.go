package main

import (
	"context"
	"errors"
	"testing"
	"time"
)

var errDeadlineObserved = errors.New("deadline observed")

type deadlineCheckingDockerClient struct {
	*fakeDockerClient
	waitHadDeadline   bool
	followHadDeadline bool
}

func (d *deadlineCheckingDockerClient) wait(
	ctx context.Context,
	_ string,
) (int, error) {
	_, d.waitHadDeadline = ctx.Deadline()
	return 0, errDeadlineObserved
}

func (d *deadlineCheckingDockerClient) followLogs(
	ctx context.Context,
	_ string,
	_ time.Time,
	_ func(string),
) error {
	_, d.followHadDeadline = ctx.Deadline()
	return errDeadlineObserved
}

func TestBoundedDockerClientBoundsContainerMonitorCalls(t *testing.T) {
	inner := &deadlineCheckingDockerClient{
		fakeDockerClient: newFakeDockerClient(&eventRecorder{}),
	}
	client := boundDockerClient(inner)

	if _, err := client.wait(context.Background(), "container-1"); !errors.Is(
		err,
		errDeadlineObserved,
	) {
		t.Fatalf("bounded wait returned the wrong error: %v", err)
	}
	if err := client.followLogs(
		context.Background(),
		"container-1",
		time.Time{},
		func(string) {},
	); !errors.Is(err, errDeadlineObserved) {
		t.Fatalf("bounded log follower returned the wrong error: %v", err)
	}
	if !inner.waitHadDeadline || !inner.followHadDeadline {
		t.Fatalf(
			"container monitor calls were not bounded: wait=%t logs=%t",
			inner.waitHadDeadline,
			inner.followHadDeadline,
		)
	}
}
