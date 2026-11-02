package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

type contract10CleanupRecord struct {
	TargetKey     string `json:"targetKey"`
	SlotKey       string `json:"slotKey"`
	RunnerID      int64  `json:"runnerId"`
	RunnerName    string `json:"runnerName"`
	ContainerID   string `json:"containerId"`
	ContainerName string `json:"containerName"`
}

type contract10CleanupDocument struct {
	SchemaVersion          int                       `json:"schemaVersion"`
	ManagerContractVersion int                       `json:"managerContractVersion"`
	TargetKey              string                    `json:"targetKey"`
	Records                []contract10CleanupRecord `json:"records"`
}

func validRegistrationCleanupRecord() registrationCleanupRecord {
	return registrationCleanupRecord{
		TargetKey:     "repo-1234",
		SlotKey:       "repo-1234-7",
		RunnerID:      7,
		RunnerName:    "pitcrew-runner-repo-1234-suffix01",
		ContainerID:   "container-1",
		ContainerName: "pitcrew-runner-repo-1234-suffix01",
		Attempts:      1,
		FirstFailedAt: "2026-07-20T12:00:00Z",
		LastAttemptAt: "2026-07-20T12:00:00Z",
		NextAttemptAt: "2026-07-20T12:01:00Z",
	}
}

func TestRegistrationCleanupStoreRoundTripsAndClears(t *testing.T) {
	directory := projectTestDirectory(t)
	store := newRegistrationCleanupStore(directory, "repo-1234")
	record := validRegistrationCleanupRecord()
	if err := store.save([]registrationCleanupRecord{record}); err != nil {
		t.Fatalf("save registration cleanup: %v", err)
	}
	data, err := os.ReadFile(registrationCleanupPath(directory, "repo-1234"))
	if err != nil {
		t.Fatalf("read registration cleanup: %v", err)
	}
	document, err := parseRegistrationCleanupDocument(data, "repo-1234")
	if err != nil ||
		document.ManagerContractVersion != registrationCleanupDocumentContractVersion {
		t.Fatalf("registration cleanup used a rollback-incompatible format: %#v %v", document, err)
	}
	restored, err := store.load()
	if err != nil {
		t.Fatalf("load registration cleanup: %v", err)
	}
	if len(restored) != 1 || restored[0] != record {
		t.Fatalf("registration cleanup did not round trip: %#v", restored)
	}
	if err := store.save(nil); err != nil {
		t.Fatalf("clear registration cleanup: %v", err)
	}
	if _, err := os.Stat(registrationCleanupPath(directory, "repo-1234")); !os.IsNotExist(err) {
		t.Fatalf("cleared registration cleanup left state behind: %v", err)
	}
	empty, err := store.load()
	if err != nil || len(empty) != 0 {
		t.Fatalf("cleared registration cleanup still reports work: %#v %v", empty, err)
	}
}

func TestRegistrationCleanupRemainsContract10Compatible(t *testing.T) {
	document := registrationCleanupDocument{
		SchemaVersion:          1,
		ManagerContractVersion: registrationCleanupDocumentContractVersion,
		TargetKey:              "repo-1234",
		Records:                []registrationCleanupRecord{validRegistrationCleanupRecord()},
	}
	data, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	var legacy contract10CleanupDocument
	if err := json.Unmarshal(data, &legacy); err != nil {
		t.Fatal(err)
	}
	if legacy.ManagerContractVersion != 10 ||
		len(legacy.Records) != 1 ||
		legacy.Records[0].ContainerID == "" {
		t.Fatalf("cleanup state is not contract-10 compatible: %#v", legacy)
	}
}

