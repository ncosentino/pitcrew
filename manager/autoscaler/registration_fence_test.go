package main

import (
	"os"
	"sync"
	"testing"
	"time"
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

func TestRegistrationFenceWritesSerializeMapAndSnapshot(t *testing.T) {
		scaler, _, _, _, cancel := newTestScaler(t, 2, 0, 0)
		defer cancel()
		releaseFirst := make(chan struct{})
		store := &blockingRegistrationFenceStore{
			firstStarted: make(chan struct{}),
			releaseFirst: releaseFirst,
			secondSaved:  make(chan struct{}),
		}
		scaler.fenceStore = store
		runners := []runnerRecord{
			{
				key:         "repo-1234-1",
				targetKey:   "repo-1234",
				runnerName:  "runner-one",
				runnerID:    1,
				containerID: "container-one",
				container:   "runner-one",
			},
			{
				key:         "repo-1234-2",
				targetKey:   "repo-1234",
				runnerName:  "runner-two",
				runnerID:    2,
				containerID: "container-two",
				container:   "runner-two",
			},
		}
		var wait sync.WaitGroup
		wait.Add(2)
		go func() {
			defer wait.Done()
			if _, err := scaler.beginPendingRegistrationFence(
				runners[0],
				registrationFenceShutdown,
				scaler.clock.now().UTC(),
			); err != nil {
				t.Errorf("persist registration fence: %v", err)
			}
		}()
		<-store.firstStarted
		secondCalling := make(chan struct{})
		go func() {
			defer wait.Done()
			close(secondCalling)
			if _, err := scaler.beginPendingRegistrationFence(
				runners[1],
				registrationFenceShutdown,
				scaler.clock.now().UTC(),
			); err != nil {
				t.Errorf("persist second registration fence: %v", err)
			}
		}()
		<-secondCalling
		select {
		case <-store.secondSaved:
			t.Fatal("second fence snapshot wrote while the first transaction was incomplete")
		case <-time.After(50 * time.Millisecond):
		}
		close(releaseFirst)
		wait.Wait()
		records, err := store.load()
		if err != nil || len(records) != 2 {
			t.Fatalf("serialized fence writes lost an identity: %#v %v", records, err)
	}
}
