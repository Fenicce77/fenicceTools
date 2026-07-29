package terminal

import (
	"testing"

	"golang.org/x/sys/unix"
)

func TestConfigureInteractiveTermios(t *testing.T) {
	state := &unix.Termios{}

	configureInteractiveTermios(state)

	if state.Oflag&unix.OPOST == 0 {
		t.Error("OPOST is disabled")
	}
	if state.Oflag&unix.ONLCR == 0 {
		t.Error("ONLCR is disabled")
	}
	if state.Lflag&unix.ISIG == 0 {
		t.Error("ISIG is disabled")
	}
}
