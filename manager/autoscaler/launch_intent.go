package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

const launchIntentContractVersion = 22

type launchIntentRecord struct {
	SchemaVersion          int    `json:"schemaVersion"`
	ManagerContractVersion int    `json:"managerContractVersion"`
	TargetKey              string `json:"targetKey"`
	RunnerName             string `json:"runnerName"`
	RunnerID               int64  `json:"runnerId,omitempty"`
	Attempts               int    `json:"attempts"`
	LastAttemptAt          string `json:"lastAttemptAt"`
	NextAttemptAt          string `json:"nextAttemptAt"`
}

type launchIntentStore interface {
	load() (launchIntentRecord, bool, error)
	save(record launchIntentRecord) error
	clear() error
}

func newLaunchIntentStore(
	stateDirectory string,
	targetKey string,
) launchIntentStore {
	if stateDirectory == "" {
		return &memoryLaunchIntentStore{}
	}
	return &fileLaunchIntentStore{
		path:      launchIntentPath(stateDirectory, targetKey),
		targetKey: targetKey,
	}
}

func launchIntentPath(stateDirectory string, targetKey string) string {
	digest := sha256.Sum256([]byte(targetKey))
	name := sanitizeIdentifier(targetKey, 48)
	if name == "" {
		name = "target"
	}
	return filepath.Join(
		stateDirectory,
		"launch-intent",
		name+"-"+hex.EncodeToString(digest[:4])+".json",
	)
}

type memoryLaunchIntentStore struct {
	record launchIntentRecord
	exists bool
}

func (s *memoryLaunchIntentStore) load() (launchIntentRecord, bool, error) {
	return s.record, s.exists, nil
}

func (s *memoryLaunchIntentStore) save(record launchIntentRecord) error {
	s.record = record
	s.exists = true
	return nil
}

func (s *memoryLaunchIntentStore) clear() error {
	s.record = launchIntentRecord{}
	s.exists = false
	return nil
}

type fileLaunchIntentStore struct {
	path      string
	targetKey string
}

func (s *fileLaunchIntentStore) load() (launchIntentRecord, bool, error) {
	data, exists, err := readOptionalFile(s.path)
	if err != nil || !exists {
		return launchIntentRecord{}, exists, err
	}
	var record launchIntentRecord
	if err := json.Unmarshal(data, &record); err != nil {
		return launchIntentRecord{}, true, err
	}
	if record.SchemaVersion != 1 ||
		record.ManagerContractVersion < launchIntentContractVersion ||
		record.ManagerContractVersion > managerContractVersion ||
		record.TargetKey != s.targetKey ||
		record.RunnerName == "" ||
		record.RunnerID < 0 ||
		record.Attempts < 1 {
		return launchIntentRecord{}, true, errors.New(
			"launch intent is incompatible",
		)
	}
	if record.Attempts > maxRegistrationCleanupAttempts {
		record.Attempts = maxRegistrationCleanupAttempts
	}
	for _, value := range []string{record.LastAttemptAt, record.NextAttemptAt} {
		if value == "" {
			continue
		}
		if _, err := time.Parse(time.RFC3339, value); err != nil {
			return launchIntentRecord{}, true, errors.New(
				"launch intent has an invalid timestamp",
			)
		}
	}
	return record, true, nil
}

func (s *fileLaunchIntentStore) save(record launchIntentRecord) error {
	return writeJSONAtomically(s.path, record)
}

func (s *fileLaunchIntentStore) clear() error {
	if err := os.Remove(s.path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("clear launch intent: %w", err)
	}
	return nil
}
