package main

import (
	"context"
	"io"
	"log/slog"
	"testing"
	"time"
)

func TestGitHubAppSkipsPeriodicRegistrationTokenProbe(t *testing.T) {
	clock := &fakeClock{current: time.Now().UTC()}
	cfg := managerTestConfig(projectTestDirectory(t))
	cfg.githubApp = githubAppConfig{
		clientID:       "Iv1example",
		privateKeyPath: "/run/secrets/app.pem",
	}
	manager := newAutoscalerManager(
		cfg,
		newFakeScaleSetServiceFactory(),
		newFakeDockerClient(nil),
		clock,
		slog.New(slog.NewTextHandler(io.Discard, nil)),
		"manager-test",
	)
	api := newFakeScaleSetService(nil)
	manager.controllers["target"] = &targetController{
		target: targetSpec{key: "target"},
		api:    api,
	}
	manager.checkRegistrationAccessIfDue(context.Background())
	if api.registrationAccessCalls != 0 {
		t.Fatalf(
			"GitHub App registration-token probes = %d, want 0",
			api.registrationAccessCalls,
		)
	}
}
