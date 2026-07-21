package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestLoadConfigDefaultsAndValidation(t *testing.T) {
	values := map[string]string{
		"ACCESS_TOKEN":             "pat-value",
		"RUNNER_PROFILE_ID":        "profile-a",
		"RUNNER_IMAGE":             "example/runner:latest",
		"PITCREW_WORKER_REVISION":  testWorkerRevision,
		"PITCREW_SESSION_OWNER":    "pitcrew-profile-a",
		"RUNNER_SCOPE":             "repo",
		"RUNNER_NAME_PREFIX":       "runner",
		"RUNNER_LABELS":            "copilot, specialized",
		"RUNNER_GROUP":             "",
		"RUNNER_NO_DEFAULT_LABELS": "1",
	}
	lookup := func(name string) (string, bool) {
		value, exists := values[name]
		return value, exists
	}
	cfg, err := loadConfig(lookup, "amd64")
	if err != nil {
		t.Fatalf("loadConfig returned an error: %v", err)
	}
	if cfg.runnerGroup != "default" {
		t.Fatalf("expected default runner group, got %q", cfg.runnerGroup)
	}
	if cfg.stateDirectory != filepath.Clean("/var/lib/pitcrew") {
		t.Fatalf("unexpected state directory %q", cfg.stateDirectory)
	}
	if cfg.minimumIdle != 0 || cfg.scaleDownDelay != 120*time.Second {
		t.Fatalf("unexpected autoscaling defaults: min=%d delay=%s", cfg.minimumIdle, cfg.scaleDownDelay)
	}
	if cfg.observedInterval != 30*time.Second || cfg.architectureLabel != "x64" {
		t.Fatalf("unexpected observation or architecture defaults")
	}
	if !cfg.noDefaultLabels {
		t.Fatal("expected RUNNER_NO_DEFAULT_LABELS=1 to be enabled")
	}
}

func TestLoadConfigRejectsInvalidValues(t *testing.T) {
	base := map[string]string{
		"ACCESS_TOKEN":            "pat-value",
		"RUNNER_PROFILE_ID":       "profile-a",
		"RUNNER_IMAGE":            "example/runner:latest",
		"PITCREW_WORKER_REVISION": testWorkerRevision,
		"PITCREW_SESSION_OWNER":   "pitcrew-profile-a",
		"RUNNER_SCOPE":            "repo",
		"RUNNER_NAME_PREFIX":      "runner",
	}
	tests := []struct {
		name   string
		key    string
		value  string
		remove string
	}{
		{name: "missing token", remove: "ACCESS_TOKEN"},
		{name: "unsupported scope", key: "RUNNER_SCOPE", value: "account"},
		{name: "negative minimum idle", key: "PITCREW_AUTOSCALING_MIN_IDLE", value: "-1"},
		{name: "invalid scale down delay", key: "PITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS", value: "soon"},
		{name: "scale down delay below minimum", key: "PITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS", value: "29"},
		{name: "scale down delay above maximum", key: "PITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS", value: "3601"},
		{name: "contract mismatch", key: "PITCREW_MANAGER_CONTRACT_VERSION", value: "7"},
		{name: "invalid worker revision", key: "PITCREW_WORKER_REVISION", value: "not-a-digest"},
		{name: "invalid session owner", key: "PITCREW_SESSION_OWNER", value: "bad owner"},
		{name: "invalid no-default flag", key: "RUNNER_NO_DEFAULT_LABELS", value: "true"},
		{name: "empty custom label", key: "RUNNER_LABELS", value: "one,,two"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			values := make(map[string]string, len(base)+1)
			for key, value := range base {
				values[key] = value
			}
			if test.remove != "" {
				delete(values, test.remove)
			}
			if test.key != "" {
				values[test.key] = test.value
			}
			_, err := loadConfig(func(name string) (string, bool) {
				value, exists := values[name]
				return value, exists
			}, "amd64")
			if err == nil {
				t.Fatal("expected configuration validation to fail")
			}
		})
	}
}

func TestLoadConfigAcceptsScaleDownDelayBounds(t *testing.T) {
	for _, seconds := range []int{30, 3600} {
		t.Run(strconv.Itoa(seconds), func(t *testing.T) {
			values := map[string]string{
				"ACCESS_TOKEN":            "pat-value",
				"RUNNER_PROFILE_ID":       "profile-a",
				"RUNNER_IMAGE":            "example/runner:latest",
				"PITCREW_WORKER_REVISION": testWorkerRevision,
				"PITCREW_SESSION_OWNER":   "pitcrew-profile-a",
				"RUNNER_SCOPE":            "repo",
				"RUNNER_NAME_PREFIX":      "runner",
				"PITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS": strconv.Itoa(seconds),
			}
			cfg, err := loadConfig(func(name string) (string, bool) {
				value, exists := values[name]
				return value, exists
			}, "amd64")
			if err != nil {
				t.Fatalf("expected boundary %d to be valid: %v", seconds, err)
			}
			if cfg.scaleDownDelay != time.Duration(seconds)*time.Second {
				t.Fatalf("unexpected scale-down delay %s", cfg.scaleDownDelay)
			}
		})
	}
}

