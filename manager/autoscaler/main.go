package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"runtime"
	"syscall"
)

func main() {
	cfg, err := loadConfig(os.LookupEnv, runtime.GOARCH)
	if err != nil {
		fmt.Fprintf(os.Stderr, "pitcrew autoscaler configuration error: %v\n", err)
		os.Exit(1)
	}
	instanceID, err := newManagerInstanceID()
	if err != nil {
		fmt.Fprintf(os.Stderr, "pitcrew autoscaler instance error: %v\n", err)
		os.Exit(1)
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil)).With(
		"profileId", cfg.profileID,
		"managerInstanceId", instanceID,
	)
	factory := githubScaleSetServiceFactory{
		accessToken: cfg.accessToken,
	}
	manager := newAutoscalerManager(
		cfg,
		factory,
		newDockerCLI(),
		realClock{},
		logger,
		instanceID,
	)
	ctx, cancel := signal.NotifyContext(
		context.Background(),
		os.Interrupt,
		syscall.SIGTERM,
	)
	defer cancel()
	if err := manager.run(ctx); err != nil {
		logger.Error("Autoscaler stopped with an error", "error", err)
		os.Exit(1)
	}
}

func newManagerInstanceID() (string, error) {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return hex.EncodeToString(value), nil
}
