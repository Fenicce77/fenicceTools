//go:build darwin

package terminal

import "golang.org/x/sys/unix"

func enableInteractiveOutput(fd int) error {
	state, err := unix.IoctlGetTermios(fd, unix.TIOCGETA)
	if err != nil {
		return err
	}
	configureInteractiveTermios(state)
	return unix.IoctlSetTermios(fd, unix.TIOCSETA, state)
}
