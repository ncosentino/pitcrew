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

const managerContractVersion = 18

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
	maximumActiveWorkers int
	workerImageID        string
	resources            workerResourcePolicy
	runtime              workerRuntimePolicy
	readOnlyVolumes      []readOnlyVolume
	serviceNetwork       string
	scaleDownDelay       time.Duration
	observedInterval     time.Duration
	architectureLabel    string
	legacyRepositoryURLs string
	legacyRepositoryURL  string
	legacyReplicas       string
	hostAdmission        hostAdmissionConfig
}

// hostAdmissionConfig carries this profile's identity for the host-local
// admission coordinator (ADR-0003). Enabled is false, and every other field
// is empty, unless all four PITCREW_HOST_ADMISSION_* variables were
// supplied together; a partially configured identity fails config loading
// closed rather than silently falling back to disabled or partially
// enabled behavior.
type hostAdmissionConfig struct {
	enabled            bool
	namespace          string
	socketPath         string
	hostFingerprint    string
	profileFingerprint string
}

type readOnlyVolume struct {
	name   string
	source string
}

func (v readOnlyVolume) target() string {
	return "/mnt/pitcrew-data/" + v.name
}

func parseReadOnlyVolumes(value string) ([]readOnlyVolume, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil, nil
	}
	entries := strings.Split(value, ",")
	if len(entries) > 8 {
		return nil, errors.New("PITCREW_READ_ONLY_VOLUMES supports at most 8 volumes")
	}
	names := make(map[string]struct{}, len(entries))
	sources := make(map[string]struct{}, len(entries))
	volumes := make([]readOnlyVolume, 0, len(entries))
	for _, entry := range entries {
		name, source, found := strings.Cut(entry, "=")
		if !found || !validReadOnlyVolumeName(name) || !validDockerVolumeName(source) {
			return nil, fmt.Errorf(
				"PITCREW_READ_ONLY_VOLUMES contains invalid entry %q",
				entry,
			)
		}
		if _, exists := names[name]; exists {
			return nil, fmt.Errorf(
				"PITCREW_READ_ONLY_VOLUMES duplicates logical name %q",
				name,
			)
		}
		if _, exists := sources[source]; exists {
			return nil, fmt.Errorf(
				"PITCREW_READ_ONLY_VOLUMES duplicates source volume %q",
				source,
			)
		}
		names[name] = struct{}{}
		sources[source] = struct{}{}
		volumes = append(volumes, readOnlyVolume{name: name, source: source})
	}
	return volumes, nil
}

func validReadOnlyVolumeName(value string) bool {
	if len(value) < 1 || len(value) > 32 || value[0] < 'a' || value[0] > 'z' {
		return false
	}
	for _, character := range value {
		if (character < 'a' || character > 'z') &&
			(character < '0' || character > '9') &&
			character != '-' {
			return false
		}
	}
	return true
}

func validDockerVolumeName(value string) bool {
	if len(value) < 1 || len(value) > 128 {
		return false
	}
	for index, character := range value {
		if (character >= 'a' && character <= 'z') ||
			(character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') {
			continue
		}
		if index > 0 && (character == '_' || character == '.' || character == '-') {
			continue
		}
		return false
	}
	return true
}

func validDockerNetworkName(value string) bool {
	if value == "" {
		return true
	}
	if value == "bridge" {
		return false
	}
	if !validDockerVolumeName(value) {
		return false
	}
	if strings.HasPrefix(value, "self-hosted-runner") &&
		strings.HasSuffix(value, "_default") {
		middle := strings.TrimSuffix(
			strings.TrimPrefix(value, "self-hosted-runner"),
			"_default",
		)
		if middle == "" {
			return false
		}
		if strings.HasPrefix(middle, "-") &&
			validReadOnlyVolumeName(strings.TrimPrefix(middle, "-")) {
			return false
		}
	}
	return true
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
	maximumActiveWorkers, err := parseOptionalPositiveInteger(
		"PITCREW_AUTOSCALING_MAX_ACTIVE_WORKERS",
		value("PITCREW_AUTOSCALING_MAX_ACTIVE_WORKERS", ""),
	)
	if err != nil {
		return config{}, err
	}
	workerImageID, err := parseWorkerImageID(
		"PITCREW_WORKER_IMAGE_ID",
		value("PITCREW_WORKER_IMAGE_ID", ""),
	)
	if err != nil {
		return config{}, err
	}
	resources, err := loadWorkerResourcePolicy(value)
	if err != nil {
		return config{}, err
	}
	runtimePolicy, err := loadWorkerRuntimePolicy(value)
	if err != nil {
		return config{}, err
	}
	readOnlyVolumes, err := parseReadOnlyVolumes(
		value("PITCREW_READ_ONLY_VOLUMES", ""),
	)
	if err != nil {
		return config{}, err
	}
	serviceNetwork := strings.TrimSpace(value("PITCREW_SERVICE_NETWORK", ""))
	if !validDockerNetworkName(serviceNetwork) {
		return config{}, errors.New(
			"PITCREW_SERVICE_NETWORK must be a Docker-safe external network name and cannot identify a reserved manager network",
		)
	}
	hostAdmission, err := loadHostAdmissionConfig(value)
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
		maximumActiveWorkers: maximumActiveWorkers,
		workerImageID:        workerImageID,
		resources:            resources,
		runtime:              runtimePolicy,
		readOnlyVolumes:      readOnlyVolumes,
		serviceNetwork:       serviceNetwork,
		scaleDownDelay:       scaleDownDelay,
		observedInterval:     observedInterval,
		architectureLabel:    normalizeArchitecture(architecture),
		legacyRepositoryURLs: value("REPO_URLS", ""),
		legacyRepositoryURL:  value("REPO_URL", ""),
		legacyReplicas:       value("RUNNER_REPLICAS", "1"),
		hostAdmission:        hostAdmission,
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
	case c.maximumActiveWorkers < 0:
		return errors.New("PITCREW_AUTOSCALING_MAX_ACTIVE_WORKERS must be a positive integer")
	case c.hostAdmission.enabled && (c.hostAdmission.namespace == "" ||
		c.hostAdmission.socketPath == "" ||
		c.hostAdmission.hostFingerprint == "" ||
		c.hostAdmission.profileFingerprint == ""):
		return errors.New(
			"host admission requires PITCREW_HOST_ADMISSION_NAMESPACE, " +
				"PITCREW_HOST_ADMISSION_SOCKET, PITCREW_HOST_ADMISSION_HOST_FINGERPRINT, " +
				"and PITCREW_HOST_ADMISSION_PROFILE_FINGERPRINT together",
		)
	}

	if err := c.resources.validate(); err != nil {
		return err
	}
	if _, err := parseWorkerImageID("PITCREW_WORKER_IMAGE_ID", c.workerImageID); err != nil {
		return err
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
		c.serviceNetwork,
		c.legacyRepositoryURLs,
		c.legacyRepositoryURL,
		c.legacyReplicas,
		c.hostAdmission.namespace,
		c.hostAdmission.socketPath,
		c.hostAdmission.hostFingerprint,
		c.hostAdmission.profileFingerprint,
	} {
		if strings.ContainsAny(value, "\r\n") {
			return errors.New("runner configuration values cannot contain newlines")
		}
	}
	return nil
}

