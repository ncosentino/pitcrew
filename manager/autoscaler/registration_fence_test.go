package main

import (
	"os"
	"testing"
)

func validRegistrationFenceRecord() registrationFenceRecord {
	return registrationFenceRecord{
		TargetKey:     "repo-1234",
		SlotKey:       "repo-1234-7",
		Purpose:       registrationFenceStale,
		RunnerID:      7,
		RunnerName:    "runner-seven",
		ContainerID:   "container-seven",
		ContainerName: "runner-seven",
		Attempts:      1,
		FirstFailedAt: "2026-07-20T12:00:00Z",
		LastAttemptAt: "2026-07-20T12:00:00Z",
		NextAttemptAt: "2026-07-20T12:01:00Z",
	}
}

func TestRegistrationFenceStoreIsSeparateAndRoundTrips(t *testing.T) {
	directory := projectTestDirectory(t)
	fenceStore := newRegistrationFenceStore(directory, "repo-1234")
	record := validRegistrationFenceRecord()
	if err := fenceStore.save([]registrationFenceRecord{record}); err != nil {
		t.Fatal(err)
	}
	restored, err := fenceStore.load()
	if err != nil || len(restored) != 1 || restored[0] != record {
		t.Fatalf("registration fence did not round trip: %#v %v", restored, err)
	}
	if registrationFencePath(directory, "repo-1234") ==
		registrationCleanupPath(directory, "repo-1234") {
		t.Fatal("live fences share rollback-compatible cleanup state")
	}
	cleanupRecords, err := newRegistrationCleanupStore(
		directory,
		"repo-1234",
	).load()
	if err != nil || len(cleanupRecords) != 0 {
		t.Fatalf(
			"cleanup reader consumed live-fence state: %#v %v",
			cleanupRecords,
			err,
		)
	}
	if err := fenceStore.save(nil); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(
		registrationFencePath(directory, "repo-1234"),
	); !os.IsNotExist(err) {
		t.Fatalf("cleared registration fence still exists: %v", err)
	}
}

func TestRegistrationFenceDocumentRejectsInvalidInput(t *testing.T) {
	tests := []string{
		`{"schemaVersion":2,"managerContractVersion":22,"targetKey":"repo-1234","records":[]}`,
		`{"schemaVersion":1,"managerContractVersion":21,"targetKey":"repo-1234","records":[]}`,
		`{"schemaVersion":1,"managerContractVersion":22,"targetKey":"repo-other","records":[]}`,
		`{"schemaVersion":1,"managerContractVersion":22,"targetKey":"repo-1234","records":[{"targetKey":"repo-1234","slotKey":"slot","purpose":"unknown","runnerId":7,"runnerName":"runner","containerId":"container"}]}`,
		`{"schemaVersion":1,"managerContractVersion":22,"targetKey":"repo-1234","records":[{"targetKey":"repo-1234","slotKey":"slot","purpose":"stale","runnerId":7,"runnerName":"runner","containerId":"container","attempts":-1}]}`,
		`{"schemaVersion":1,"managerContractVersion":22,"targetKey":"repo-1234","records":[{"targetKey":"repo-1234","slotKey":"slot","purpose":"stale","runnerId":7,"runnerName":"runner","containerId":"container","nextAttemptAt":"soon"}]}`,
	}
	for _, data := range tests {
		if _, err := parseRegistrationFenceDocument(
			[]byte(data),
			"repo-1234",
		); err == nil {
			t.Fatalf("invalid registration fence was accepted: %s", data)
		}
	}
}
