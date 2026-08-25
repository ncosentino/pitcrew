//go:build !windows

package main

import (
	"os/exec"
	"syscall"
	"time"
)

// processTeardownGrace bounds how long Wait may keep blocking once a docker
// CLI invocation has been signaled to die. It is a last-resort ceiling for a
// process stuck in an uninterruptible kernel wait that ignores SIGKILL; it
// does not by itself guarantee the OS process has exited, only that this
// program's own goroutine is no longer blocked on it.
const processTeardownGrace = 5 * time.Second

// configureProcessGroup gives a docker CLI invocation its own process group
// and kills the whole group on context cancellation. exec.CommandContext's
// default cancellation only signals the direct child PID, so a docker
// invocation that spawns further descendants (or is itself unresponsive to a
// single-process kill) could otherwise outlive the bounded call that started
// it.
func configureProcessGroup(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.WaitDelay = processTeardownGrace
	command.Cancel = func() error {
		return syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	}
}
