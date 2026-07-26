package main

import "time"

// containerExitState carries Docker's own evidence about how a worker exited.
// A nil oomKilled means Docker did not report the flag rather than reporting
// that no OOM occurred.
type containerExitState struct {
	exitCode  int
	oomKilled *bool
}

// lastExitDiagnostic is the bounded, credential-free exit evidence published
// for one exact worker identity.
type lastExitDiagnostic struct {
	ObservedAt      string `json:"observedAt"`
	Classification  string `json:"classification"`
	ExitCode        *int   `json:"exitCode"`
	Signal          *int   `json:"signal"`
	DockerOOMKilled *bool  `json:"dockerOomKilled"`
	Evidence        string `json:"evidence"`
}

// classifyContainerExit derives the contract-11 exit classification. Precedence
// is Docker-confirmed OOM, SIGKILL, another signal, a clean zero exit, an
// ordinary nonzero error, and finally unknown. Exit code 137 on its own never
// proves an OOM kill because a plain SIGKILL produces the same status.
func classifyContainerExit(
	state containerExitState,
	inspected bool,
	observedAt time.Time,
) lastExitDiagnostic {
	diagnostic := lastExitDiagnostic{
		ObservedAt: observedAt.UTC().Format(time.RFC3339),
		Evidence:   "docker-wait",
	}
	if inspected {
		diagnostic.Evidence = "docker-inspect"
		diagnostic.DockerOOMKilled = state.oomKilled
	}
	exitCode := state.exitCode
	if exitCode < 0 || exitCode > 255 {
		diagnostic.Classification = "unknown"
		diagnostic.Evidence = "unavailable"
		return diagnostic
	}
	diagnostic.ExitCode = &exitCode
	if signal := signalFromExitCode(exitCode); signal > 0 {
		diagnostic.Signal = &signal
	}
	switch {
	case inspected && state.oomKilled != nil && *state.oomKilled:
		diagnostic.Classification = "oom-killed"
	case diagnostic.Signal != nil && *diagnostic.Signal == 9:
		diagnostic.Classification = "sigkill"
	case diagnostic.Signal != nil:
		diagnostic.Classification = "signal"
	case exitCode == 0:
		diagnostic.Classification = "clean"
	default:
		diagnostic.Classification = "error"
	}
	return diagnostic
}

// launchFailureDiagnostic records a worker that never reached a running state.
func launchFailureDiagnostic(observedAt time.Time) lastExitDiagnostic {
	return lastExitDiagnostic{
		ObservedAt:     observedAt.UTC().Format(time.RFC3339),
		Classification: "launch-failure",
		Evidence:       "launch",
	}
}

func signalFromExitCode(exitCode int) int {
	if exitCode <= 128 || exitCode > 128+64 {
		return 0
	}
	return exitCode - 128
}
