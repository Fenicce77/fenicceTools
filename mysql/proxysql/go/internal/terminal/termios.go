package terminal

import "golang.org/x/sys/unix"

func configureInteractiveTermios(state *unix.Termios) {
	state.Oflag |= unix.OPOST | unix.ONLCR
	state.Lflag |= unix.ISIG
}
