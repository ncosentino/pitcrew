package main

import (
	"errors"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/actions/scaleset"
)

const managerContractVersion = 9

type config struct {
	accessToken          string
	profileID            string
	runnerImage          string
	workerRevision       string
	sessionOwner         string
	assumeUnversioned    bool
	scope                string
	organization         string
	enterprise           string
	namePrefix           string
	labels               []string
	noDefaultLabels      bool
	runnerGroup          string
	stateDirectory       string
	minimumIdle          int
	scaleDownDelay       time.Duration
	observedInterval     time.Duration
	architectureLabel    string
	legacyRepositoryURLs string
	legacyRepositoryURL  string
	legacyReplicas       string
}

func loadConfig(lookup func(string) (string, bool), architecture string) (config, error) {
	value := func(name, fallback string) string {
		if configured, ok := lookup(name); ok {
			return configured
		}
		return fallback
	}

	minimumIdle, err := parseNonnegativeInteger(
		"PITCREW_AUTOSCALING_MIN_IDLE",
		value("PITCREW_AUTOSCALING_MIN_IDLE", "0"),
	)
	if err != nil {
		return config{}, err
	}
	scaleDownSeconds, err := parseNonnegativeInteger(
		"PITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS",
		value("PITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS", "120"),
	)
	if err != nil {
		return config{}, err
	}
	if scaleDownSeconds < 30 || scaleDownSeconds > 3600 {
		return config{}, errors.New(
			"PITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS must be between 30 and 3600",
		)
	}
	scaleDownDelay, err := secondsToDuration(
		"PITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS",
		scaleDownSeconds,
	)
	if err != nil {
		return config{}, err
	}
	observedSeconds, err := parsePositiveInteger(
		"PITCREW_OBSERVED_STATE_INTERVAL",
		value("PITCREW_OBSERVED_STATE_INTERVAL", "30"),
	)
	if err != nil {
		return config{}, err
	}
	observedInterval, err := secondsToDuration(
		"PITCREW_OBSERVED_STATE_INTERVAL",
		observedSeconds,
	)
	if err != nil {
		return config{}, err
	}
	contractVersion, err := parsePositiveInteger(
		"PITCREW_MANAGER_CONTRACT_VERSION",
		value("PITCREW_MANAGER_CONTRACT_VERSION", strconv.Itoa(managerContractVersion)),
	)
	if err != nil {
		return config{}, err
	}
	if contractVersion != managerContractVersion {
		return config{}, fmt.Errorf(
			"PITCREW_MANAGER_CONTRACT_VERSION must be %d, got %d",
			managerContractVersion,
			contractVersion,
		)
	}

	noDefaultLabels, err := parseBooleanFlag(
		"RUNNER_NO_DEFAULT_LABELS",
		value("RUNNER_NO_DEFAULT_LABELS", ""),
	)
	if err != nil {
		return config{}, err
	}
	assumeUnversioned, err := parseBooleanFlag(
		"PITCREW_ASSUME_UNVERSIONED_CURRENT",
		value("PITCREW_ASSUME_UNVERSIONED_CURRENT", "0"),
	)
	if err != nil {
		return config{}, err
	}
	labels, err := parseLabels(value("RUNNER_LABELS", ""))
	if err != nil {
		return config{}, err
	}

	cfg := config{
		accessToken:          strings.TrimSpace(value("ACCESS_TOKEN", "")),
		profileID:            strings.TrimSpace(value("RUNNER_PROFILE_ID", "")),
		runnerImage:          strings.TrimSpace(value("RUNNER_IMAGE", "")),
		workerRevision:       strings.TrimSpace(value("PITCREW_WORKER_REVISION", "")),
		sessionOwner:         strings.TrimSpace(value("PITCREW_SESSION_OWNER", "")),
		assumeUnversioned:    assumeUnversioned,
		scope:                strings.TrimSpace(value("RUNNER_SCOPE", "")),
		organization:         strings.TrimSpace(value("ORG_NAME", "")),
		enterprise:           strings.TrimSpace(value("ENTERPRISE_NAME", "")),
		namePrefix:           strings.TrimSpace(value("RUNNER_NAME_PREFIX", "")),
		labels:               labels,
		noDefaultLabels:      noDefaultLabels,
		runnerGroup:          strings.TrimSpace(value("RUNNER_GROUP", scaleset.DefaultRunnerGroup)),
		stateDirectory:       filepath.Clean(value("PITCREW_STATE_DIRECTORY", "/var/lib/pitcrew")),
		minimumIdle:          minimumIdle,
		scaleDownDelay:       scaleDownDelay,
		observedInterval:     observedInterval,
		architectureLabel:    normalizeArchitecture(architecture),
		legacyRepositoryURLs: value("REPO_URLS", ""),
		legacyRepositoryURL:  value("REPO_URL", ""),
		legacyReplicas:       value("RUNNER_REPLICAS", "1"),
	}
	if cfg.runnerGroup == "" {
		cfg.runnerGroup = scaleset.DefaultRunnerGroup
	}
	if err := cfg.validate(); err != nil {
		return config{}, err
	}
	return cfg, nil
}

