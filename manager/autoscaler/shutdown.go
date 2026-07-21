package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"
)

type shutdownRequest struct {
	SchemaVersion      int    `json:"schemaVersion"`
	ManagerContainerID string `json:"managerContainerId"`
	RequestedAt        string `json:"requestedAt"`
}

func (m *autoscalerManager) fullStopRequested() (bool, error) {
	data, exists, err := readOptionalFile(m.paths.shutdownRequest)
	if err != nil {
		return false, err
	}
	if !exists {
		return false, nil
	}
	var request shutdownRequest
	if err := json.Unmarshal(data, &request); err != nil {
		return false, fmt.Errorf("decode manager shutdown request: %w", err)
	}
	if request.SchemaVersion != 1 {
		return false, fmt.Errorf(
			"manager shutdown request schemaVersion must be 1, got %d",
			request.SchemaVersion,
		)
	}
	if request.ManagerContainerID == "" {
		return false, errors.New("manager shutdown request requires managerContainerId")
	}
	if request.RequestedAt == "" {
		return false, errors.New("manager shutdown request requires requestedAt")
	}
	if _, err := time.Parse(time.RFC3339Nano, request.RequestedAt); err != nil {
		return false, fmt.Errorf("parse manager shutdown requestedAt: %w", err)
	}
	containerID, err := os.Hostname()
	if err != nil {
		return false, fmt.Errorf("resolve manager container identity: %w", err)
	}
	containerID = strings.TrimSpace(containerID)
	if containerID == "" {
		return false, errors.New("manager container identity is empty")
	}
	return strings.HasPrefix(request.ManagerContainerID, containerID), nil
}
