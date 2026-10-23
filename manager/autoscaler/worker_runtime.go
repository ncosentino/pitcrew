package main

import (
	"context"
	_ "embed"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

const minimumWorkerSharedMemoryBytes int64 = 64 * 1024 * 1024

//go:embed nested_docker.sh
var nestedDockerBootstrap string

type workerRuntimePolicy struct {
	devices            []string
	sharedMemoryBytes  *int64
	dockerMode         string
	dockerStorageBytes *int64
}

func loadWorkerRuntimePolicy(
	value func(name, fallback string) string,
) (workerRuntimePolicy, error) {
	devicesValue := strings.TrimSpace(value("PITCREW_WORKER_RUNTIME_DEVICES", ""))
	var devices []string
	if devicesValue != "" {
		devices = strings.Split(devicesValue, ",")
		for index := range devices {
			devices[index] = strings.TrimSpace(strings.ToLower(devices[index]))
		}
	}
	sharedMemoryBytes, err := parseOptionalInt64(
		"PITCREW_WORKER_SHM_SIZE_BYTES",
		value("PITCREW_WORKER_SHM_SIZE_BYTES", ""),
	)
	if err != nil {
		return workerRuntimePolicy{}, err
	}
	dockerStorage, err := parseOptionalInt64(
		"PITCREW_WORKER_DOCKER_STORAGE_BYTES",
		value("PITCREW_WORKER_DOCKER_STORAGE_BYTES", ""),
	)
	if err != nil {
		return workerRuntimePolicy{}, err
	}
	policy := workerRuntimePolicy{
		devices:            devices,
		sharedMemoryBytes:  sharedMemoryBytes,
		dockerMode:         value("PITCREW_WORKER_DOCKER_MODE", ""),
		dockerStorageBytes: dockerStorage,
	}
	if err := policy.validate(); err != nil {
		return workerRuntimePolicy{}, err
	}
	return policy, nil
}

func (p workerRuntimePolicy) validate() error {
	if p.dockerMode != "" && p.dockerMode != "privileged-local" {
		return errors.New("PITCREW_WORKER_DOCKER_MODE supports only privileged-local")
	}
	if (p.dockerMode == "") != (p.dockerStorageBytes == nil) {
		return errors.New("nested Docker mode and bounded storage must be configured together")
	}
	if p.dockerMode != "" && (len(p.devices) != 0 ||
		*p.dockerStorageBytes < minimumWorkerSharedMemoryBytes) {
		return errors.New("nested Docker requires at least 64 MiB storage and cannot combine device capabilities")
	}
	if len(p.devices) > 1 {
		return errors.New("PITCREW_WORKER_RUNTIME_DEVICES supports at most one typed device")
	}
	if len(p.devices) == 1 && p.devices[0] != "kvm" {
		return fmt.Errorf(
			"PITCREW_WORKER_RUNTIME_DEVICES contains unsupported device %q",
			p.devices[0],
		)
	}
	if p.sharedMemoryBytes != nil &&
		*p.sharedMemoryBytes < minimumWorkerSharedMemoryBytes {
		return fmt.Errorf(
			"PITCREW_WORKER_SHM_SIZE_BYTES must be at least %d",
			minimumWorkerSharedMemoryBytes,
		)
	}
	return nil
}

func (d *dockerCLI) validateNestedDockerImage(ctx context.Context, image string) error {
	ctx, cancel := context.WithTimeout(ctx, dockerOperationTimeout)
	defer cancel()
	host, err := d.executor.run(ctx, "info", "--format",
		`{{.OSType}}|{{.Architecture}}|{{.CgroupVersion}}|{{join .SecurityOptions ","}}`)
	if err != nil {
		return errors.New("nested Docker host metadata could not be verified")
	}
	hostContract := strings.TrimSpace(string(host))
	if !strings.HasPrefix(hostContract, "linux|x86_64|2|") ||
		strings.Contains(hostContract, "rootless") || strings.Contains(hostContract, "userns") {
		return errors.New("nested Docker requires rootful Linux x64, cgroup v2 and no user namespace remapping")
	}
	metadata, err := d.executor.run(ctx, "image", "inspect", "--format",
		`{{.Os}}|{{.Architecture}}|{{.Config.User}}|{{if .Config.Volumes}}{{len .Config.Volumes}}{{else}}0{{end}}`,
		image)
	if err != nil {
		return errors.New("nested Docker image metadata could not be verified")
	}
	fields := strings.Split(strings.TrimSpace(string(metadata)), "|")
	if len(fields) != 4 || fields[0] != "linux" || fields[1] != "amd64" || fields[3] != "0" {
		return errors.New("nested Docker requires a native Linux amd64 image without image-declared volumes")
	}
	switch fields[2] {
	case "", "0", "root", "0:0", "root:root":
		return nil
	default:
		return errors.New("nested Docker requires an image-declared root user")
	}
}

func (p workerRuntimePolicy) dockerArguments() []string {
	arguments := make([]string, 0, 4)
	if p.dockerMode != "" {
		arguments = append(arguments,
			"--privileged", "--cgroupns", "private",
			"--tmpfs", "/var/lib/pitcrew-docker:rw,exec,nosuid,nodev,size="+
				strconv.FormatInt(*p.dockerStorageBytes, 10),
			"--tmpfs", "/run/pitcrew-docker:rw,nosuid,nodev,size=67108864,mode=0700",
			"--env", "DOCKER_HOST=unix:///run/pitcrew-docker/docker.sock",
			"--env", "PITCREW_NESTED_DOCKER_VERIFY_ONLY=0",
		)
	}
	if len(p.devices) == 1 {
		arguments = append(arguments, "--device", "/dev/kvm:/dev/kvm:rwm")
	}
	if p.sharedMemoryBytes != nil {
		arguments = append(
			arguments,
			"--shm-size",
			strconv.FormatInt(*p.sharedMemoryBytes, 10),
		)
	}
	return arguments
}

func (p workerRuntimePolicy) validateLaunch(
	resources workerResourcePolicy, volumes []externalVolume, network string,
) error {
	if err := p.validate(); err != nil {
		return err
	}
	if p.dockerMode == "" {
		return nil
	}
	if resources.memoryBytes == nil || resources.memorySwapBytes == nil ||
		resources.cpuCores == "" || resources.pids == nil ||
		*resources.memorySwapBytes != *resources.memoryBytes ||
		*p.dockerStorageBytes >= *resources.memoryBytes {
		return errors.New("nested Docker requires explicit CPU, memory, PID and swap-disabled limits, with storage smaller than memory")
	}
	if len(volumes) != 0 || network != "" {
		return errors.New("nested Docker cannot combine external volumes or service networks")
	}
	return nil
}
