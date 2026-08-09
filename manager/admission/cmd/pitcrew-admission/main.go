// Command pitcrew-admission is the single static binary for the host-local
// admission coordinator described by
// docs/adr/adr-0003-dedicated-host-admission-service.md. It serves the
// coordinator over a Unix domain socket ("serve") and offers CLI
// subcommands that speak the same client protocol ("acquire", "renew",
// "activate", "release", "reconcile", "apply-policy", "status") so a POSIX
// shell manager can drive admission without a separate Go program, while a
// Go manager may instead import the admission package's Client directly.
//
// Wiring this binary into the manager Compose topology, entrypoint, or
// Setup-Runner.ps1 is out of scope here; that belongs to the setup and
// manager integration issues that build on this core.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/ncosentino/pitcrew/manager/admission"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, usage())
		os.Exit(2)
	}
	command := os.Args[1]
	args := os.Args[2:]

	var err error
	switch command {
	case "serve":
		err = runServe(args)
	case "apply-policy":
		err = runApplyPolicy(args)
	case "set-demand":
		err = runSetDemand(args)
	case "acquire":
		err = runAcquire(args)
	case "renew":
		err = runRenew(args)
	case "activate":
		err = runActivate(args)
	case "release":
		err = runRelease(args)
	case "reconcile":
		err = runReconcile(args)
	case "status":
		err = runStatus(args)
	case "-h", "--help", "help":
		fmt.Fprintln(os.Stdout, usage())
		return
	default:
		fmt.Fprintf(os.Stderr, "pitcrew-admission: unknown command %q\n\n%s\n", command, usage())
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "pitcrew-admission %s: %v\n", command, err)
		os.Exit(exitCodeForError(err))
	}
}

func exitCodeForError(err error) int {
	if errors.Is(err, admission.ErrBudgetExceeded) {
		return 3
	}
	if errors.Is(err, admission.ErrLeaseNotFound) {
		return 4
	}
	return 1
}

func usage() string {
	return `pitcrew-admission serves and drives the host-local admission coordinator.

Usage:
  pitcrew-admission serve --socket PATH --state-dir DIR [--provisional-ttl DURATION]
  pitcrew-admission apply-policy --socket PATH --policy-file FILE|-
  pitcrew-admission set-demand --socket PATH --profile ID --demand N
  pitcrew-admission acquire --socket PATH --profile ID --slot KEY [--demand N]
  pitcrew-admission renew --socket PATH --profile ID --slot KEY
  pitcrew-admission activate --socket PATH --profile ID --slot KEY
  pitcrew-admission release --socket PATH --profile ID --slot KEY
  pitcrew-admission reconcile --socket PATH --profile ID --slot KEY --evidence TEXT
  pitcrew-admission status --socket PATH`
}