func TestDesiredStateClassification(t *testing.T) {
	currentDocument := []byte(`{
	  "schemaVersion": 1,
	  "generation": 2,
	  "scope": "repo",
	  "repositories": [{"url": "https://github.com/example/repo", "workers": 2}],
	  "replicas": null
	}`)
	current, err := parseDesiredState(currentDocument, "repo")
	if err != nil {
		t.Fatalf("parse current desired state: %v", err)
	}
	const expectedHash = "8508318c9fd3a88fdc3beef9f95a7922b90da31448bc9cfcd0a048b863fe5c26"
	if current.stateHash != expectedHash {
		t.Fatalf("desired-state hash is incompatible: got %s", current.stateHash)
	}
	tests := []struct {
		name     string
		document string
		expected desiredClassification
	}{
		{name: "unchanged", document: string(currentDocument), expected: classificationUnchanged},
		{name: "new", document: strings.Replace(string(currentDocument), `"generation": 2`, `"generation": 3`, 1), expected: classificationNew},
		{name: "stale", document: strings.Replace(string(currentDocument), `"generation": 2`, `"generation": 1`, 1), expected: classificationStale},
		{name: "conflict", document: strings.Replace(string(currentDocument), `"workers": 2`, `"workers": 3`, 1), expected: classificationConflict},
		{name: "invalid", document: `{"schemaVersion":1,"generation":3,"scope":"repo","repositories":[],"replicas":null}`, expected: classificationInvalid},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			classification, _, _ := classifyDesiredState(
				[]byte(test.document),
				"repo",
				current.state.Generation,
				current.stateHash,
			)
			if classification != test.expected {
				t.Fatalf("expected %q, got %q", test.expected, classification)
			}
		})
	}
}

func TestDesiredStateAcceptsIntegralJSONNumbersAndRejectsConflicts(t *testing.T) {
	document := []byte(`{
	  "schemaVersion": 1.0,
	  "generation": 4e0,
	  "scope": "repo",
	  "repositories": [{"url": "https://github.com/example/repo", "workers": 2.0}],
	  "replicas": null
	}`)
	parsed, err := parseDesiredState(document, "repo")
	if err != nil {
		t.Fatalf("expected integral JSON numbers to be accepted: %v", err)
	}
	if parsed.state.Generation != 4 || parsed.state.Repositories[0].Workers != 2 {
		t.Fatalf("integral JSON numbers were not normalized")
	}

	duplicate := []byte(`{
	  "schemaVersion": 1,
	  "generation": 5,
	  "scope": "repo",
	  "repositories": [
	    {"url": "https://github.com/example/repo", "workers": 1},
	    {"url": "https://github.com/example/repo", "workers": 1}
	  ],
	  "replicas": null
	}`)
	if _, err := parseDesiredState(duplicate, "repo"); err == nil {
		t.Fatal("expected duplicate repository targets to be rejected")
	}
	if _, err := parseDesiredState(document, "org"); err == nil {
		t.Fatal("expected configured scope conflict to be rejected")
	}
}