func (c config) validate() error {
	switch {
	case c.accessToken == "":
		return errors.New("ACCESS_TOKEN is required")
	case c.profileID == "":
		return errors.New("RUNNER_PROFILE_ID is required")
	case c.runnerImage == "":
		return errors.New("RUNNER_IMAGE is required")
	case len(c.workerRevision) != 64 ||
		strings.IndexFunc(c.workerRevision, func(r rune) bool {
			return (r < '0' || r > '9') && (r < 'a' || r > 'f')
		}) >= 0:
		return errors.New("PITCREW_WORKER_REVISION must be a lowercase SHA-256 digest")
	case c.sessionOwner == "":
		return errors.New("PITCREW_SESSION_OWNER is required")
	case strings.IndexFunc(c.sessionOwner, func(r rune) bool {
		return !unicode.IsLetter(r) &&
			!unicode.IsDigit(r) &&
			r != '.' &&
			r != '_' &&
			r != '-'
	}) >= 0:
		return errors.New("PITCREW_SESSION_OWNER contains unsupported characters")
	case c.namePrefix == "":
		return errors.New("RUNNER_NAME_PREFIX is required")
	case c.stateDirectory == "" || c.stateDirectory == ".":
		return errors.New("PITCREW_STATE_DIRECTORY must identify a directory")
	case c.architectureLabel == "":
		return errors.New("current architecture cannot be empty")
	}

	switch c.scope {
	case "repo":
		if c.organization != "" || c.enterprise != "" {
			return errors.New("ORG_NAME and ENTERPRISE_NAME must be empty for repository scope")
		}
	case "org":
		if c.organization == "" {
			return errors.New("ORG_NAME is required for organization scope")
		}
		if c.enterprise != "" {
			return errors.New("ENTERPRISE_NAME must be empty for organization scope")
		}
		if strings.ContainsAny(c.organization, "/\\ \t\r\n") {
			return errors.New("ORG_NAME must be a GitHub organization name")
		}
	case "ent":
		if c.enterprise == "" {
			return errors.New("ENTERPRISE_NAME is required for enterprise scope")
		}
		if c.organization != "" {
			return errors.New("ORG_NAME must be empty for enterprise scope")
		}
		if strings.ContainsAny(c.enterprise, "/\\ \t\r\n") {
			return errors.New("ENTERPRISE_NAME must be a GitHub enterprise name")
		}
	default:
		return fmt.Errorf("RUNNER_SCOPE must be repo, org, or ent, got %q", c.scope)
	}

	for _, value := range []string{
		c.accessToken,
		c.profileID,
		c.runnerImage,
		c.workerRevision,
		c.sessionOwner,
		c.organization,
		c.enterprise,
		c.namePrefix,
		c.runnerGroup,
		c.stateDirectory,
		c.legacyRepositoryURLs,
		c.legacyRepositoryURL,
		c.legacyReplicas,
	} {
		if strings.ContainsAny(value, "\r\n") {
			return errors.New("runner configuration values cannot contain newlines")
		}
	}
	return nil
}

func parseLabels(value string) ([]string, error) {
	if value == "" {
		return nil, nil
	}
	parts := strings.Split(value, ",")
	labels := make([]string, 0, len(parts))
	for index, part := range parts {
		label := strings.TrimSpace(part)
		if label == "" {
			return nil, fmt.Errorf("RUNNER_LABELS contains an empty label at index %d", index)
		}
		if strings.ContainsAny(label, "\r\n") {
			return nil, fmt.Errorf("RUNNER_LABELS label %q contains a newline", label)
		}
		labels = append(labels, label)
	}
	return labels, nil
}

func parseBooleanFlag(name, value string) (bool, error) {
	switch value {
	case "", "0":
		return false, nil
	case "1":
		return true, nil
	default:
		return false, fmt.Errorf("%s must be empty, 0, or 1", name)
	}
}

func parseNonnegativeInteger(name, value string) (int, error) {
	if value == "" || strings.IndexFunc(value, func(r rune) bool {
		return r < '0' || r > '9'
	}) >= 0 {
		return 0, fmt.Errorf("%s must be a nonnegative integer", name)
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed < 0 {
		return 0, fmt.Errorf("%s must be a nonnegative integer", name)
	}
	return parsed, nil
}

func parsePositiveInteger(name, value string) (int, error) {
	if value == "" || strings.IndexFunc(value, func(r rune) bool {
		return r < '0' || r > '9'
	}) >= 0 {
		return 0, fmt.Errorf("%s must be a positive integer", name)
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed < 1 {
		return 0, fmt.Errorf("%s must be a positive integer", name)
	}
	return parsed, nil
}

func normalizeArchitecture(architecture string) string {
	switch strings.ToLower(strings.TrimSpace(architecture)) {
	case "amd64", "x86_64":
		return "x64"
	case "arm64", "aarch64":
		return "arm64"
	case "arm", "armv6l", "armv7l":
		return "arm"
	default:
		return strings.ToLower(strings.TrimSpace(architecture))
	}
}

func secondsToDuration(name string, seconds int) (time.Duration, error) {
	const maximumSeconds = int64((1<<63 - 1) / int64(time.Second))
	if int64(seconds) > maximumSeconds {
		return 0, fmt.Errorf("%s exceeds the supported duration", name)
	}
	return time.Duration(seconds) * time.Second, nil
}
