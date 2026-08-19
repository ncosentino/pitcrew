package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestPublishSupportEvidenceSnapshotCopiesOnlyAllowlistedState(t *testing.T) {
	paths := newStatePaths(t.TempDir())
	sources := map[string]string{
		paths.desired:         "desired\n",
		paths.acknowledgement: "acknowledged\n",
		paths.static:          "static\n",
		paths.observed:        "observed\n",
	}
	for path, content := range sources {
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	if err := os.WriteFile(paths.lastValid, []byte("private\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := publishSupportEvidenceSnapshot(paths); err != nil {
		t.Fatal(err)
	}
	evidenceInfo, err := os.Stat(paths.supportEvidence)
	if err != nil {
		t.Fatal(err)
	}
	if evidenceInfo.Mode().Perm() != 0o700 {
		t.Fatalf(
			"support evidence directory mode = %04o, want 0700",
			evidenceInfo.Mode().Perm(),
		)
	}
	for source, expected := range sources {
		destination := filepath.Join(
			paths.supportEvidence,
			filepath.Base(source),
		)
		data, err := os.ReadFile(destination)
		if err != nil {
			t.Fatal(err)
		}
		if string(data) != expected {
			t.Fatalf(
				"support evidence %s = %q, want %q",
				filepath.Base(source),
				data,
				expected,
			)
		}
		info, err := os.Stat(destination)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o640 {
			t.Fatalf(
				"support evidence %s mode = %04o, want 0640",
				filepath.Base(source),
				info.Mode().Perm(),
			)
		}
	}
	if _, err := os.Stat(
		filepath.Join(paths.supportEvidence, filepath.Base(paths.lastValid)),
	); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("non-allowlisted state was mirrored: %v", err)
	}

	if err := os.WriteFile(paths.observed, []byte("replacement\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(paths.desired); err != nil {
		t.Fatal(err)
	}
	if err := publishSupportEvidenceSnapshot(paths); err != nil {
		t.Fatal(err)
	}
	observed, err := os.ReadFile(
		filepath.Join(paths.supportEvidence, filepath.Base(paths.observed)),
	)
	if err != nil {
		t.Fatal(err)
	}
	if string(observed) != "replacement\n" {
		t.Fatalf("replacement evidence = %q", observed)
	}
	if _, err := os.Stat(
		filepath.Join(paths.supportEvidence, filepath.Base(paths.desired)),
	); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale support evidence was retained: %v", err)
	}
}

func TestPublishSupportEvidenceSnapshotRejectsNonRegularSource(t *testing.T) {
	paths := newStatePaths(t.TempDir())
	if err := os.WriteFile(paths.desired, []byte("desired\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := publishSupportEvidenceSnapshot(paths); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(paths.desired); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(paths.desired, 0o755); err != nil {
		t.Fatal(err)
	}

	err := publishSupportEvidenceSnapshot(paths)
	if err == nil {
		t.Fatal("non-regular support evidence source was accepted")
	}
	if _, err := os.Stat(
		filepath.Join(paths.supportEvidence, filepath.Base(paths.desired)),
	); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale support evidence survived an invalid source: %v", err)
	}
}
