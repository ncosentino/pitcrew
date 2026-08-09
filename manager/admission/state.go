package admission

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
)

// stateSchemaVersion is the exact durable-state schema this coordinator
// build understands. A restart that finds any other value fails closed
// rather than guessing forward or backward compatibility.
const stateSchemaVersion = 1

// ErrCorruptState reports durable state that cannot be safely trusted:
// invalid JSON, an unsupported schema version, or an internally
// inconsistent document. The coordinator never treats this as an empty
// budget or permission to admit; Open returns the error and grants nothing.
var ErrCorruptState = errors.New("admission: corrupt or unsupported durable state")

// durableState is the exact, restart-durable ledger the coordinator
// persists: the last accepted policy, every live lease, and every release
// tombstone, plus the monotonic epoch and decision sequence that make
// restart and reconciliation exact.
type durableState struct {
	SchemaVersion    int                  `json:"schemaVersion"`
	Epoch            int64                `json:"epoch"`
	DecisionSequence int64                `json:"decisionSequence"`
	Policy           HostPolicy           `json:"policy"`
	Leases           map[string]Lease     `json:"leases"`
	Tombstones       map[string]Tombstone `json:"tombstones"`
}

func newDurableState() durableState {
	return durableState{
		SchemaVersion: stateSchemaVersion,
		Leases:        make(map[string]Lease),
		Tombstones:    make(map[string]Tombstone),
	}
}

func (s durableState) clone() durableState {
	cloned := durableState{
		SchemaVersion:    s.SchemaVersion,
		Epoch:            s.Epoch,
		DecisionSequence: s.DecisionSequence,
		Policy:           clonePolicy(s.Policy),
		Leases:           make(map[string]Lease, len(s.Leases)),
		Tombstones:       make(map[string]Tombstone, len(s.Tombstones)),
	}
	for key, lease := range s.Leases {
		cloned.Leases[key] = lease
	}
	for key, tombstone := range s.Tombstones {
		cloned.Tombstones[key] = tombstone
	}
	return cloned
}

// validate checks internal structural consistency of a decoded document.
// It intentionally does not require every lease's profile to still exist in
// the current policy: a profile removed from policy while leases remain
// active must drain naturally rather than fail state validation.
func (s durableState) validate() error {
	if s.SchemaVersion != stateSchemaVersion {
		return fmt.Errorf(
			"%w: schemaVersion must be %d, got %d",
			ErrCorruptState,
			stateSchemaVersion,
			s.SchemaVersion,
		)
	}
	if s.Epoch < 0 || s.DecisionSequence < 0 {
		return fmt.Errorf("%w: epoch and decision sequence cannot be negative", ErrCorruptState)
	}
	if s.Policy.Generation > 0 {
		if err := s.Policy.validate(); err != nil {
			return fmt.Errorf("%w: %v", ErrCorruptState, err)
		}
	}
	for key, lease := range s.Leases {
		if key != lease.key().String() {
			return fmt.Errorf(
				"%w: lease key %q does not match lease identity %q",
				ErrCorruptState,
				key,
				lease.key().String(),
			)
		}
		if lease.ProfileID == "" || lease.SlotKey == "" || lease.Units < 1 {
			return fmt.Errorf("%w: lease %q is incomplete", ErrCorruptState, key)
		}
		if lease.Status != LeaseProvisional && lease.Status != LeaseActive {
			return fmt.Errorf(
				"%w: lease %q has unsupported status %q",
				ErrCorruptState,
				key,
				lease.Status,
			)
		}
	}
	for key, tombstone := range s.Tombstones {
		expected := leaseKey{profileID: tombstone.ProfileID, slotKey: tombstone.SlotKey}.String()
		if key != expected {
			return fmt.Errorf(
				"%w: tombstone key %q does not match tombstone identity %q",
				ErrCorruptState,
				key,
				expected,
			)
		}
	}
	for key := range s.Leases {
		if _, tombstoned := s.Tombstones[key]; tombstoned {
			return fmt.Errorf(
				"%w: key %q has both a live lease and a tombstone",
				ErrCorruptState,
				key,
			)
		}
	}
	return nil
}

// store persists and restores durableState. Load must fail closed: a
// missing document is a legitimate fresh start, but a present, corrupt, or
// unsupported document must return an error rather than an empty state.
type store interface {
	Load() (durableState, bool, error)
	Save(durableState) error
}

// memoryStore is a non-durable store used for tests and standalone use
// without a configured durable state path.
type memoryStore struct {
	state  durableState
	exists bool
}

func newMemoryStore() *memoryStore {
	return &memoryStore{}
}