func TestRegistrationCleanupDocumentRejectsUnusableState(t *testing.T) {
	tests := []struct {
		name string
		data string
	}{
		{name: "malformed", data: "{invalid"},
		{
			name: "unsupported schema",
			data: `{"schemaVersion":2,"managerContractVersion":10,"targetKey":"repo-1234","records":[]}`,
		},
		{
			name: "unsupported contract",
			data: `{"schemaVersion":1,"managerContractVersion":9,"targetKey":"repo-1234","records":[]}`,
		},
		{
			name: "foreign target",
			data: `{"schemaVersion":1,"managerContractVersion":10,"targetKey":"repo-9999","records":[]}`,
		},
		{
			name: "incomplete record",
			data: `{"schemaVersion":1,"managerContractVersion":10,"targetKey":"repo-1234",` +
				`"records":[{"targetKey":"repo-1234","slotKey":"repo-1234-7","runnerId":0}]}`,
		},
		{
			name: "duplicate slot",
			data: `{"schemaVersion":1,"managerContractVersion":10,"targetKey":"repo-1234","records":[` +
				`{"targetKey":"repo-1234","slotKey":"repo-1234-7","runnerId":7,"runnerName":"one","containerId":"container-1"},` +
				`{"targetKey":"repo-1234","slotKey":"repo-1234-7","runnerId":7,"runnerName":"one","containerId":"container-1"}]}`,
		},
		{
			name: "negative attempts",
			data: `{"schemaVersion":1,"managerContractVersion":10,"targetKey":"repo-1234","records":[` +
				`{"targetKey":"repo-1234","slotKey":"repo-1234-7","runnerId":7,"runnerName":"one","attempts":-1}]}`,
		},
		{
			name: "invalid retry timestamp",
			data: `{"schemaVersion":1,"managerContractVersion":10,"targetKey":"repo-1234","records":[` +
				`{"targetKey":"repo-1234","slotKey":"repo-1234-7","runnerId":7,"runnerName":"one","nextAttemptAt":"soon"}]}`,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := parseRegistrationCleanupDocument(
				[]byte(test.data),
				"repo-1234",
			); err == nil {
				t.Fatal("expected unusable registration cleanup state to be rejected")
			}
		})
	}
}

func TestRegistrationCleanupDocumentCapsAttempts(t *testing.T) {
	data := `{"schemaVersion":1,"managerContractVersion":10,"targetKey":"repo-1234","records":[` +
		`{"targetKey":"repo-1234","slotKey":"repo-1234-7","runnerId":7,"runnerName":"one","containerId":"container-1","attempts":2147483647}]}`
	document, err := parseRegistrationCleanupDocument(
		[]byte(data),
		"repo-1234",
	)
	if err != nil {
		t.Fatal(err)
	}
	if document.Records[0].Attempts != maxRegistrationCleanupAttempts {
		t.Fatalf(
			"attempts = %d, want %d",
			document.Records[0].Attempts,
			maxRegistrationCleanupAttempts,
		)
	}
}

func TestRegistrationCleanupPathsAreTargetSpecific(t *testing.T) {
	first := registrationCleanupPath("/var/lib/pitcrew", "repo-1234")
	second := registrationCleanupPath("/var/lib/pitcrew", "repo-5678")
	if first == second {
		t.Fatal("distinct targets shared a registration cleanup state file")
	}
	if !strings.HasSuffix(first, ".json") {
		t.Fatalf("unexpected registration cleanup path: %s", first)
	}
}

func TestRegistrationCleanupRetryHonoursSchedule(t *testing.T) {
	record := validRegistrationCleanupRecord()
	now := time.Date(2026, 7, 20, 12, 0, 10, 0, time.UTC)
	if registrationCleanupDue(record, now) {
		t.Fatal("cleanup retried before its scheduled attempt")
	}
	scheduledAt, err := time.Parse(time.RFC3339, record.NextAttemptAt)
	if err != nil {
		t.Fatal(err)
	}
	if !registrationCleanupDue(record, scheduledAt) {
		t.Fatal("cleanup was not retried after its scheduled attempt")
	}
	record.NextAttemptAt = ""
	if !registrationCleanupDue(record, now) {
		t.Fatal("a record without a schedule was not retried")
	}
}

func TestRegistrationCleanupRetryUsesProgressiveBackoff(t *testing.T) {
	expected := []time.Duration{
		time.Minute,
		2 * time.Minute,
		4 * time.Minute,
		8 * time.Minute,
		15 * time.Minute,
		15 * time.Minute,
	}
	for index, delay := range expected {
		attempts := index + 1
		if actual := registrationOperationRetryDelay(attempts); actual != delay {
			t.Fatalf(
				"attempt %d delay = %s, want %s",
				attempts,
				actual,
				delay,
			)
		}
	}
}
