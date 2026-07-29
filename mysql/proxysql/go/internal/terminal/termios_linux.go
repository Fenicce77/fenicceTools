//go:build linux

package terminal

import "golang.org/x/sys/unix"

func enableInteractiveOutput(fd int) error {
	state, err := unix.IoctlGetTermios(fd, unix.TCGETS)
	if err != nil {
		return err
	}
	configureInteractiveTermios(state)
	return unix.IoctlSetTermios(fd, unix.TCSETS, state)
}
