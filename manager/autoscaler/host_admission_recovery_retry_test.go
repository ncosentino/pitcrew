package main

import (
	"os"
	"testing"
)

func TestHostAdmissionRecoveryRetryStateRoundTripsAndClears(t *testing.T) {
	directory := projectTestDirectory(t)
	path := newStatePaths(directory).hostRecovery
	expected := hostAdmissionRecoveryRetryState{
		SchemaVersion:          1,
		ManagerContractVersion: managerContractVersion,
		ProfileID:              "profile-a",
		Attempts:               2,
		LastAttemptAt:          "2026-07-20T12:01:00Z",
		NextAttemptAt:          "2026-07-20T12:03:00Z",
	}
	if err := saveHostAdmissionRecoveryRetryState(path, expected); err != nil {
		t.Fatal(err)
	}
	actual, exists, err := loadHostAdmissionRecoveryRetryState(
		path,
		expected.ProfileID,
	)
	if err != nil || !exists || actual != expected {
		t.Fatalf("retry state did not round trip: %#v %t %v", actual, exists, err)
	}
	if err := clearHostAdmissionRecoveryRetryState(path); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("cleared retry state still exists: %v", err)
	}
}

func TestHostAdmissionRecoveryRetryStateRejectsInvalidInput(t *testing.T) {
	tests := []string{
		`{"schemaVersion":2,"managerContractVersion":22,"profileId":"profile-a","attempts":1}`,
		`{"schemaVersion":1,"managerContractVersion":21,"profileId":"profile-a","attempts":1}`,
		`{"schemaVersion":1,"managerContractVersion":22,"profileId":"profile-b","attempts":1}`,
		`{"schemaVersion":1,"managerContractVersion":22,"profileId":"profile-a","attempts":-1}`,
		`{"schemaVersion":1,"managerContractVersion":22,"profileId":"profile-a","attempts":1,"nextAttemptAt":"soon"}`,
	}
	for _, data := range tests {
		directory := projectTestDirectory(t)
		path := newStatePaths(directory).hostRecovery
		if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, _, err := loadHostAdmissionRecoveryRetryState(
			path,
			"profile-a",
		); err == nil {
			t.Fatalf("invalid retry state was accepted: %s", data)
		}
	}
}
