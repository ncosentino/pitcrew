package main

import (
	"errors"
	"testing"
	"time"
)

func TestControlPlaneGateDoesNotCarryPATCooldownIntoGitHubApp(t *testing.T) {
	directory := projectTestDirectory(t)
	path := newStatePaths(directory).controlPlane
	clock := &fakeClock{current: time.Now().UTC()}
	patGate := newControlPlaneRateGate(path, "profile-a", clock)
	if err := patGate.before(); err != nil {
		t.Fatal(err)
	}
	patGate.after(errors.New("API rate limit exceeded"))

	appGate := newControlPlaneRateGate(path, "profile-a", clock)
	appGate.credentialIdentity = "app:Iv1example"
	if err := appGate.load(); err != nil {
		t.Fatal(err)
	}
	if err := appGate.before(); err != nil {
		t.Fatalf("PAT cooldown blocked GitHub App authentication: %v", err)
	}
}
