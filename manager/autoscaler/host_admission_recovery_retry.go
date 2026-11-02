package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"
)

type hostAdmissionRecoveryRetryState struct {
	SchemaVersion          int    `json:"schemaVersion"`
	ManagerContractVersion int    `json:"managerContractVersion"`
	ProfileID              string `json:"profileId"`
	Attempts               int    `json:"attempts"`
	LastAttemptAt          string `json:"lastAttemptAt"`
	NextAttemptAt          string `json:"nextAttemptAt"`
}

func loadHostAdmissionRecoveryRetryState(
	path string,
	profileID string,
) (hostAdmissionRecoveryRetryState, bool, error) {
	data, exists, err := readOptionalFile(path)
	if err != nil || !exists {
		return hostAdmissionRecoveryRetryState{}, exists, err
	}
	var state hostAdmissionRecoveryRetryState
	if err := json.Unmarshal(data, &state); err != nil {
		return hostAdmissionRecoveryRetryState{}, true, fmt.Errorf(
			"decode host admission recovery retry state: %w",
			err,
		)
	}
	if state.SchemaVersion != 1 ||
		state.ManagerContractVersion < 22 ||
		state.ManagerContractVersion > managerContractVersion ||
		state.ProfileID != profileID ||
		state.Attempts < 0 {
		return hostAdmissionRecoveryRetryState{}, true, errors.New(
			"host admission recovery retry state is incompatible",
		)
	}
	if state.Attempts > maxRegistrationCleanupAttempts {
		state.Attempts = maxRegistrationCleanupAttempts
	}
	for _, value := range []string{state.LastAttemptAt, state.NextAttemptAt} {
		if value == "" {
			continue
		}
		if _, err := time.Parse(time.RFC3339, value); err != nil {
			return hostAdmissionRecoveryRetryState{}, true, errors.New(
				"host admission recovery retry state has an invalid timestamp",
			)
		}
	}
	return state, true, nil
}

func saveHostAdmissionRecoveryRetryState(
	path string,
	state hostAdmissionRecoveryRetryState,
) error {
	return writeJSONAtomically(path, state)
}

func clearHostAdmissionRecoveryRetryState(path string) error {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}
