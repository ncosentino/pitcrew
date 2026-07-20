package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
)

type retirementRecord struct {
	Key                string `json:"key"`
	RegistrationURL    string `json:"registrationUrl"`
	Repository         string `json:"repository,omitempty"`
	Maximum            int    `json:"maximum"`
	ScaleSetName       string `json:"scaleSetName"`
	RetireAtGeneration int    `json:"retireAtGeneration"`
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
		ManagerContractVersion: managerContractVersion,
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
	if document.ManagerContractVersion != managerContractVersion {
		return retirementDocument{}, fmt.Errorf(
			"retiring-targets managerContractVersion must be %d, got %d",
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
		seen[record.Key] = struct{}{}
	}
	return document, nil
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
