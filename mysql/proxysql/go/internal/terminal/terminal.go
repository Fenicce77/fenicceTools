package terminal

import (
	"bufio"
	"context"
	"io"
	"os"
	"strings"
	"sync"

	"golang.org/x/term"
)

type Controller struct {
	input  *os.File
	output io.Writer

	mu            sync.Mutex
	state         *term.State
	raw           bool
	geometryDirty bool
}

func New(input *os.File, output io.Writer) *Controller {
	return &Controller{input: input, output: output, geometryDirty: true}
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
	keys := make(chan rune, 32)
	go func() {
		defer close(keys)
		buffer := make([]byte, 1)
		for {
			select {
			case <-ctx.Done():
				return
			default:
			}
			count, err := c.input.Read(buffer)
			if err != nil || count == 0 {
				return
			}
			select {
			case keys <- rune(buffer[0]):
			case <-ctx.Done():
				return
			}
		}
	}()
	return keys
}

func (c *Controller) Prompt(message string) (string, error) {
	wasRaw := c.isRaw()
	if wasRaw {
		if err := c.Restore(); err != nil {
			return "", err
		}
		defer func() { _ = c.Enter() }()
	}
	if _, err := io.WriteString(c.output, message); err != nil {
		return "", err
	}
	value, err := bufio.NewReader(c.input).ReadString('\n')
	return strings.TrimRight(value, "\r\n"), err
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
