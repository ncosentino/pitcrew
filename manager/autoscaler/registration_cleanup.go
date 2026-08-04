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

// maxPendingRegistrationCleanups bounds the durable cleanup-pending backlog.
const maxPendingRegistrationCleanups = 64

// registrationCleanupRetryDelay paces retries of failed registration removal.
const registrationCleanupRetryDelay = 15 * time.Second

// registrationCleanupRecord carries only the identity and retry metadata needed
// to remove one exact JIT registration. It never carries JIT configuration,
// credentials, or job output.
type registrationCleanupRecord struct {
	TargetKey     string `json:"targetKey"`
	SlotKey       string `json:"slotKey"`
	RunnerID      int64  `json:"runnerId"`
	RunnerName    string `json:"runnerName"`
	ContainerID   string `json:"containerId"`
	ContainerName string `json:"containerName"`
	Attempts      int    `json:"attempts"`
	FirstFailedAt string `json:"firstFailedAt"`
	LastAttemptAt string `json:"lastAttemptAt"`
	NextAttemptAt string `json:"nextAttemptAt"`
	// LastExit carries the exit evidence captured for this exact worker so it
	// survives a manager restart tied to the same runner and container identity.
	LastExit *lastExitDiagnostic `json:"lastExit,omitempty"`
}

type registrationCleanupDocument struct {
	SchemaVersion          int                         `json:"schemaVersion"`
	ManagerContractVersion int                         `json:"managerContractVersion"`
	TargetKey              string                      `json:"targetKey"`
	Records                []registrationCleanupRecord `json:"records"`
}

// The cleanup document format has not changed since contract 10. Pinning this
// value keeps pending cleanup readable if a manager image handoff rolls back.
const registrationCleanupDocumentContractVersion = 10

type registrationCleanupStore interface {
	load() ([]registrationCleanupRecord, error)
	save(records []registrationCleanupRecord) error
}

func newRegistrationCleanupStore(
	stateDirectory string,
	targetKey string,
) registrationCleanupStore {
	if stateDirectory == "" {
		return &memoryRegistrationCleanupStore{}
	}
	return &fileRegistrationCleanupStore{
		path:      registrationCleanupPath(stateDirectory, targetKey),
		targetKey: targetKey,
	}
}

func registrationCleanupPath(stateDirectory, targetKey string) string {
	digest := sha256.Sum256([]byte(targetKey))
	name := sanitizeIdentifier(targetKey, 48)
	if name == "" {
		name = "target"
	}
	return filepath.Join(
		stateDirectory,
		"registration-cleanup",
		name+"-"+hex.EncodeToString(digest[:4])+".json",
	)
}

type memoryRegistrationCleanupStore struct {
	mu      sync.Mutex
	records []registrationCleanupRecord
}

func (s *memoryRegistrationCleanupStore) load() ([]registrationCleanupRecord, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]registrationCleanupRecord(nil), s.records...), nil
}

func (s *memoryRegistrationCleanupStore) save(records []registrationCleanupRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.records = append([]registrationCleanupRecord(nil), records...)
	return nil
}

type fileRegistrationCleanupStore struct {
	mu        sync.Mutex
	path      string
	targetKey string
}

func (s *fileRegistrationCleanupStore) load() ([]registrationCleanupRecord, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, exists, err := readOptionalFile(s.path)
	if err != nil {
		return nil, err
	}
	if !exists {
		return nil, nil
	}
	document, err := parseRegistrationCleanupDocument(data, s.targetKey)
	if err != nil {
		return nil, err
	}
	return document.Records, nil
}

func (s *fileRegistrationCleanupStore) save(records []registrationCleanupRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(records) == 0 {
		if err := os.Remove(s.path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("clear registration cleanup state %s: %w", s.path, err)
		}
		return nil
	}
	ordered := append([]registrationCleanupRecord(nil), records...)
	sort.Slice(ordered, func(i, j int) bool {
		return ordered[i].SlotKey < ordered[j].SlotKey
	})
	return writeJSONAtomically(s.path, registrationCleanupDocument{
		SchemaVersion:          1,
		ManagerContractVersion: registrationCleanupDocumentContractVersion,
		TargetKey:              s.targetKey,
		Records:                ordered,
	})
}

func parseRegistrationCleanupDocument(
	data []byte,
	targetKey string,
) (registrationCleanupDocument, error) {
	var document registrationCleanupDocument
	if err := json.Unmarshal(data, &document); err != nil {
		return registrationCleanupDocument{}, fmt.Errorf(
			"decode registration cleanup document: %w",
			err,
		)
	}
	if document.SchemaVersion != 1 {
		return registrationCleanupDocument{}, fmt.Errorf(
			"registration cleanup schemaVersion must be 1, got %d",
			document.SchemaVersion,
		)
	}
	if document.ManagerContractVersion < 10 ||
		document.ManagerContractVersion > managerContractVersion {
		return registrationCleanupDocument{}, fmt.Errorf(
			"registration cleanup managerContractVersion must be between 10 and %d, got %d",
			managerContractVersion,
			document.ManagerContractVersion,
		)
	}
	if document.TargetKey != targetKey {
		return registrationCleanupDocument{}, fmt.Errorf(
			"registration cleanup document targets %q, not %q",
			document.TargetKey,
			targetKey,
		)
	}
	seen := make(map[string]struct{}, len(document.Records))
	for index, record := range document.Records {
		if record.TargetKey != targetKey ||
			record.SlotKey == "" ||
			record.RunnerID < 1 ||
			record.RunnerName == "" ||
			record.ContainerID == "" {
			return registrationCleanupDocument{}, fmt.Errorf(
				"registration cleanup record at index %d is incomplete",
				index,
			)
		}
		if _, exists := seen[record.SlotKey]; exists {
			return registrationCleanupDocument{}, fmt.Errorf(
				"registration cleanup contains duplicate slot %q",
				record.SlotKey,
			)
		}
		seen[record.SlotKey] = struct{}{}
	}
	if len(document.Records) > maxPendingRegistrationCleanups {
		return registrationCleanupDocument{}, fmt.Errorf(
			"registration cleanup holds %d records, more than the %d bound",
			len(document.Records),
			maxPendingRegistrationCleanups,
		)
	}
	return document, nil
}

func registrationCleanupDue(record registrationCleanupRecord, now time.Time) bool {
	if record.NextAttemptAt == "" {
		return true
	}
	nextAttemptAt, err := time.Parse(time.RFC3339, record.NextAttemptAt)
	if err != nil {
		return true
	}
	return !now.Before(nextAttemptAt)
}
