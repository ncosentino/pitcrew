package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

const (
	registrationFenceScaleDown   = "scale-down"
	registrationFenceStale       = "stale"
	registrationFenceShutdown    = "shutdown"
	registrationFenceContractVersion = 22
)

type registrationFenceRecord struct {
	TargetKey     string `json:"targetKey"`
	SlotKey       string `json:"slotKey"`
	Purpose       string `json:"purpose"`
	RunnerID      int64  `json:"runnerId"`
	RunnerName    string `json:"runnerName"`
	ContainerID   string `json:"containerId"`
	ContainerName string `json:"containerName"`
	Attempts      int    `json:"attempts"`
	FirstFailedAt string `json:"firstFailedAt"`
	LastAttemptAt string `json:"lastAttemptAt"`
	NextAttemptAt string `json:"nextAttemptAt"`
}

type registrationFenceDocument struct {
	SchemaVersion          int                       `json:"schemaVersion"`
	ManagerContractVersion int                       `json:"managerContractVersion"`
	TargetKey              string                    `json:"targetKey"`
	Records                []registrationFenceRecord `json:"records"`
}

type registrationFenceStore interface {
	load() ([]registrationFenceRecord, error)
	save(records []registrationFenceRecord) error
}

func newRegistrationFenceStore(
	stateDirectory string,
	targetKey string,
) registrationFenceStore {
	if stateDirectory == "" {
		return &memoryRegistrationFenceStore{}
	}
	return &fileRegistrationFenceStore{
		path:      registrationFencePath(stateDirectory, targetKey),
		targetKey: targetKey,
	}
}

func registrationFencePath(stateDirectory string, targetKey string) string {
	digest := sha256.Sum256([]byte(targetKey))
	name := sanitizeIdentifier(targetKey, 48)
	if name == "" {
		name = "target"
	}
	return filepath.Join(
		stateDirectory,
		"registration-fence",
		name+"-"+hex.EncodeToString(digest[:4])+".json",
	)
}

type memoryRegistrationFenceStore struct {
	mu      sync.Mutex
	records []registrationFenceRecord
}

func (s *memoryRegistrationFenceStore) load() ([]registrationFenceRecord, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]registrationFenceRecord(nil), s.records...), nil
}

func (s *memoryRegistrationFenceStore) save(records []registrationFenceRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.records = append([]registrationFenceRecord(nil), records...)
	return nil
}

type fileRegistrationFenceStore struct {
	mu        sync.Mutex
	path      string
	targetKey string
}

func (s *fileRegistrationFenceStore) load() ([]registrationFenceRecord, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, exists, err := readOptionalFile(s.path)
	if err != nil || !exists {
		return nil, err
	}
	document, err := parseRegistrationFenceDocument(data, s.targetKey)
	if err != nil {
		return nil, err
	}
	return document.Records, nil
}

func (s *fileRegistrationFenceStore) save(records []registrationFenceRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(records) == 0 {
		if err := os.Remove(s.path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	ordered := append([]registrationFenceRecord(nil), records...)
	sort.Slice(ordered, func(i, j int) bool {
		return ordered[i].SlotKey < ordered[j].SlotKey
	})
	return writeJSONAtomically(s.path, registrationFenceDocument{
		SchemaVersion:          1,
		ManagerContractVersion: registrationFenceContractVersion,
		TargetKey:              s.targetKey,
		Records:                ordered,
	})
}

func parseRegistrationFenceDocument(
	data []byte,
	targetKey string,
) (registrationFenceDocument, error) {
	var document registrationFenceDocument
	if err := json.Unmarshal(data, &document); err != nil {
		return registrationFenceDocument{}, err
	}
	if document.SchemaVersion != 1 ||
		document.ManagerContractVersion < registrationFenceContractVersion ||
		document.ManagerContractVersion > managerContractVersion ||
		document.TargetKey != targetKey {
		return registrationFenceDocument{}, errors.New(
			"registration fence document is incompatible",
		)
	}
	seen := make(map[string]struct{}, len(document.Records))
	for index, record := range document.Records {
		if record.TargetKey != targetKey ||
			record.SlotKey == "" ||
			record.RunnerID < 1 ||
			record.RunnerName == "" ||
			record.ContainerID == "" ||
			record.Attempts < 0 {
			return registrationFenceDocument{}, fmt.Errorf(
				"registration fence record at index %d is incomplete",
				index,
			)
		}
		if record.Purpose != registrationFenceScaleDown &&
			record.Purpose != registrationFenceStale &&
			record.Purpose != registrationFenceShutdown {
			return registrationFenceDocument{}, fmt.Errorf(
				"registration fence record at index %d has unsupported purpose",
				index,
			)
		}
		if record.Attempts > maxRegistrationCleanupAttempts {
			document.Records[index].Attempts = maxRegistrationCleanupAttempts
		}
		for _, value := range []string{
			record.FirstFailedAt,
			record.LastAttemptAt,
			record.NextAttemptAt,
		} {
			if value == "" {
				continue
			}
			if _, err := time.Parse(time.RFC3339, value); err != nil {
				return registrationFenceDocument{}, fmt.Errorf(
					"registration fence record at index %d has invalid timestamp",
					index,
				)
			}
		}
		if _, exists := seen[record.SlotKey]; exists {
			return registrationFenceDocument{}, fmt.Errorf(
				"registration fence contains duplicate slot %q",
				record.SlotKey,
			)
		}
		seen[record.SlotKey] = struct{}{}
	}
	return document, nil
}

func registrationFenceDue(record registrationFenceRecord, now time.Time) bool {
	if record.NextAttemptAt == "" {
		return true
	}
	nextAttemptAt, err := time.Parse(time.RFC3339, record.NextAttemptAt)
	if err != nil {
		return false
	}
	return !now.Before(nextAttemptAt)
}
