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
	for source, expected := range sources {
		data, err := os.ReadFile(
			filepath.Join(paths.supportEvidence, filepath.Base(source)),
		)
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
