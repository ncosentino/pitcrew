package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math"
	"sort"
	"strings"
	"unicode"
)

const (
	managedProfileLabelKey = "ephemeral-managed-runner-profile"
	managedSlotLabelKey    = "ephemeral-managed-runner-slot"
	managerProfileLabelKey = "ephemeral-runner-manager-profile"
	autoscalerLabelKey     = "pitcrew-autoscaler"
	targetKeyLabelKey      = "pitcrew-autoscaler-target-key"
	runnerNameLabelKey     = "pitcrew-autoscaler-runner-name"
	runnerIDLabelKey       = "pitcrew-autoscaler-runner-id"
)

type targetSpec struct {
	key             string
	registrationURL string
	repository      string
	maximum         int
	scaleSetName    string
}

func effectiveLabels(cfg config) []string {
	labels := append([]string(nil), cfg.labels...)
	labels = appendUnique(labels, "linux")
	labels = appendUnique(labels, cfg.architectureLabel)
	if !cfg.noDefaultLabels {
		labels = appendUnique(labels, "self-hosted")
	}
	return labels
}

func appendUnique(labels []string, candidate string) []string {
	for _, existing := range labels {
		if strings.EqualFold(existing, candidate) {
			return labels
		}
	}
	return append(labels, candidate)
}

func buildTargetSpecs(state desiredState, cfg config) ([]targetSpec, error) {
	var targets []targetSpec
	switch state.Scope {
	case "repo":
		targets = make([]targetSpec, 0, len(state.Repositories))
		seen := make(map[string]struct{}, len(state.Repositories))
		for _, repository := range state.Repositories {
			canonicalURL, err := canonicalRepositoryURL(repository.URL)
			if err != nil {
				return nil, err
			}
			if _, duplicate := seen[canonicalURL]; duplicate {
				return nil, fmt.Errorf(
					"desired-capacity contains duplicate repository URL %q",
					canonicalURL,
				)
			}
			seen[canonicalURL] = struct{}{}
			if repository.Workers > math.MaxInt32 {
				return nil, fmt.Errorf(
					"repository %q maximum %d exceeds scale-set limit %d",
					canonicalURL,
					repository.Workers,
					math.MaxInt32,
				)
			}
			key := repositoryTargetKey(canonicalURL)
			targets = append(targets, targetSpec{
				key:             key,
				registrationURL: canonicalURL,
				repository:      canonicalURL,
				maximum:         repository.Workers,
				scaleSetName:    stableScaleSetName(cfg.profileID, cfg.namePrefix, canonicalURL),
			})
		}
	case "org":
		if *state.Replicas > math.MaxInt32 {
			return nil, fmt.Errorf(
				"organization maximum %d exceeds scale-set limit %d",
				*state.Replicas,
				math.MaxInt32,
			)
		}
		targets = []targetSpec{{
			key:             "scope",
			registrationURL: "https://github.com/" + cfg.organization,
			maximum:         *state.Replicas,
			scaleSetName: stableScaleSetName(
				cfg.profileID,
				cfg.namePrefix,
				"https://github.com/"+cfg.organization,
			),
		}}
	case "ent":
		if *state.Replicas > math.MaxInt32 {
			return nil, fmt.Errorf(
				"enterprise maximum %d exceeds scale-set limit %d",
				*state.Replicas,
				math.MaxInt32,
			)
		}
		targets = []targetSpec{{
			key:             "scope",
			registrationURL: "https://github.com/enterprises/" + cfg.enterprise,
			maximum:         *state.Replicas,
			scaleSetName: stableScaleSetName(
				cfg.profileID,
				cfg.namePrefix,
				"https://github.com/enterprises/"+cfg.enterprise,
			),
		}}
	default:
		return nil, fmt.Errorf("unsupported desired scope %q", state.Scope)
	}
	sort.Slice(targets, func(i, j int) bool {
		return targets[i].key < targets[j].key
	})
	return targets, nil
}

func repositoryTargetKey(repositoryURL string) string {
	digest := sha256.Sum256([]byte(repositoryURL))
	return "repo-" + hex.EncodeToString(digest[:8])
}

func stableScaleSetName(profileID, namePrefix, registrationURL string) string {
	digest := sha256.Sum256([]byte(namePrefix + "\n" + registrationURL))
	hash := hex.EncodeToString(digest[:6])
	profile := sanitizeIdentifier(profileID, 40)
	if profile == "" {
		profile = "profile"
	}
	return "pitcrew-" + profile + "-" + hash
}

func sanitizeIdentifier(value string, maximum int) string {
	var builder strings.Builder
	lastHyphen := false
	for _, r := range strings.ToLower(value) {
		valid := unicode.IsLetter(r) || unicode.IsDigit(r)
		if valid {
			builder.WriteRune(r)
			lastHyphen = false
			continue
		}
		if !lastHyphen && builder.Len() > 0 {
			builder.WriteByte('-')
			lastHyphen = true
		}
	}
	result := strings.Trim(builder.String(), "-")
	if len(result) > maximum {
		result = strings.Trim(result[:maximum], "-")
	}
	return result
}

func configuredSlotKeys(state desiredState) []string {
	var keys []string
	if state.Scope == "repo" {
		for _, repository := range state.Repositories {
			targetKey := repositoryTargetKey(repository.URL)
			for ordinal := 1; ordinal <= repository.Workers; ordinal++ {
				keys = append(keys, fmt.Sprintf("%s-%06d", targetKey, ordinal))
			}
		}
	} else if state.Replicas != nil {
		for ordinal := 1; ordinal <= *state.Replicas; ordinal++ {
			keys = append(keys, fmt.Sprintf("scope-%06d", ordinal))
		}
	}
	sort.Strings(keys)
	return keys
}

func diffSlotKeys(previous, current desiredState) (added, draining, unchanged []string) {
	previousSet := make(map[string]struct{})
	for _, key := range configuredSlotKeys(previous) {
		previousSet[key] = struct{}{}
	}
	currentSet := make(map[string]struct{})
	for _, key := range configuredSlotKeys(current) {
		currentSet[key] = struct{}{}
		if _, exists := previousSet[key]; exists {
			unchanged = append(unchanged, key)
		} else {
			added = append(added, key)
		}
	}
	for key := range previousSet {
		if _, exists := currentSet[key]; !exists {
			draining = append(draining, key)
		}
	}
	sort.Strings(added)
	sort.Strings(draining)
	sort.Strings(unchanged)
	return added, draining, unchanged
}
