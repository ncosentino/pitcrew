package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

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
		NextAttemptAt: "2026-07-20T12:00:15Z",
	}
}

func TestRegistrationCleanupStoreRoundTripsAndClears(t *testing.T) {
	directory := projectTestDirectory(t)
	store := newRegistrationCleanupStore(directory, "repo-1234")
	record := validRegistrationCleanupRecord()
	if err := store.save([]registrationCleanupRecord{record}); err != nil {
		t.Fatalf("save registration cleanup: %v", err)
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
	if !registrationCleanupDue(record, now.Add(registrationCleanupRetryDelay)) {
		t.Fatal("cleanup was not retried after its scheduled attempt")
	}
	record.NextAttemptAt = ""
	if !registrationCleanupDue(record, now) {
		t.Fatal("a record without a schedule was not retried")
	}
}
