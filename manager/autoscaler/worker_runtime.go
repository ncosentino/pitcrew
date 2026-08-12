package main

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

const minimumWorkerSharedMemoryBytes int64 = 64 * 1024 * 1024

type workerRuntimePolicy struct {
	devices           []string
	sharedMemoryBytes *int64
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
	policy := workerRuntimePolicy{
		devices:           devices,
		sharedMemoryBytes: sharedMemoryBytes,
	}
	if err := policy.validate(); err != nil {
		return workerRuntimePolicy{}, err
	}
	return policy, nil
}

func (p workerRuntimePolicy) validate() error {
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

func (p workerRuntimePolicy) dockerArguments() []string {
	arguments := make([]string, 0, 4)
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