func runServe(args []string) error {
	flagSet := flag.NewFlagSet("serve", flag.ContinueOnError)
	socketPath := flagSet.String("socket", "", "Unix domain socket path to listen on")
	stateDirectory := flagSet.String("state-dir", "", "durable state directory")
	provisionalTTL := flagSet.Duration(
		"provisional-ttl",
		admission.DefaultProvisionalLeaseTTL,
		"provisional lease lifetime before it expires without renewal",
	)
	if err := flagSet.Parse(args); err != nil {
		return err
	}
	if *socketPath == "" || *stateDirectory == "" {
		return errors.New("--socket and --state-dir are required")
	}

	coordinator, err := admission.OpenFile(*stateDirectory, admission.SystemClock{}, *provisionalTTL)
	if err != nil {
		return fmt.Errorf("open durable admission state: %w", err)
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	server, err := admission.NewServer(coordinator, *socketPath, logger)
	if err != nil {
		return err
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	logger.Info("pitcrew-admission listening", "socket", *socketPath, "stateDir", *stateDirectory)
	return server.Serve(ctx)
}

func runApplyPolicy(args []string) error {
	flagSet := flag.NewFlagSet("apply-policy", flag.ContinueOnError)
	socketPath := flagSet.String("socket", "", "Unix domain socket path")
	policyFile := flagSet.String("policy-file", "-", "path to a JSON host policy document, or - for stdin")
	if err := flagSet.Parse(args); err != nil {
		return err
	}
	if *socketPath == "" {
		return errors.New("--socket is required")
	}
	data, err := readAll(*policyFile)
	if err != nil {
		return fmt.Errorf("read policy: %w", err)
	}
	var policy admission.HostPolicy
	if err := json.Unmarshal(data, &policy); err != nil {
		return fmt.Errorf("decode policy: %w", err)
	}
	client := admission.NewClient(*socketPath)
	return client.ApplyPolicy(policy)
}

func runSetDemand(args []string) error {
	flagSet := flag.NewFlagSet("set-demand", flag.ContinueOnError)
	socketPath := flagSet.String("socket", "", "Unix domain socket path")
	profileID := flagSet.String("profile", "", "profile identity")
	demand := flagSet.Int("demand", 0, "current total pending demand for this profile")
	if err := flagSet.Parse(args); err != nil {
		return err
	}
	if *socketPath == "" || *profileID == "" {
		return errors.New("--socket and --profile are required")
	}
	client := admission.NewClient(*socketPath)
	return client.SetDemand(*profileID, *demand)
}

func runAcquire(args []string) error {
	flagSet := flag.NewFlagSet("acquire", flag.ContinueOnError)
	socketPath := flagSet.String("socket", "", "Unix domain socket path")
	profileID := flagSet.String("profile", "", "profile identity")
	slotKey := flagSet.String("slot", "", "exact slot identity")
	demand := flagSet.Int("demand", 1, "current total pending demand for this profile, including this request")
	if err := flagSet.Parse(args); err != nil {
		return err
	}
	if *socketPath == "" || *profileID == "" || *slotKey == "" {
		return errors.New("--socket, --profile, and --slot are required")
	}
	client := admission.NewClient(*socketPath)
	lease, err := client.Acquire(*profileID, *slotKey, *demand)
	if err != nil && !errors.Is(err, admission.ErrDuplicateLease) {
		return err
	}
	return printJSON(lease)
}

func runRenew(args []string) error {
	profileID, slotKey, client, err := parseSlotArgs("renew", args)
	if err != nil {
		return err
	}
	lease, err := client.Renew(profileID, slotKey)
	if err != nil {
		return err
	}
	return printJSON(lease)
}

func runActivate(args []string) error {
	profileID, slotKey, client, err := parseSlotArgs("activate", args)
	if err != nil {
		return err
	}
	lease, err := client.Activate(profileID, slotKey)
	if err != nil {
		return err
	}
	return printJSON(lease)
}

func runRelease(args []string) error {
	profileID, slotKey, client, err := parseSlotArgs("release", args)
	if err != nil {
		return err
	}
	return client.Release(profileID, slotKey)
}

func runReconcile(args []string) error {
	flagSet := flag.NewFlagSet("reconcile", flag.ContinueOnError)
	socketPath := flagSet.String("socket", "", "Unix domain socket path")
	profileID := flagSet.String("profile", "", "profile identity")
	slotKey := flagSet.String("slot", "", "exact slot identity")
	evidence := flagSet.String("evidence", "", "exact retained evidence that the worker and registration are absent")
	if err := flagSet.Parse(args); err != nil {
		return err
	}
	if *socketPath == "" || *profileID == "" || *slotKey == "" || *evidence == "" {
		return errors.New("--socket, --profile, --slot, and --evidence are required")
	}
	client := admission.NewClient(*socketPath)
	return client.Reconcile(*profileID, *slotKey, *evidence)
}

func runStatus(args []string) error {
	flagSet := flag.NewFlagSet("status", flag.ContinueOnError)
	socketPath := flagSet.String("socket", "", "Unix domain socket path")
	if err := flagSet.Parse(args); err != nil {
		return err
	}
	if *socketPath == "" {
		return errors.New("--socket is required")
	}
	client := admission.NewClient(*socketPath)
	snapshot, err := client.Status()
	if err != nil {
		return err
	}
	return printJSON(snapshot)
}

func parseSlotArgs(name string, args []string) (string, string, *admission.Client, error) {
	flagSet := flag.NewFlagSet(name, flag.ContinueOnError)
	socketPath := flagSet.String("socket", "", "Unix domain socket path")
	profileID := flagSet.String("profile", "", "profile identity")
	slotKey := flagSet.String("slot", "", "exact slot identity")
	if err := flagSet.Parse(args); err != nil {
		return "", "", nil, err
	}
	if *socketPath == "" || *profileID == "" || *slotKey == "" {
		return "", "", nil, errors.New("--socket, --profile, and --slot are required")
	}
	return *profileID, *slotKey, admission.NewClient(*socketPath), nil
}

func readAll(path string) ([]byte, error) {
	if path == "-" {
		return io.ReadAll(os.Stdin)
	}
	return os.ReadFile(path)
}

func printJSON(value any) error {
	encoded, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	fmt.Fprintln(os.Stdout, string(encoded))
	return nil
}
