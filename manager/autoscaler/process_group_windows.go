//go:build windows

package main

import "os/exec"

// The manager only ever runs the docker CLI from its Linux container image;
// Windows builds exist solely for developer tooling, so process-group
// hardening (see process_group_unix.go) has no equivalent here and
// cancellation falls back to the standard library's default per-process
// kill.
func configureProcessGroup(*exec.Cmd) {}
