package main

import (
	"context"
	"testing"
	"time"
)

func TestGitHubAppSkipsPeriodicRegistrationTokenProbe(t *testing.T) {
	manager := newTestManager(t, &fakeClock{current: time.Now().UTC()})
	manager.cfg.githubApp = githubAppConfig{
		clientID:       "Iv1.example",
		privateKeyPath: "/run/secrets/app.pem",
	}
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
