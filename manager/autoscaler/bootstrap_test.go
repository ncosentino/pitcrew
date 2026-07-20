package main

import (
	"os"
	"testing"
)

func TestBootstrapLegacyRepositoryCapacity(t *testing.T) {
	directory := projectTestDirectory(t)
	paths := newStatePaths(directory)
	cfg := config{
		scope:                "repo",
		legacyRepositoryURLs: " https://github.com/example/one=2,https://github.com/example/two ",
		legacyRepositoryURL:  "https://github.com/example/ignored=9",
	}

	created, err := bootstrapLegacyDesiredState(cfg, paths)
	if err != nil {
		t.Fatal(err)
	}
	if !created {
		t.Fatal("expected repository capacity to be bootstrapped")
	}
	data, err := os.ReadFile(paths.desired)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := parseDesiredState(data, "repo")
	if err != nil {
		t.Fatal(err)
	}
	if parsed.state.Generation != 1 ||
		len(parsed.state.Repositories) != 2 ||
		parsed.state.Repositories[0].URL != "https://github.com/example/one" ||
		parsed.state.Repositories[0].Workers != 2 ||
		parsed.state.Repositories[1].URL != "https://github.com/example/two" ||
		parsed.state.Repositories[1].Workers != 1 {
		t.Fatalf("unexpected bootstrapped repository state: %#v", parsed.state)
	}
}

func TestBootstrapLegacyRepositoryURLFallback(t *testing.T) {
	directory := projectTestDirectory(t)
	paths := newStatePaths(directory)
	created, err := bootstrapLegacyDesiredState(config{
		scope:               "repo",
		legacyRepositoryURL: "https://github.com/example/fallback=3",
	}, paths)
	if err != nil {
		t.Fatal(err)
	}
	if !created {
		t.Fatal("expected REPO_URL fallback capacity to be bootstrapped")
	}
	data, err := os.ReadFile(paths.desired)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := parseDesiredState(data, "repo")
	if err != nil {
		t.Fatal(err)
	}
	if len(parsed.state.Repositories) != 1 ||
		parsed.state.Repositories[0].Workers != 3 {
		t.Fatalf("unexpected fallback repository state: %#v", parsed.state)
	}
}

func TestBootstrapLegacyReplicaCapacity(t *testing.T) {
	for _, test := range []struct {
		name     string
		value    string
		expected int
	}{
		{name: "configured", value: "4", expected: 4},
		{name: "empty defaults to one", value: "", expected: 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			directory := projectTestDirectory(t)
			paths := newStatePaths(directory)
			cfg := config{
				scope:          "org",
				legacyReplicas: test.value,
			}

			created, err := bootstrapLegacyDesiredState(cfg, paths)
			if err != nil {
				t.Fatal(err)
			}
			if !created {
				t.Fatal("expected replica capacity to be bootstrapped")
			}
			data, err := os.ReadFile(paths.desired)
			if err != nil {
				t.Fatal(err)
			}
			parsed, err := parseDesiredState(data, "org")
			if err != nil {
				t.Fatal(err)
			}
			if parsed.state.Replicas == nil ||
				*parsed.state.Replicas != test.expected {
				t.Fatalf("unexpected bootstrapped replica state: %#v", parsed.state)
			}
		})
	}
}

func TestBootstrapLegacyCapacityDoesNotOverwriteState(t *testing.T) {
	for _, existingPath := range []func(statePaths) string{
		func(paths statePaths) string { return paths.desired },
		func(paths statePaths) string { return paths.lastValid },
	} {
		directory := projectTestDirectory(t)
		paths := newStatePaths(directory)
		path := existingPath(paths)
		if err := os.WriteFile(path, []byte("existing"), 0o644); err != nil {
			t.Fatal(err)
		}
		created, err := bootstrapLegacyDesiredState(config{
			scope:               "repo",
			legacyRepositoryURL: "https://github.com/example/repository",
		}, paths)
		if err != nil {
			t.Fatal(err)
		}
		if created {
			t.Fatal("legacy bootstrap overwrote existing manager state")
		}
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if string(data) != "existing" {
			t.Fatalf("existing state changed to %q", data)
		}
	}
}
