package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"
)

type containerLaunch struct {
	name      string
	image     string
	jitConfig string
	labels    map[string]string
}

type recoveredContainer struct {
	containerID string
	name        string
	runnerName  string
	runnerID    int64
	targetKey   string
	slotKey     string
	createdAt   time.Time
}

type dockerClient interface {
	run(ctx context.Context, launch containerLaunch) (string, error)
	wait(ctx context.Context, containerID string) (int, error)
	isRunning(ctx context.Context, containerID string) (bool, error)
	readLogs(ctx context.Context, containerID string) ([]string, error)
	followLogs(
		ctx context.Context,
		containerID string,
		since time.Time,
		onLine func(string),
	) error
	stopAndRemove(ctx context.Context, containerID string) error
	stop(ctx context.Context, containerID string) error
	listManaged(ctx context.Context, profileID string) ([]recoveredContainer, error)
	sampleResources(
		ctx context.Context,
		profileID string,
		runners []resourceContainer,
		sampledAt time.Time,
	) resourceSample
}

type commandExecutor interface {
	run(ctx context.Context, arguments ...string) ([]byte, error)
	stream(ctx context.Context, arguments []string, onLine func(string)) error
}

type execCommandExecutor struct{}

func (execCommandExecutor) run(ctx context.Context, arguments ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, "docker", arguments...)
	output, err := command.Output()
	if err != nil {
		return output, err
	}
	return output, nil
}

func (execCommandExecutor) stream(
	ctx context.Context,
	arguments []string,
	onLine func(string),
) error {
	command := exec.CommandContext(ctx, "docker", arguments...)
	reader, writer := io.Pipe()
	command.Stdout = writer
	command.Stderr = writer
	if err := command.Start(); err != nil {
		_ = reader.Close()
		_ = writer.Close()
		return err
	}

	wait := make(chan error, 1)
	go func() {
		err := command.Wait()
		_ = writer.CloseWithError(err)
		wait <- err
	}()

	scanner := bufio.NewScanner(reader)
	for scanner.Scan() {
		onLine(scanner.Text())
	}
	scanErr := scanner.Err()
	waitErr := <-wait
	_ = reader.Close()
	if scanErr != nil && !errors.Is(scanErr, context.Canceled) {
		return scanErr
	}
	return waitErr
}

type dockerCLI struct {
	executor               commandExecutor
	hostname               func() (string, error)
	resourceCommandTimeout time.Duration
}

func newDockerCLI() *dockerCLI {
	return &dockerCLI{
		executor:               execCommandExecutor{},
		hostname:               os.Hostname,
		resourceCommandTimeout: resourceTelemetryCommandTimeout,
	}
}

func (d *dockerCLI) run(ctx context.Context, launch containerLaunch) (string, error) {
	output, err := d.executor.run(ctx, buildDockerRunArguments(launch)...)
	if err != nil {
		return "", fmt.Errorf("docker run failed: %w", err)
	}
	containerID := strings.TrimSpace(string(output))
	if containerID == "" {
		return "", errors.New("docker run returned an empty container ID")
	}
	return containerID, nil
}

func buildDockerRunArguments(launch containerLaunch) []string {
	arguments := []string{
		"run",
		"--rm",
		"--detach",
		"--init",
		"--user", "runner",
		"--workdir", "/actions-runner",
		"--entrypoint", "/actions-runner/bin/Runner.Listener",
		"--name", launch.name,
	}
	labelKeys := make([]string, 0, len(launch.labels))
	for key := range launch.labels {
		labelKeys = append(labelKeys, key)
	}
	sort.Strings(labelKeys)
	for _, key := range labelKeys {
		arguments = append(arguments, "--label", key+"="+launch.labels[key])
	}
	arguments = append(
		arguments,
		"--env",
		"ACTIONS_RUNNER_INPUT_JITCONFIG="+launch.jitConfig,
		launch.image,
		"run",
	)
	return arguments
}

func (d *dockerCLI) wait(ctx context.Context, containerID string) (int, error) {
	output, err := d.executor.run(ctx, "wait", containerID)
	if err != nil {
		return 0, fmt.Errorf("docker wait for %s failed: %w", containerID, err)
	}
	exitCode, err := strconv.Atoi(strings.TrimSpace(string(output)))
	if err != nil {
		return 0, fmt.Errorf("docker wait for %s returned invalid status: %w", containerID, err)
	}
	return exitCode, nil
}