func TestRepositoryDesiredStateCanonicalizesRegistrationURLs(t *testing.T) {
	variant := []byte(`{
	  "schemaVersion":1,
	  "generation":7,
	  "scope":"repo",
	  "repositories":[
	    {"url":"HTTPS://GitHub.COM:443/Example/Repo.GIT/","workers":2}
	  ],
	  "replicas":null
	}`)
	parsed, err := parseDesiredState(variant, "repo")
	if err != nil {
		t.Fatal(err)
	}
	const canonicalURL = "https://github.com/Example/Repo"
	if parsed.state.Repositories[0].URL != canonicalURL {
		t.Fatalf(
			"repository URL was not canonicalized: %q",
			parsed.state.Repositories[0].URL,
		)
	}
	httpURL, err := canonicalRepositoryURL(
		"http://GitHub.COM:80/Example/Repo.git/",
	)
	if err != nil {
		t.Fatal(err)
	}
	if httpURL != "http://github.com/Example/Repo" {
		t.Fatalf("HTTP repository URL was not canonicalized: %q", httpURL)
	}
	canonical, err := parseDesiredState([]byte(`{
	  "schemaVersion":1,
	  "generation":7,
	  "scope":"repo",
	  "repositories":[
	    {"url":"https://github.com/Example/Repo","workers":2}
	  ],
	  "replicas":null
	}`), "repo")
	if err != nil {
		t.Fatal(err)
	}
	if parsed.stateHash != canonical.stateHash {
		t.Fatal("canonical URL variants produced conflicting desired-state hashes")
	}
	targets, err := buildTargetSpecs(parsed.state, config{
		profileID:  "profile-a",
		namePrefix: "runner",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(targets) != 1 ||
		targets[0].registrationURL != canonicalURL ||
		targets[0].repository != canonicalURL {
		t.Fatalf("scale-set target did not receive the canonical URL: %#v", targets)
	}

	duplicate := []byte(`{
	  "schemaVersion":1,
	  "generation":8,
	  "scope":"repo",
	  "repositories":[
	    {"url":"https://github.com/Example/Repo","workers":1},
	    {"url":"https://github.com/Example/Repo.git/","workers":1}
	  ],
	  "replicas":null
	}`)
	if _, err := parseDesiredState(duplicate, "repo"); err == nil {
		t.Fatal("duplicate canonical repository URLs were accepted")
	}
	if _, err := buildTargetSpecs(desiredState{
		Scope: "repo",
		Repositories: []desiredRepository{
			{URL: "https://github.com/Example/Repo/", Workers: 1},
			{URL: "https://github.com/Example/Repo.git", Workers: 1},
		},
	}, config{}); err == nil {
		t.Fatal("target construction accepted duplicate canonical repository URLs")
	}
}

func TestAcknowledgementJSONUsesConfiguredMaximum(t *testing.T) {
	previous, err := parseDesiredState([]byte(`{
	  "schemaVersion":1,
	  "generation":1,
	  "scope":"repo",
	  "repositories":[{"url":"https://github.com/example/repo","workers":1}],
	  "replicas":null
	}`), "repo")
	if err != nil {
		t.Fatal(err)
	}
	current, err := parseDesiredState([]byte(`{
	  "schemaVersion":1,
	  "generation":2,
	  "scope":"repo",
	  "repositories":[{"url":"https://github.com/example/repo","workers":3}],
	  "replicas":null
	}`), "repo")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	ack := buildAcknowledgement(current, previous.state, 2, 1, now)
	if ack.DesiredSlots != 3 || ack.ActiveSlots != 2 {
		t.Fatalf("unexpected desired/active slots: %#v", ack)
	}
	if ack.ActivationMode != "autoscaled" || ack.MinimumIdleSlots != 1 {
		t.Fatalf("missing autoscaling acknowledgement fields: %#v", ack)
	}
	if ack.AddedSlots != 2 || ack.UnchangedSlots != 1 || ack.DrainingSlots != 0 {
		t.Fatalf("unexpected compatibility diff: %#v", ack)
	}

	path := filepath.Join(projectTestDirectory(t), "acknowledged-capacity.json")
	if err := writeJSONAtomically(path, ack); err != nil {
		t.Fatalf("write acknowledgement: %v", err)
	}
	ack.ActiveSlots = 3
	if err := writeJSONAtomically(path, ack); err != nil {
		t.Fatalf("replace acknowledgement atomically: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded["activeSlots"] != float64(3) {
		t.Fatalf("atomic replacement did not publish the latest acknowledgement: %#v", decoded)
	}
	for _, field := range []string{
		"schemaVersion", "status", "generation", "managerContractVersion",
		"desiredStateHash", "observedAt", "desiredSlots", "addedSlots",
		"drainingSlots", "unchangedSlots", "addedKeys", "drainingKeys",
		"unchangedKeys", "activationMode", "activeSlots", "minimumIdleSlots",
	} {
		if _, exists := decoded[field]; !exists {
			t.Fatalf("acknowledgement omitted field %q", field)
		}
	}
}

func TestEffectiveLabelsAndScaleSetNames(t *testing.T) {
	cfg := config{
		profileID:         "Copilot Profile",
		namePrefix:        "worker",
		labels:            []string{"copilot", "linux"},
		architectureLabel: "x64",
	}
	if labels := effectiveLabels(cfg); !reflect.DeepEqual(
		labels,
		[]string{"copilot", "linux", "x64", "self-hosted"},
	) {
		t.Fatalf("unexpected effective labels: %#v", labels)
	}
	cfg.noDefaultLabels = true
	if labels := effectiveLabels(cfg); !reflect.DeepEqual(
		labels,
		[]string{"copilot", "linux", "x64"},
	) {
		t.Fatalf("unexpected no-default labels: %#v", labels)
	}

	first := stableScaleSetName(
		cfg.profileID,
		cfg.namePrefix,
		"https://github.com/example/repo",
	)
	second := stableScaleSetName(
		cfg.profileID,
		cfg.namePrefix,
		"https://github.com/example/repo",
	)
	changed := stableScaleSetName(
		cfg.profileID,
		"other-prefix",
		"https://github.com/example/repo",
	)
	if first != second || first == changed {
		t.Fatalf("scale-set name is not stable or does not include the required hash")
	}
	if !strings.Contains(first, "copilot-profile") {
		t.Fatalf("scale-set name does not contain profile identity: %q", first)
	}
}
