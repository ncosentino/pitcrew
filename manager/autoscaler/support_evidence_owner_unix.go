//go:build !windows

package main

import (
	"errors"
	"fmt"
	"os"
	"syscall"
)

func preserveSupportEvidenceOwner(stateDirectory string, path string) error {
	info, err := os.Stat(stateDirectory)
	if err != nil {
		return fmt.Errorf("inspect state directory owner: %w", err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return errors.New("state directory owner is unavailable")
	}
	if err := os.Chown(path, int(stat.Uid), int(stat.Gid)); err != nil {
		return fmt.Errorf("set state owner: %w", err)
	}
	return nil
}