func (d *dockerCLI) isRunning(ctx context.Context, containerID string) (bool, error) {
	output, err := d.executor.run(
		ctx,
		"ps",
		"--quiet",
		"--no-trunc",
		"--filter", "id="+containerID,
	)
	if err != nil {
		return false, fmt.Errorf("inspect running state for %s: %w", containerID, err)
	}
	for _, runningID := range strings.Fields(string(output)) {
		if runningID == containerID {
			return true, nil
		}
	}
	return false, nil
}

func (d *dockerCLI) followLogs(
	ctx context.Context,
	containerID string,
	since time.Time,
	onLine func(string),
) error {
	if err := d.executor.stream(
		ctx,
		[]string{
			"logs",
			"--follow",
			"--since", since.UTC().Format(time.RFC3339Nano),
			containerID,
		},
		onLine,
	); err != nil {
		return fmt.Errorf("follow docker logs for %s: %w", containerID, err)
	}
	return nil
}

func (d *dockerCLI) readLogs(ctx context.Context, containerID string) ([]string, error) {
	var lines []string
	if err := d.executor.stream(
		ctx,
		[]string{"logs", containerID},
		func(line string) {
			lines = append(lines, line)
		},
	); err != nil {
		return nil, fmt.Errorf("read docker logs for %s: %w", containerID, err)
	}
	return lines, nil
}

func (d *dockerCLI) stopAndRemove(ctx context.Context, containerID string) error {
	if _, err := d.executor.run(ctx, "rm", "--force", containerID); err != nil {
		return fmt.Errorf("stop and remove container %s: %w", containerID, err)
	}
	return nil
}

func (d *dockerCLI) stop(ctx context.Context, containerID string) error {
	if _, err := d.executor.run(ctx, "stop", "--time", "20", containerID); err != nil {
		return fmt.Errorf("stop container %s: %w", containerID, err)
	}
	return nil
}

func (d *dockerCLI) listManaged(
	ctx context.Context,
	profileID string,
) ([]recoveredContainer, error) {
	output, err := d.executor.run(
		ctx,
		"ps",
		"--quiet",
		"--filter", "label="+managedProfileLabelKey+"="+profileID,
		"--filter", "label="+autoscalerLabelKey+"=true",
	)
	if err != nil {
		return nil, fmt.Errorf("list managed autoscaler containers: %w", err)
	}
	ids := strings.Fields(string(output))
	if len(ids) == 0 {
		return nil, nil
	}

	inspectArguments := append([]string{"inspect"}, ids...)
	inspectOutput, err := d.executor.run(ctx, inspectArguments...)
	if err != nil {
		return nil, fmt.Errorf("inspect managed autoscaler containers: %w", err)
	}
	var records []struct {
		ID      string    `json:"Id"`
		Name    string    `json:"Name"`
		Created time.Time `json:"Created"`
		Config  struct {
			Labels map[string]string `json:"Labels"`
		} `json:"Config"`
		State struct {
			Running bool `json:"Running"`
		} `json:"State"`
	}
	decoder := json.NewDecoder(bytes.NewReader(inspectOutput))
	if err := decoder.Decode(&records); err != nil {
		return nil, fmt.Errorf("decode managed container inspection: %w", err)
	}

	recovered := make([]recoveredContainer, 0, len(records))
	for _, record := range records {
		if !record.State.Running {
			continue
		}
		labels := record.Config.Labels
		if labels[managedProfileLabelKey] != profileID || labels[autoscalerLabelKey] != "true" {
			return nil, fmt.Errorf("container %s does not have exact autoscaler ownership labels", record.ID)
		}
		targetKey := labels[targetKeyLabelKey]
		runnerName := labels[runnerNameLabelKey]
		slotKey := labels[managedSlotLabelKey]
		runnerIDText := labels[runnerIDLabelKey]
		if targetKey == "" || runnerName == "" || runnerIDText == "" || slotKey == "" {
			return nil, fmt.Errorf("container %s is missing autoscaler recovery labels", record.ID)
		}
		runnerID, err := strconv.ParseInt(runnerIDText, 10, 64)
		if err != nil || runnerID < 1 {
			return nil, fmt.Errorf("container %s has invalid runner ID label %q", record.ID, runnerIDText)
		}
		recovered = append(recovered, recoveredContainer{
			containerID: record.ID,
			name:        strings.TrimPrefix(record.Name, "/"),
			runnerName:  runnerName,
			runnerID:    runnerID,
			targetKey:   targetKey,
			slotKey:     slotKey,
			createdAt:   record.Created,
		})
	}
	sort.Slice(recovered, func(i, j int) bool {
		return recovered[i].containerID < recovered[j].containerID
	})
	return recovered, nil
}