// loadHostAdmissionConfig reads the four PITCREW_HOST_ADMISSION_* variables
// that identify this profile to the host-local admission coordinator
// (ADR-0003). All four empty means host admission is disabled and the
// autoscaler behaves exactly as it did before this coordinator existed; any
// other subset is an incomplete identity and fails closed rather than
// guessing which combination the operator intended.
func loadHostAdmissionConfig(
	value func(name, fallback string) string,
) (hostAdmissionConfig, error) {
	namespace := strings.TrimSpace(value("PITCREW_HOST_ADMISSION_NAMESPACE", ""))
	socketPath := strings.TrimSpace(value("PITCREW_HOST_ADMISSION_SOCKET", ""))
	hostFingerprint := strings.TrimSpace(value("PITCREW_HOST_ADMISSION_HOST_FINGERPRINT", ""))
	profileFingerprint := strings.TrimSpace(value("PITCREW_HOST_ADMISSION_PROFILE_FINGERPRINT", ""))

	present := 0
	for _, field := range []string{namespace, socketPath, hostFingerprint, profileFingerprint} {
		if field != "" {
			present++
		}
	}
	switch present {
	case 0:
		return hostAdmissionConfig{}, nil
	case 4:
		return hostAdmissionConfig{
			enabled:            true,
			namespace:          namespace,
			socketPath:         socketPath,
			hostFingerprint:    hostFingerprint,
			profileFingerprint: profileFingerprint,
		}, nil
	default:
		return hostAdmissionConfig{}, errors.New(
			"PITCREW_HOST_ADMISSION_NAMESPACE, PITCREW_HOST_ADMISSION_SOCKET, " +
				"PITCREW_HOST_ADMISSION_HOST_FINGERPRINT, and " +
				"PITCREW_HOST_ADMISSION_PROFILE_FINGERPRINT must be set together or not at all",
		)
	}
}

// loadWorkerResourcePolicy reads the canonical per-worker limits. Empty values
// mean unconfigured; the manager never treats them as zero.
func loadWorkerResourcePolicy(
	value func(name, fallback string) string,
) (workerResourcePolicy, error) {
	memoryBytes, err := parseOptionalInt64(
		"PITCREW_WORKER_MEMORY_BYTES",
		value("PITCREW_WORKER_MEMORY_BYTES", ""),
	)
	if err != nil {
		return workerResourcePolicy{}, err
	}
	memorySwapBytes, err := parseOptionalInt64(
		"PITCREW_WORKER_MEMORY_SWAP_BYTES",
		value("PITCREW_WORKER_MEMORY_SWAP_BYTES", ""),
	)
	if err != nil {
		return workerResourcePolicy{}, err
	}
	pids, err := parseOptionalInt64(
		"PITCREW_WORKER_PIDS_LIMIT",
		value("PITCREW_WORKER_PIDS_LIMIT", ""),
	)
	if err != nil {
		return workerResourcePolicy{}, err
	}
	policy := workerResourcePolicy{
		memoryBytes:     memoryBytes,
		memorySwapBytes: memorySwapBytes,
		cpuCores:        strings.TrimSpace(value("PITCREW_WORKER_CPU_CORES", "")),
		pids:            pids,
	}
	if err := policy.validate(); err != nil {
		return workerResourcePolicy{}, err
	}
	return policy, nil
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
