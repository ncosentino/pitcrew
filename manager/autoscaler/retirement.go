package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"time"
)

// Optional retry fields remain readable by older managers. Keep retirement
// intent rollback-readable rather than changing the document contract.
const retirementDocumentContractVersion = 8

const (
	retirementStartupRetryBase = time.Minute
	retirementStartupRetryMax  = 15 * time.Minute
)

type retirementRecord struct {
	Key                string `json:"key"`
	RegistrationURL    string `json:"registrationUrl"`
	Repository         string `json:"repository,omitempty"`
	Maximum            int    `json:"maximum"`
	ScaleSetName       string `json:"scaleSetName"`
	RetireAtGeneration int    `json:"retireAtGeneration"`
	StartupAttempts    int    `json:"startupAttempts,omitempty"`
	StartupRetryAt     string `json:"startupRetryAt,omitempty"`
}

type retirementDocument struct {
	SchemaVersion          int                `json:"schemaVersion"`
	ManagerContractVersion int                `json:"managerContractVersion"`
	Generation             int                `json:"generation"`
	Targets                []retirementRecord `json:"targets"`
}

func newRetirementDocument(generation int, records map[string]retirementRecord) retirementDocument {
	targets := make([]retirementRecord, 0, len(records))
	for _, record := range records {
		targets = append(targets, record)
	}
	sort.Slice(targets, func(i, j int) bool {
		return targets[i].Key < targets[j].Key
	})
	return retirementDocument{
		SchemaVersion:          1,
		ManagerContractVersion: retirementDocumentContractVersion,
		Generation:             generation,
		Targets:                targets,
	}
}

func parseRetirementDocument(data []byte) (retirementDocument, error) {
	var document retirementDocument
	if err := json.Unmarshal(data, &document); err != nil {
		return retirementDocument{}, fmt.Errorf("decode retiring-targets document: %w", err)
	}
	if document.SchemaVersion != 1 {
		return retirementDocument{}, fmt.Errorf(
			"retiring-targets schemaVersion must be 1, got %d",
			document.SchemaVersion,
		)
	}
	if document.ManagerContractVersion < 8 ||
		document.ManagerContractVersion > managerContractVersion {
		return retirementDocument{}, fmt.Errorf(
			"retiring-targets managerContractVersion must be between 8 and %d, got %d",
			managerContractVersion,
			document.ManagerContractVersion,
		)
	}
	if document.Generation < 0 {
		return retirementDocument{}, errors.New("retiring-targets generation cannot be negative")
	}
	seen := make(map[string]struct{}, len(document.Targets))
	for index, record := range document.Targets {
		if record.Key == "" || record.RegistrationURL == "" ||
			record.ScaleSetName == "" || record.Maximum < 1 ||
			record.RetireAtGeneration < 1 {
			return retirementDocument{}, fmt.Errorf(
				"retiring target at index %d is incomplete",
				index,
			)
		}
		if _, exists := seen[record.Key]; exists {
			return retirementDocument{}, fmt.Errorf(
				"retiring-targets contains duplicate key %q",
				record.Key,
			)
		}
		if record.StartupAttempts < 0 ||
			record.StartupAttempts > maxRegistrationCleanupAttempts ||
			(record.StartupAttempts == 0) != (record.StartupRetryAt == "") {
			return retirementDocument{}, errors.New("retiring target has invalid startup retry state")
		}
		if record.StartupRetryAt != "" {
			if _, err := time.Parse(time.RFC3339, record.StartupRetryAt); err != nil {
				return retirementDocument{}, errors.New("retiring target has invalid startup retry deadline")
			}
		}
		seen[record.Key] = struct{}{}
	}
	return document, nil
}

func (m *autoscalerManager) prepareRetirementStartup(record retirementRecord) error {
	now := m.clock.now().UTC()
	if record.StartupRetryAt != "" {
		retryAt, err := time.Parse(time.RFC3339, record.StartupRetryAt)
		if err != nil {
			return fmt.Errorf("invalid retiring target %s retry deadline", record.Key)
		}
		if now.Before(retryAt) {
			return fmt.Errorf(
				"retiring target %s is waiting for retry backoff until %s",
				record.Key,
				record.StartupRetryAt,
			)
		}
	}
	record.StartupAttempts = min(record.StartupAttempts+1, maxRegistrationCleanupAttempts)
	record.StartupRetryAt = now.Add(boundedExponentialBackoff(
		retirementStartupRetryBase,
		retirementStartupRetryMax,
		record.StartupAttempts,
	)).Format(time.RFC3339)
	records := cloneRetirementRecords(m.retirementRecords)
	records[record.Key] = record
	// Commit before discovery: failures and manager crashes must not reset pacing.
	if err := m.persistRetirements(m.current.state.Generation, records); err != nil {
		return fmt.Errorf("persist startup retry for retiring target %s: %w", record.Key, err)
	}
	return nil
}

func retirementRecordFor(target targetSpec, generation int) retirementRecord {
	return retirementRecord{
		Key:                target.key,
		RegistrationURL:    target.registrationURL,
		Repository:         target.repository,
		Maximum:            target.maximum,
		ScaleSetName:       target.scaleSetName,
		RetireAtGeneration: generation,
	}
}

func (r retirementRecord) targetSpec() targetSpec {
	return targetSpec{
		key:             r.Key,
		registrationURL: r.RegistrationURL,
		repository:      r.Repository,
		maximum:         r.Maximum,
		scaleSetName:    r.ScaleSetName,
	}
}
