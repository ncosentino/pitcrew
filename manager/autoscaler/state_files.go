package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"time"
)

type statePaths struct {
	desired         string
	lastValid       string
	acknowledgement string
	observed        string
	static          string
	supportEvidence string
	hardware        string
	retirements     string
	shutdownRequest string
}

type acknowledgement struct {
	SchemaVersion          int      `json:"schemaVersion"`
	Status                 string   `json:"status"`
	Generation             int      `json:"generation"`
	ManagerContractVersion int      `json:"managerContractVersion"`
	DesiredStateHash       string   `json:"desiredStateHash"`
	ObservedAt             string   `json:"observedAt"`
	DesiredSlots           int      `json:"desiredSlots"`
	AddedSlots             int      `json:"addedSlots"`
	DrainingSlots          int      `json:"drainingSlots"`
	UnchangedSlots         int      `json:"unchangedSlots"`
	AddedKeys              []string `json:"addedKeys"`
	DrainingKeys           []string `json:"drainingKeys"`
	UnchangedKeys          []string `json:"unchangedKeys"`
	ActivationMode         string   `json:"activationMode"`
	ActiveSlots            int      `json:"activeSlots"`
	MinimumIdleSlots       int      `json:"minimumIdleSlots"`
}

func newStatePaths(directory string) statePaths {
	return statePaths{
		desired:         filepath.Join(directory, "desired-capacity.json"),
		lastValid:       filepath.Join(directory, "last-valid-capacity.json"),
		acknowledgement: filepath.Join(directory, "acknowledged-capacity.json"),
		observed:        filepath.Join(directory, "observed-state.json"),
		static:          filepath.Join(directory, "static-profile.json"),
		supportEvidence: filepath.Join(directory, "support-evidence"),
		hardware:        filepath.Join(directory, "host-hardware.json"),
		retirements:     filepath.Join(directory, "retiring-targets.json"),
		shutdownRequest: filepath.Join(directory, "manager-shutdown.json"),
	}
}

func publishSupportEvidenceSnapshot(paths statePaths) error {
	evidenceInfo, err := os.Lstat(paths.supportEvidence)
	if errors.Is(err, os.ErrNotExist) {
		if err := os.MkdirAll(paths.supportEvidence, 0o700); err != nil {
			return fmt.Errorf("create support evidence directory: %w", err)
		}
	} else if err != nil {
		return fmt.Errorf("inspect support evidence directory: %w", err)
	} else if !evidenceInfo.IsDir() ||
		evidenceInfo.Mode()&os.ModeSymlink != 0 {
		return errors.New("support evidence path is not an unlinked directory")
	}
	for _, source := range []string{
		paths.desired,
		paths.acknowledgement,
		paths.static,
		paths.observed,
	} {
		name := filepath.Base(source)
		destination := filepath.Join(paths.supportEvidence, name)
		sourceInfo, err := os.Lstat(source)
		if errors.Is(err, os.ErrNotExist) {
			if err := os.Remove(destination); err != nil &&
				!errors.Is(err, os.ErrNotExist) {
				return fmt.Errorf(
					"remove stale support evidence %s: %w",
					name,
					err,
				)
			}
			continue
		}
		if err != nil {
			return fmt.Errorf("inspect support evidence %s: %w", name, err)
		}
		if !sourceInfo.Mode().IsRegular() {
			if err := os.Remove(destination); err != nil &&
				!errors.Is(err, os.ErrNotExist) {
				return fmt.Errorf(
					"remove invalid support evidence %s: %w",
					name,
					err,
				)
			}
			return fmt.Errorf("support evidence %s is not a regular file", name)
		}
		data, err := os.ReadFile(source)
		if err != nil {
			return fmt.Errorf("read support evidence %s: %w", name, err)
		}
		if err := writeBytesAtomically(destination, data, 0o640); err != nil {
			return fmt.Errorf("publish support evidence %s: %w", name, err)
		}
	}
	return nil
}

func writeJSONAtomically(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal %s: %w", filepath.Base(path), err)
	}
	data = append(data, '\n')
	return writeBytesAtomically(path, data, 0o644)
}

func writeBytesAtomically(path string, data []byte, mode os.FileMode) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return fmt.Errorf("create state directory %s: %w", directory, err)
	}
	temporary, err := os.CreateTemp(directory, "."+filepath.Base(path)+".*.tmp")
	if err != nil {
		return fmt.Errorf("create temporary state file for %s: %w", path, err)
	}
	temporaryPath := temporary.Name()
	committed := false
	defer func() {
		if !committed {
			_ = os.Remove(temporaryPath)
		}
	}()

	if err := temporary.Chmod(mode); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("set mode on temporary state file %s: %w", temporaryPath, err)
	}
	if _, err := temporary.Write(data); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("write temporary state file %s: %w", temporaryPath, err)
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("sync temporary state file %s: %w", temporaryPath, err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close temporary state file %s: %w", temporaryPath, err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("replace state file %s: %w", path, err)
	}
	committed = true

	if runtime.GOOS != "windows" {
		directoryHandle, err := os.Open(directory)
		if err != nil {
			return fmt.Errorf("open state directory %s for sync: %w", directory, err)
		}
		syncErr := directoryHandle.Sync()
		closeErr := directoryHandle.Close()
		if syncErr != nil {
			return fmt.Errorf("sync state directory %s: %w", directory, syncErr)
		}
		if closeErr != nil {
			return fmt.Errorf("close state directory %s: %w", directory, closeErr)
		}
	}
	return nil
}

func readOptionalFile(path string) ([]byte, bool, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("read %s: %w", path, err)
	}
	return data, true, nil
}

func buildAcknowledgement(
	state parsedDesiredState,
	previous desiredState,
	activeSlots int,
	minimumIdle int,
	now time.Time,
) acknowledgement {
	added, draining, unchanged := diffSlotKeys(previous, state.state)
	return acknowledgement{
		SchemaVersion:          1,
		Status:                 "accepted",
		Generation:             state.state.Generation,
		ManagerContractVersion: managerContractVersion,
		DesiredStateHash:       state.stateHash,
		ObservedAt:             now.UTC().Format(time.RFC3339),
		DesiredSlots:           len(configuredSlotKeys(state.state)),
		AddedSlots:             len(added),
		DrainingSlots:          len(draining),
		UnchangedSlots:         len(unchanged),
		AddedKeys:              added,
		DrainingKeys:           draining,
		UnchangedKeys:          unchanged,
		ActivationMode:         "autoscaled",
		ActiveSlots:            activeSlots,
		MinimumIdleSlots:       minimumIdle,
	}
}
