package terminal

import (
	"context"
	"errors"
	"io"
	"os"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
	"golang.org/x/term"
)

type Controller struct {
	input  *os.File
	output io.Writer

	mu            sync.Mutex
	state         *term.State
	raw           bool
	geometryDirty bool
	readerOnce    sync.Once
	readerStarted bool
	readerCancel  context.CancelFunc
	readerDone    chan struct{}
	keys          chan rune
	prompting     bool
	promptInput   chan byte
}

func New(input *os.File, output io.Writer) *Controller {
	return &Controller{
		input: input, output: output, geometryDirty: true,
		keys: make(chan rune, 32),
	}
}

func (c *Controller) Enter() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	fd := int(c.input.Fd())
	if c.raw || !term.IsTerminal(fd) {
		return nil
	}
	state, err := term.MakeRaw(fd)
	if err != nil {
		return err
	}
	if err := enableInteractiveOutput(fd); err != nil {
		if restoreErr := term.Restore(fd, state); restoreErr != nil {
			c.state = state
			c.raw = true
			return errors.Join(err, restoreErr)
		}
		return err
	}
	c.state = state
	c.raw = true
	return nil
}

func (c *Controller) Restore() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.raw || c.state == nil {
		return nil
	}
	err := term.Restore(int(c.input.Fd()), c.state)
	c.raw = false
	return err
}

func (c *Controller) Keys(ctx context.Context) <-chan rune {
	c.readerOnce.Do(func() {
		readerContext, cancel := context.WithCancel(ctx)
		c.mu.Lock()
		c.readerStarted = true
		c.readerCancel = cancel
		c.readerDone = make(chan struct{})
		c.mu.Unlock()
		go c.readInput(readerContext)
	})
	return c.keys
}

func (c *Controller) Prompt(ctx context.Context, message string) (string, error) {
	c.Keys(ctx)
	c.mu.Lock()
	c.prompting = true
	c.promptInput = make(chan byte, 256)
	promptInput := c.promptInput
	c.mu.Unlock()
	wasRaw := c.isRaw()
	if wasRaw {
		if err := c.Restore(); err != nil {
			c.finishPrompt()
			return "", err
		}
		defer func() { _ = c.Enter() }()
	}
	if _, err := io.WriteString(c.output, message); err != nil {
		c.finishPrompt()
		return "", err
	}
	defer c.finishPrompt()
	var value strings.Builder
	for {
		select {
		case <-ctx.Done():
			return strings.TrimRight(value.String(), "\r\n"), ctx.Err()
		case character, ok := <-promptInput:
			if !ok {
				return strings.TrimRight(value.String(), "\r\n"), io.EOF
			}
			value.WriteByte(character)
			if character == '\n' {
				return strings.TrimRight(value.String(), "\r\n"), nil
			}
		}
	}
}

func (c *Controller) Stop() error {
	c.mu.Lock()
	cancel, done := c.readerCancel, c.readerDone
	c.mu.Unlock()
	if cancel == nil || done == nil {
		return nil
	}
	cancel()
	select {
	case <-done:
		return nil
	case <-time.After(time.Second):
		return errors.New("terminal input reader did not stop within one second")
	}
}

func (c *Controller) Size() (int, int) {
	width, height, err := term.GetSize(int(c.input.Fd()))
	if err != nil || width < 110 {
		width, height = 130, 24
	}
	c.mu.Lock()
	c.geometryDirty = false
	c.mu.Unlock()
	return width, height
}

func (c *Controller) Clear() error {
	_, err := io.WriteString(c.output, "\x1b[H\x1b[2J")
	return err
}

func (c *Controller) MarkGeometryDirty() {
	c.mu.Lock()
	c.geometryDirty = true
	c.mu.Unlock()
}

func (c *Controller) isRaw() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.raw
}

func (c *Controller) finishPrompt() {
	c.mu.Lock()
	c.prompting = false
	c.promptInput = nil
	c.mu.Unlock()
}

func (c *Controller) readInput(ctx context.Context) {
	fd := int(c.input.Fd())
	defer c.finishInput()
	pollDescriptors := []unix.PollFd{{
		Fd:     int32(fd),
		Events: unix.POLLIN,
	}}
	buffer := make([]byte, 1)
	for {
		if ctx.Err() != nil {
			return
		}

		pollDescriptors[0].Revents = 0
		ready, err := unix.Poll(pollDescriptors, 25)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil {
			return
		}
		if ready == 0 {
			continue
		}

		events := pollDescriptors[0].Revents
		if events&(unix.POLLERR|unix.POLLNVAL) != 0 {
			return
		}
		if events&unix.POLLIN == 0 {
			if events&unix.POLLHUP != 0 {
				return
			}
			continue
		}

		count, err := unix.Read(fd, buffer)
		if errors.Is(err, unix.EAGAIN) || errors.Is(err, unix.EWOULDBLOCK) || errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil || count == 0 {
			return
		}
		c.mu.Lock()
		prompting, promptInput := c.prompting, c.promptInput
		c.mu.Unlock()
		if prompting {
			select {
			case promptInput <- buffer[0]:
			case <-ctx.Done():
				return
			}
			continue
		}
		select {
		case c.keys <- rune(buffer[0]):
		case <-ctx.Done():
			return
		}
	}
}

func (c *Controller) finishInput() {
	c.mu.Lock()
	if c.promptInput != nil {
		close(c.promptInput)
		c.promptInput = nil
	}
	close(c.keys)
	if c.readerDone != nil {
		close(c.readerDone)
	}
	c.mu.Unlock()
}
