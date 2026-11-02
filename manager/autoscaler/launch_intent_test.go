package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type failSecondLaunchIntentSaveStore struct {
	record    launchIntentRecord
	exists    bool
	saveCalls int
}

func (s *failSecondLaunchIntentSaveStore) load() (
	launchIntentRecord,
	bool,
	error,
) {
	return s.record, s.exists, nil
}

func (s *failSecondLaunchIntentSaveStore) save(
	record launchIntentRecord,
) error {
	s.saveCalls++
	if s.saveCalls == 2 {
		return errors.New("second launch intent save failed")
	}
	s.record = record
	s.exists = true
	return nil
}

func (s *failSecondLaunchIntentSaveStore) clear() error {
	s.record = launchIntentRecord{}
	s.exists = false
	return nil
}

func TestLaunchIntentStoreRoundTripsAndClears(t *testing.T) {
	directory := projectTestDirectory(t)
	store := newLaunchIntentStore(directory, "repo-1234")
	expected := launchIntentRecord{
		SchemaVersion:          1,
		ManagerContractVersion: launchIntentContractVersion,
		TargetKey:              "repo-1234",
		RunnerName:             "runner-one",
		RunnerID:               7,
		Attempts:               1,
		LastAttemptAt:          "2026-07-20T12:00:00Z",
		NextAttemptAt:          "2026-07-20T12:01:00Z",
	}
	if err := store.save(expected); err != nil {
		t.Fatal(err)
	}
	actual, exists, err := store.load()
	if err != nil || !exists || actual != expected {
		t.Fatalf("launch intent did not round trip: %#v %t %v", actual, exists, err)
	}
	if err := store.clear(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(
		launchIntentPath(directory, expected.TargetKey),
	); !os.IsNotExist(err) {
		t.Fatalf("cleared launch intent still exists: %v", err)
	}
}

func TestLaunchIntentDeadlineSurvivesManagerRestart(t *testing.T) {
	directory := projectTestDirectory(t)
	scaler, api, _, _, cancel := newTestScalerInDirectory(
		t,
		1,
		0,
		0,
		directory,
	)
	api.generateErrors = []error{errors.New("JIT unavailable")}
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err == nil {
		t.Fatal("expected JIT failure")
	}
	cancel()

	restarted, restartedAPI, _, restartedClock, restartedCancel :=
		newTestScalerInDirectory(t, 1, 0, 0, directory)
	defer restartedCancel()
	if _, err := restarted.HandleDesiredRunnerCount(
		context.Background(),
		1,
	); err != nil {
		t.Fatal(err)
	}
	if restartedAPI.jitCalls != 0 {
		t.Fatal("manager restart bypassed launch intent deadline")
	}
	restartedClock.advance(registrationOperationRetryDelay(1))
	if err := restarted.tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if restartedAPI.jitCalls != 1 || restarted.runnerCount() != 1 {
		t.Fatalf(
			"launch intent did not recover demand: jit=%d runners=%d",
			restartedAPI.jitCalls,
			restarted.runnerCount(),
		)
	}
}

func TestCorruptLaunchIntentBlocksJIT(t *testing.T) {
	directory := projectTestDirectory(t)
	path := launchIntentPath(directory, "repo-1234")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("{invalid"), 0o600); err != nil {
		t.Fatal(err)
	}
	scaler, api, _, _, cancel := newTestScalerInDirectory(
		t,
		1,
		0,
		0,
		directory,
	)
	defer cancel()
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err == nil {
		t.Fatal("corrupt launch intent did not fail closed")
	}
	if api.jitCalls != 0 {
		t.Fatal("corrupt launch intent admitted JIT generation")
	}
}

func TestLaunchIntentSecondSaveFailureRemainsRecoverable(t *testing.T) {
	scaler, api, _, clock, cancel := newTestScaler(t, 1, 0, 0)
	defer cancel()
	store := &failSecondLaunchIntentSaveStore{}
	scaler.launchIntentStore = store
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err == nil {
		t.Fatal("expected runner ID persistence failure")
	}
	if api.jitCalls != 1 || !store.exists || store.record.RunnerName == "" {
		t.Fatalf(
			"first launch intent was not retained: jit=%d record=%#v",
			api.jitCalls,
			store.record,
		)
	}

	restarted, _, _, restartedClock, restartedCancel := newTestScaler(
		t,
		1,
		0,
		0,
	)
	defer restartedCancel()
	restarted.api = api
	restarted.launchIntentStore = store
	restarted.pendingLaunchIntent = nil
	restarted.launchIntentStateError = nil
	restarted.restoreLaunchIntent()
	restartedClock.current = clock.now()
	if _, err := restarted.HandleDesiredRunnerCount(
		context.Background(),
		1,
	); err != nil {
		t.Fatal(err)
	}
	if api.findRunnerCalls[store.record.RunnerName] != 0 {
		t.Fatal("restart bypassed the retained launch deadline")
	}
	restartedClock.advance(registrationOperationRetryDelay(1))
	if err := restarted.tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if store.exists {
		t.Fatal("recovered launch intent was not cleared")
	}
}
