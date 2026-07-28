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
	readerOnce    sync.Once
	readerStarted bool
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
		c.mu.Lock()
		c.readerStarted = true
		c.mu.Unlock()
		go c.readInput(ctx)
	})
	return c.keys
}

func (c *Controller) Prompt(message string) (string, error) {
	c.mu.Lock()
	readerStarted := c.readerStarted
	var promptInput chan byte
	if readerStarted {
		c.prompting = true
		c.promptInput = make(chan byte, 256)
		promptInput = c.promptInput
	}
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
	if !readerStarted {
		value, err := bufio.NewReader(c.input).ReadString('\n')
		return strings.TrimRight(value, "\r\n"), err
	}
	defer c.finishPrompt()
	var value strings.Builder
	for {
		character, ok := <-promptInput
		if !ok {
			return strings.TrimRight(value.String(), "\r\n"), io.EOF
		}
		value.WriteByte(character)
		if character == '\n' {
			return strings.TrimRight(value.String(), "\r\n"), nil
		}
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
	defer func() {
		c.mu.Lock()
		if c.promptInput != nil {
			close(c.promptInput)
			c.promptInput = nil
		}
		close(c.keys)
		c.mu.Unlock()
	}()
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
