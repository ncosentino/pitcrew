package main

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// minimumWorkerMemoryBytes matches the contract-11 profile schema floor.
const minimumWorkerMemoryBytes int64 = 6 * 1024 * 1024

// maximumWorkerPidsLimit matches the contract-11 profile schema ceiling.
const maximumWorkerPidsLimit int64 = 2147483647

// workerResourcePolicy carries the canonical per-worker limits configured for a
// profile. A nil or empty field means unconfigured; it never means zero.
type workerResourcePolicy struct {
	memoryBytes     *int64
	memorySwapBytes *int64
	cpuCores        string
	pids            *int64
}

func (p workerResourcePolicy) configured() bool {
	return p.memoryBytes != nil ||
		p.memorySwapBytes != nil ||
		p.cpuCores != "" ||
		p.pids != nil
}

func (p workerResourcePolicy) validate() error {
	if p.memoryBytes != nil && *p.memoryBytes < minimumWorkerMemoryBytes {
		return fmt.Errorf(
			"PITCREW_WORKER_MEMORY_BYTES must be at least %d",
			minimumWorkerMemoryBytes,
		)
	}
	if p.memorySwapBytes != nil {
		if *p.memorySwapBytes < minimumWorkerMemoryBytes {
			return fmt.Errorf(
				"PITCREW_WORKER_MEMORY_SWAP_BYTES must be at least %d",
				minimumWorkerMemoryBytes,
			)
		}
		if p.memoryBytes == nil {
			return errors.New(
				"PITCREW_WORKER_MEMORY_SWAP_BYTES requires PITCREW_WORKER_MEMORY_BYTES",
			)
		}
		if *p.memorySwapBytes < *p.memoryBytes {
			return errors.New(
				"PITCREW_WORKER_MEMORY_SWAP_BYTES cannot be lower than PITCREW_WORKER_MEMORY_BYTES",
			)
		}
	}
	if p.cpuCores != "" && !validCPUCoresText(p.cpuCores) {
		return errors.New(
			"PITCREW_WORKER_CPU_CORES must be a positive decimal with at most nine fractional digits",
		)
	}
	if p.pids != nil && (*p.pids < 1 || *p.pids > maximumWorkerPidsLimit) {
		return fmt.Errorf(
			"PITCREW_WORKER_PIDS_LIMIT must be between 1 and %d",
			maximumWorkerPidsLimit,
		)
	}
	return nil
}

// dockerArguments renders the canonical Docker resource arguments in a stable
// order so worker launches stay reproducible and reviewable.
func (p workerResourcePolicy) dockerArguments() []string {
	arguments := make([]string, 0, 8)
	if p.memoryBytes != nil {
		arguments = append(
			arguments,
			"--memory",
			strconv.FormatInt(*p.memoryBytes, 10),
		)
	}
	if p.memorySwapBytes != nil {
		arguments = append(
			arguments,
			"--memory-swap",
			strconv.FormatInt(*p.memorySwapBytes, 10),
		)
	}
	if p.cpuCores != "" {
		arguments = append(arguments, "--cpus", p.cpuCores)
	}
	if p.pids != nil {
		arguments = append(
			arguments,
			"--pids-limit",
			strconv.FormatInt(*p.pids, 10),
		)
	}
	return arguments
}

// validCPUCoresText enforces the contract-11 CPU pattern: a positive decimal
// without insignificant leading zeroes and at most nine fractional digits.
func validCPUCoresText(value string) bool {
	if value == "" || value != strings.TrimSpace(value) {
		return false
	}
	whole, fraction, hasFraction := strings.Cut(value, ".")
	if strings.Contains(fraction, ".") {
		return false
	}
	if !decimalDigits(whole) || (hasFraction && !decimalDigits(fraction)) {
		return false
	}
	if hasFraction && (len(fraction) < 1 || len(fraction) > 9) {
		return false
	}
	switch {
	case whole == "0":
		return hasFraction && fraction[len(fraction)-1] != '0'
	case whole[0] == '0':
		return false
	default:
		return true
	}
}

func decimalDigits(value string) bool {
	if value == "" {
		return false
	}
	return strings.IndexFunc(value, func(r rune) bool {
		return r < '0' || r > '9'
	}) < 0
}

func parseOptionalInt64(name, value string) (*int64, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return nil, nil
	}
	if !decimalDigits(trimmed) {
		return nil, fmt.Errorf("%s must be a positive integer", name)
	}
	parsed, err := strconv.ParseInt(trimmed, 10, 64)
	if err != nil || parsed < 1 {
		return nil, fmt.Errorf("%s must be a positive integer", name)
	}
	return &parsed, nil
}

func parseOptionalPositiveInteger(name, value string) (int, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return 0, nil
	}
	return parsePositiveInteger(name, trimmed)
}

func parseWorkerImageID(name, value string) (string, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return "", nil
	}
	digest, ok := strings.CutPrefix(trimmed, "sha256:")
	if !ok || len(digest) != 64 || strings.IndexFunc(digest, func(r rune) bool {
		return (r < '0' || r > '9') && (r < 'a' || r > 'f')
	}) >= 0 {
		return "", fmt.Errorf("%s must be a sha256:<64 hex> image identifier", name)
	}
	return trimmed, nil
}
