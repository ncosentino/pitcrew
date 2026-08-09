package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

func validHostLeaseCleanupRecord() hostLeaseCleanupRecord {
	return hostLeaseCleanupRecord{
		TargetKey:     "repo-1234",
		RunnerKey:     "repo-1234-7",
		HostSlotKey:   "pitcrew-runner-repo-1234-suffix01",
		Attempts:      1,
		FirstFailedAt: "2026-07-20T12:00:00Z",
		LastAttemptAt: "2026-07-20T12:00:00Z",
		NextAttemptAt: "2026-07-20T12:00:15Z",
	}
}

func TestHostLeaseCleanupStoreRoundTripsAndClears(t *testing.T) {
	directory := projectTestDirectory(t)
	store := newHostLeaseCleanupStore(directory, "repo-1234")
	record := validHostLeaseCleanupRecord()
	if err := store.save([]hostLeaseCleanupRecord{record}); err != nil {
		t.Fatalf("save host lease cleanup: %v", err)
	}
	data, err := os.ReadFile(hostLeaseCleanupPath(directory, "repo-1234"))
	if err != nil {
		t.Fatalf("read host lease cleanup: %v", err)
	}
	document, err := parseHostLeaseCleanupDocument(data, "repo-1234")
	if err != nil ||
		document.ManagerContractVersion != hostLeaseCleanupDocumentContractVersion {
		t.Fatalf("host lease cleanup used an unexpected format: %#v %v", document, err)
	}
	restored, err := store.load()
	if err != nil {
		t.Fatalf("load host lease cleanup: %v", err)
	}
	if len(restored) != 1 || restored[0] != record {
		t.Fatalf("host lease cleanup did not round trip: %#v", restored)
	}
	if err := store.save(nil); err != nil {
		t.Fatalf("clear host lease cleanup: %v", err)
	}
	if _, err := os.Stat(hostLeaseCleanupPath(directory, "repo-1234")); !os.IsNotExist(err) {
		t.Fatalf("cleared host lease cleanup left state behind: %v", err)
	}
	empty, err := store.load()
	if err != nil || len(empty) != 0 {
		t.Fatalf("cleared host lease cleanup still reports work: %#v %v", empty, err)
	}
}

func TestHostLeaseCleanupDocumentRejectsUnusableState(t *testing.T) {
	tests := []struct {
		name string
		data string
	}{
		{name: "malformed", data: "{invalid"},
		{
			name: "unsupported schema",
			data: `{"schemaVersion":2,"managerContractVersion":17,"targetKey":"repo-1234","records":[]}`,
		},
		{
			name: "unsupported contract",
			data: `{"schemaVersion":1,"managerContractVersion":16,"targetKey":"repo-1234","records":[]}`,
		},
		{
			name: "foreign target",
			data: `{"schemaVersion":1,"managerContractVersion":17,"targetKey":"repo-9999","records":[]}`,
		},
		{
			name: "incomplete record",
			data: `{"schemaVersion":1,"managerContractVersion":17,"targetKey":"repo-1234",` +
				`"records":[{"targetKey":"repo-1234","runnerKey":"repo-1234-7"}]}`,
		},
		{
			name: "duplicate slot",
			data: `{"schemaVersion":1,"managerContractVersion":17,"targetKey":"repo-1234","records":[` +
				`{"targetKey":"repo-1234","runnerKey":"repo-1234-7","hostSlotKey":"slot-a"},` +
				`{"targetKey":"repo-1234","runnerKey":"repo-1234-7","hostSlotKey":"slot-a"}]}`,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := parseHostLeaseCleanupDocument(
				[]byte(test.data),
				"repo-1234",
			); err == nil {
				t.Fatal("expected unusable host lease cleanup state to be rejected")
			}
		})
	}
}

// TestHostLeaseCleanupDocumentNeverCarriesPrivateEvidence proves the
// persisted document contains only the exact identity and retry metadata
// needed to release one lease, never JIT configuration, credentials, or job
// output.
func TestHostLeaseCleanupDocumentNeverCarriesPrivateEvidence(t *testing.T) {
	directory := projectTestDirectory(t)
	store := newHostLeaseCleanupStore(directory, "repo-1234")
	record := validHostLeaseCleanupRecord()
	if err := store.save([]hostLeaseCleanupRecord{record}); err != nil {
		t.Fatalf("save host lease cleanup: %v", err)
	}
	data, err := os.ReadFile(hostLeaseCleanupPath(directory, "repo-1234"))
	if err != nil {
		t.Fatalf("read host lease cleanup: %v", err)
	}
	for _, forbidden := range []string{"jit-secret", "credential", "jobOutput"} {
		if strings.Contains(string(data), forbidden) {
			t.Fatalf("persisted host lease cleanup leaked private evidence: %q in %s", forbidden, data)
		}
	}
}

func TestHostLeaseCleanupPathsAreTargetSpecific(t *testing.T) {
	first := hostLeaseCleanupPath("/var/lib/pitcrew", "repo-1234")
	second := hostLeaseCleanupPath("/var/lib/pitcrew", "repo-5678")
	if first == second {
		t.Fatal("distinct targets shared a host lease cleanup state file")
	}
	if !strings.HasSuffix(first, ".json") {
		t.Fatalf("unexpected host lease cleanup path: %s", first)
	}
}

func TestHostLeaseCleanupRetryHonoursSchedule(t *testing.T) {
	record := validHostLeaseCleanupRecord()
	now := time.Date(2026, 7, 20, 12, 0, 10, 0, time.UTC)
	if hostLeaseReleaseDue(record, now) {
		t.Fatal("release retried before its scheduled attempt")
	}
	if !hostLeaseReleaseDue(record, now.Add(hostLeaseReleaseRetryDelay)) {
		t.Fatal("release was not retried after its scheduled attempt")
	}
	record.NextAttemptAt = ""
	if !hostLeaseReleaseDue(record, now) {
		t.Fatal("a record without a schedule was not retried")
	}
}

func TestHostLeaseCleanupBoundLimitsBacklogSize(t *testing.T) {
	records := make([]hostLeaseCleanupRecord, 0, maxPendingHostLeaseReleases+5)
	for index := 0; index < maxPendingHostLeaseReleases+5; index++ {
		record := validHostLeaseCleanupRecord()
		record.HostSlotKey = record.HostSlotKey + "-" + time.Now().Add(time.Duration(index)*time.Second).Format(time.RFC3339Nano)
		records = append(records, record)
	}
	if _, err := parseHostLeaseCleanupDocument(
		[]byte(mustMarshalHostLeaseCleanupDocument(t, "repo-1234", records)),
		"repo-1234",
	); err == nil {
		t.Fatal("expected an over-bound host lease cleanup document to be rejected")
	}
}

func mustMarshalHostLeaseCleanupDocument(
	t *testing.T,
	targetKey string,
	records []hostLeaseCleanupRecord,
) string {
	t.Helper()
	document := hostLeaseCleanupDocument{
		SchemaVersion:          1,
		ManagerContractVersion: hostLeaseCleanupDocumentContractVersion,
		TargetKey:              targetKey,
		Records:                records,
	}
	data, err := json.Marshal(document)
	if err != nil {
		t.Fatalf("marshal host lease cleanup document: %v", err)
	}
	return string(data)
}