func (m *memoryStore) Load() (durableState, bool, error) {
	if !m.exists {
		return durableState{}, false, nil
	}
	return m.state.clone(), true, nil
}

func (m *memoryStore) Save(state durableState) error {
	m.state = state.clone()
	m.exists = true
	return nil
}

// fileStore persists durableState as a single atomically replaced JSON
// document at a fixed path, following the same temp-file-plus-rename plus
// directory-fsync convention used elsewhere in the manager.
type fileStore struct {
	path string
}

// newFileStore builds a durable store rooted at the given directory. The
// directory is the durable state path later setup wiring mounts from the
// admission service's internal named volume; this package only requires
// that the directory exists or can be created.
func newFileStore(directory string) *fileStore {
	return &fileStore{path: filepath.Join(directory, "admission-state.json")}
}

func (f *fileStore) Load() (durableState, bool, error) {
	data, err := os.ReadFile(f.path)
	if errors.Is(err, os.ErrNotExist) {
		return durableState{}, false, nil
	}
	if err != nil {
		return durableState{}, false, fmt.Errorf("read admission state %s: %w", f.path, err)
	}
	var state durableState
	if err := json.Unmarshal(data, &state); err != nil {
		return durableState{}, false, fmt.Errorf("%w: %v", ErrCorruptState, err)
	}
	if state.Leases == nil {
		state.Leases = make(map[string]Lease)
	}
	if state.Tombstones == nil {
		state.Tombstones = make(map[string]Tombstone)
	}
	if err := state.validate(); err != nil {
		return durableState{}, false, err
	}
	return state, true, nil
}

func (f *fileStore) Save(state durableState) error {
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal admission state: %w", err)
	}
	data = append(data, '\n')
	return writeFileAtomically(f.path, data)
}

// writeFileAtomically writes data to path through a temporary file in the
// same directory, syncs it, and renames it into place, so a crash never
// leaves a partially written durable-state document.
func writeFileAtomically(path string, data []byte) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return fmt.Errorf("create admission state directory %s: %w", directory, err)
	}
	temporary, err := os.CreateTemp(directory, "."+filepath.Base(path)+".*.tmp")
	if err != nil {
		return fmt.Errorf("create temporary admission state file: %w", err)
	}
	temporaryPath := temporary.Name()
	committed := false
	defer func() {
		if !committed {
			_ = os.Remove(temporaryPath)
		}
	}()

	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("set mode on temporary admission state file: %w", err)
	}
	if _, err := temporary.Write(data); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("write temporary admission state file: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("sync temporary admission state file: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close temporary admission state file: %w", err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("replace admission state file %s: %w", path, err)
	}
	committed = true

	if runtime.GOOS != "windows" {
		directoryHandle, err := os.Open(directory)
		if err != nil {
			return fmt.Errorf("open admission state directory %s for sync: %w", directory, err)
		}
		syncErr := directoryHandle.Sync()
		closeErr := directoryHandle.Close()
		if syncErr != nil {
			return fmt.Errorf("sync admission state directory %s: %w", directory, syncErr)
		}
		if closeErr != nil {
			return fmt.Errorf("close admission state directory %s: %w", directory, closeErr)
		}
	}
	return nil
}

// sortedStateKeys returns lease/tombstone map keys in a stable order for
// deterministic snapshot output.
func sortedStateKeys[V any](values map[string]V) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

// maxTombstones bounds the durable tombstone ledger so an unbounded stream
// of releases, expirations, and reconciliations can never grow the durable
// state document without limit. Compaction always keeps the newest entries
// by decision sequence: a newer tombstone is strictly more relevant to
// idempotent release and fenced recovery than an older one.
const maxTombstones = 4096

// compactTombstones trims state.Tombstones to at most maxTombstones entries,
// keeping the newest by Sequence. It is a no-op at or below the bound.
func compactTombstones(state durableState) durableState {
	if len(state.Tombstones) <= maxTombstones {
		return state
	}
	type tombstoneEntry struct {
		key       string
		tombstone Tombstone
	}
	entries := make([]tombstoneEntry, 0, len(state.Tombstones))
	for key, tombstone := range state.Tombstones {
		entries = append(entries, tombstoneEntry{key: key, tombstone: tombstone})
	}
	sort.Slice(entries, func(i, j int) bool {
		return entries[i].tombstone.Sequence > entries[j].tombstone.Sequence
	})
	trimmed := make(map[string]Tombstone, maxTombstones)
	for i := 0; i < maxTombstones; i++ {
		trimmed[entries[i].key] = entries[i].tombstone
	}
	state.Tombstones = trimmed
	return state
}
