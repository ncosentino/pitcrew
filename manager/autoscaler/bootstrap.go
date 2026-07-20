package main

import (
	"fmt"
	"strings"
)

func bootstrapLegacyDesiredState(cfg config, paths statePaths) (bool, error) {
	if _, exists, err := readOptionalFile(paths.desired); err != nil {
		return false, err
	} else if exists {
		return false, nil
	}
	if _, exists, err := readOptionalFile(paths.lastValid); err != nil {
		return false, err
	} else if exists {
		return false, nil
	}

	state := desiredState{
		SchemaVersion: 1,
		Generation:    1,
		Scope:         cfg.scope,
	}
	switch cfg.scope {
	case "repo":
		value := cfg.legacyRepositoryURLs
		if strings.TrimSpace(value) == "" {
			value = cfg.legacyRepositoryURL
		}
		if strings.TrimSpace(value) == "" {
			return false, nil
		}
		for _, rawEntry := range strings.Split(value, ",") {
			entry := strings.TrimSpace(rawEntry)
			if entry == "" {
				continue
			}
			repositoryURL := entry
			workers := 1
			if firstEquals := strings.Index(entry, "="); firstEquals >= 0 {
				repositoryURL = entry[:firstEquals]
				workerText := entry[strings.LastIndex(entry, "=")+1:]
				parsed, err := parsePositiveInteger("repository worker count", workerText)
				if err != nil {
					return false, err
				}
				workers = parsed
			}
			state.Repositories = append(state.Repositories, desiredRepository{
				URL:     repositoryURL,
				Workers: workers,
			})
		}
		state.Replicas = nil
	case "org", "ent":
		replicaValue := strings.TrimSpace(cfg.legacyReplicas)
		if replicaValue == "" {
			replicaValue = "1"
		}
		replicas, err := parsePositiveInteger(
			"RUNNER_REPLICAS",
			replicaValue,
		)
		if err != nil {
			return false, err
		}
		state.Repositories = make([]desiredRepository, 0)
		state.Replicas = &replicas
	default:
		return false, fmt.Errorf("cannot bootstrap unsupported scope %q", cfg.scope)
	}
	if err := canonicalizeDesiredRepositoryURLs(&state, nil); err != nil {
		return false, fmt.Errorf("legacy capacity is invalid: %w", err)
	}
	if err := validateDesiredState(state, cfg.scope); err != nil {
		return false, fmt.Errorf("legacy capacity is invalid: %w", err)
	}
	if err := writeJSONAtomically(paths.desired, state); err != nil {
		return false, fmt.Errorf("publish bootstrapped desired capacity: %w", err)
	}
	return true, nil
}
