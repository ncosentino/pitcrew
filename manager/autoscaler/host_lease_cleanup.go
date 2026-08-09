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

// maxPendingHostLeaseReleases bounds the durable host-lease release backlog.
const maxPendingHostLeaseReleases = 64

// hostLeaseReleaseRetryDelay paces retries of failed host admission lease
// releases.
const hostLeaseReleaseRetryDelay = 15 * time.Second

// hostLeaseCleanupRecord carries only the identity and retry metadata needed
// to release one exact host admission lease. It never carries JIT
// configuration, credentials, job output, or any other private evidence.
type hostLeaseCleanupRecord struct {
	TargetKey     string `json:"targetKey"`
	RunnerKey     string `json:"runnerKey"`
	HostSlotKey   string `json:"hostSlotKey"`
	Attempts      int    `json:"attempts"`
	FirstFailedAt string `json:"firstFailedAt"`
	LastAttemptAt string `json:"lastAttemptAt"`
	NextAttemptAt string `json:"nextAttemptAt"`
}

type hostLeaseCleanupDocument struct {
	SchemaVersion          int                      `json:"schemaVersion"`
	ManagerContractVersion int                      `json:"managerContractVersion"`
	TargetKey              string                   `json:"targetKey"`
	Records                []hostLeaseCleanupRecord `json:"records"`
}

// The host-lease cleanup document format was introduced at contract 17.
// Pinning this value keeps pending release state readable if a manager image
// handoff rolls back within contract 17.
const hostLeaseCleanupDocumentContractVersion = 17

type hostLeaseCleanupStore interface {
	load() ([]hostLeaseCleanupRecord, error)
	save(records []hostLeaseCleanupRecord) error
}

func newHostLeaseCleanupStore(
	stateDirectory string,
	targetKey string,
) hostLeaseCleanupStore {
	if stateDirectory == "" {
		return &memoryHostLeaseCleanupStore{}
	}
	return &fileHostLeaseCleanupStore{
		path:      hostLeaseCleanupPath(stateDirectory, targetKey),
		targetKey: targetKey,
	}
}

func hostLeaseCleanupPath(stateDirectory, targetKey string) string {
	digest := sha256.Sum256([]byte(targetKey))
	name := sanitizeIdentifier(targetKey, 48)
	if name == "" {
		name = "target"
	}
	return filepath.Join(
		stateDirectory,
		"host-lease-cleanup",
		name+"-"+hex.EncodeToString(digest[:4])+".json",
	)
}

type memoryHostLeaseCleanupStore struct {
	mu      sync.Mutex
	records []hostLeaseCleanupRecord
}

func (s *memoryHostLeaseCleanupStore) load() ([]hostLeaseCleanupRecord, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]hostLeaseCleanupRecord(nil), s.records...), nil
}

func (s *memoryHostLeaseCleanupStore) save(records []hostLeaseCleanupRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.records = append([]hostLeaseCleanupRecord(nil), records...)
	return nil
}

type fileHostLeaseCleanupStore struct {
	mu        sync.Mutex
	path      string
	targetKey string
}

func (s *fileHostLeaseCleanupStore) load() ([]hostLeaseCleanupRecord, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, exists, err := readOptionalFile(s.path)
	if err != nil {
		return nil, err
	}
	if !exists {
		return nil, nil
	}
	document, err := parseHostLeaseCleanupDocument(data, s.targetKey)
	if err != nil {
		return nil, err
	}
	return document.Records, nil
}

func (s *fileHostLeaseCleanupStore) save(records []hostLeaseCleanupRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(records) == 0 {
		if err := os.Remove(s.path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("clear host lease cleanup state %s: %w", s.path, err)
		}
		return nil
	}
	ordered := append([]hostLeaseCleanupRecord(nil), records...)
	sort.Slice(ordered, func(i, j int) bool {
		return ordered[i].HostSlotKey < ordered[j].HostSlotKey
	})
	return writeJSONAtomically(s.path, hostLeaseCleanupDocument{
		SchemaVersion:          1,
		ManagerContractVersion: hostLeaseCleanupDocumentContractVersion,
		TargetKey:              s.targetKey,
		Records:                ordered,
	})
}

func parseHostLeaseCleanupDocument(
	data []byte,
	targetKey string,
) (hostLeaseCleanupDocument, error) {
	var document hostLeaseCleanupDocument
	if err := json.Unmarshal(data, &document); err != nil {
		return hostLeaseCleanupDocument{}, fmt.Errorf(
			"decode host lease cleanup document: %w",
			err,
		)
	}
	if document.SchemaVersion != 1 {
		return hostLeaseCleanupDocument{}, fmt.Errorf(
			"host lease cleanup schemaVersion must be 1, got %d",
			document.SchemaVersion,
		)
	}
	if document.ManagerContractVersion < hostLeaseCleanupDocumentContractVersion ||
		document.ManagerContractVersion > managerContractVersion {
		return hostLeaseCleanupDocument{}, fmt.Errorf(
			"host lease cleanup managerContractVersion must be between %d and %d, got %d",
			hostLeaseCleanupDocumentContractVersion,
			managerContractVersion,
			document.ManagerContractVersion,
		)
	}
	if document.TargetKey != targetKey {
		return hostLeaseCleanupDocument{}, fmt.Errorf(
			"host lease cleanup document targets %q, not %q",
			document.TargetKey,
			targetKey,
		)
	}
	seen := make(map[string]struct{}, len(document.Records))
	for index, record := range document.Records {
		if record.TargetKey != targetKey ||
			record.RunnerKey == "" ||
			record.HostSlotKey == "" {
			return hostLeaseCleanupDocument{}, fmt.Errorf(
				"host lease cleanup record at index %d is incomplete",
				index,
			)
		}
		if _, exists := seen[record.HostSlotKey]; exists {
			return hostLeaseCleanupDocument{}, fmt.Errorf(
				"host lease cleanup contains duplicate slot %q",
				record.HostSlotKey,
			)
		}
		seen[record.HostSlotKey] = struct{}{}
	}
	if len(document.Records) > maxPendingHostLeaseReleases {
		return hostLeaseCleanupDocument{}, fmt.Errorf(
			"host lease cleanup holds %d records, more than the %d bound",
			len(document.Records),
			maxPendingHostLeaseReleases,
		)
	}
	return document, nil
}

func hostLeaseReleaseDue(record hostLeaseCleanupRecord, now time.Time) bool {
	if record.NextAttemptAt == "" {
		return true
	}
	nextAttemptAt, err := time.Parse(time.RFC3339, record.NextAttemptAt)
	if err != nil {
		return true
	}
	return !now.Before(nextAttemptAt)
}
