package main

import (
	"encoding/json"
	"errors"
	"os"
	"time"
)

type registrationAccessRetryState struct {
	SchemaVersion          int    `json:"schemaVersion"`
	ManagerContractVersion int    `json:"managerContractVersion"`
	ProfileID              string `json:"profileId"`
	ConsecutiveFailures    int    `json:"consecutiveFailures"`
	NextCheckAt            string `json:"nextCheckAt"`
}

func loadRegistrationAccessRetryState(
	path string,
	profileID string,
) (registrationAccessRetryState, bool, error) {
	data, exists, err := readOptionalFile(path)
	if err != nil || !exists {
		return registrationAccessRetryState{}, exists, err
	}
	var state registrationAccessRetryState
	if err := json.Unmarshal(data, &state); err != nil {
		return registrationAccessRetryState{}, true, err
	}
	if state.SchemaVersion != 1 ||
		state.ManagerContractVersion < 22 ||
		state.ManagerContractVersion > managerContractVersion ||
		state.ProfileID != profileID ||
		state.ConsecutiveFailures < 0 ||
		state.NextCheckAt == "" {
		return registrationAccessRetryState{}, true, errors.New(
			"registration access retry state is incompatible",
		)
	}
	if state.ConsecutiveFailures > maxRegistrationCleanupAttempts {
		state.ConsecutiveFailures = maxRegistrationCleanupAttempts
	}
	if _, err := time.Parse(time.RFC3339, state.NextCheckAt); err != nil {
		return registrationAccessRetryState{}, true, err
	}
	return state, true, nil
}

func saveRegistrationAccessRetryState(
	path string,
	state registrationAccessRetryState,
) error {
	return writeJSONAtomically(path, state)
}

func clearRegistrationAccessRetryState(path string) error {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}
