package terminal

import (
	"bytes"
	"context"
	"errors"
	"os"
	"sync"
	"testing"
	"time"
)

type notifyingWriter struct {
	bytes.Buffer
	ready chan struct{}
	once  sync.Once
}

func (w *notifyingWriter) Write(data []byte) (int, error) {
	count, err := w.Buffer.Write(data)
	w.once.Do(func() { close(w.ready) })
	return count, err
}

func (w *notifyingWriter) WriteString(value string) (int, error) {
	count, err := w.Buffer.WriteString(value)
	w.once.Do(func() { close(w.ready) })
	return count, err
}

func TestNonTTYClearAndFallbackSize(t *testing.T) {
	input, err := os.Open(os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	defer input.Close()
	var output bytes.Buffer
	controller := New(input, &output)
	if err := controller.Enter(); err != nil {
		t.Fatal(err)
	}
	width, height := controller.Size()
	if width != 130 || height != 24 {
		t.Fatalf("size = %dx%d, want 130x24", width, height)
	}
	if err := controller.Clear(); err != nil {
		t.Fatal(err)
	}
	if output.String() != "\x1b[H\x1b[2J" {
		t.Fatalf("clear output = %q", output.String())
	}
	if err := controller.Restore(); err != nil {
		t.Fatal(err)
	}
}

func TestNonTTYKeysCloseOnCancellation(t *testing.T) {
	input, err := os.Open(os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	defer input.Close()
	controller := New(input, &bytes.Buffer{})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	select {
	case _, ok := <-controller.Keys(ctx):
		if ok {
			t.Fatal("key channel remained open")
		}
	case <-time.After(100 * time.Millisecond):
		t.Fatal("cancelled key channel did not close within timeout")
	}
}

func TestPromptDoesNotCompeteWithKeyReader(t *testing.T) {
	input, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer input.Close()
	defer writer.Close()
	output := &notifyingWriter{ready: make(chan struct{})}
	controller := New(input, output)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	keys := controller.Keys(ctx)
	if _, err := writer.Write([]byte{'r'}); err != nil {
		t.Fatal(err)
	}
	if key := <-keys; key != 'r' {
		t.Fatalf("key = %q, want r", key)
	}

	result := make(chan string, 1)
	errs := make(chan error, 1)
	go func() {
		value, promptErr := controller.Prompt(ctx, "refresh: ")
		if promptErr != nil {
			errs <- promptErr
			return
		}
		result <- value
	}()
	select {
	case <-output.ready:
	case <-time.After(time.Second):
		t.Fatal("prompt was not emitted")
	}
	if _, err := writer.Write([]byte("0.5\n")); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-errs:
		t.Fatal(err)
	case value := <-result:
		if value != "0.5" {
			t.Fatalf("prompt = %q, want 0.5", value)
		}
	case <-time.After(time.Second):
		t.Fatal("prompt timed out while key reader was active")
	}
	if err := controller.Stop(); err != nil {
		t.Fatal(err)
	}
}

func TestPromptCancellationStopsWaiting(t *testing.T) {
	input, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer input.Close()
	defer writer.Close()
	output := &notifyingWriter{ready: make(chan struct{})}
	controller := New(input, output)
	readerContext, cancelReader := context.WithCancel(context.Background())
	defer cancelReader()
	keys := controller.Keys(readerContext)
	if _, err := writer.Write([]byte{'r'}); err != nil {
		t.Fatal(err)
	}
	<-keys

	promptContext, cancelPrompt := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() {
		_, promptErr := controller.Prompt(promptContext, "refresh: ")
		result <- promptErr
	}()
	<-output.ready
	cancelPrompt()
	select {
	case promptErr := <-result:
		if !errors.Is(promptErr, context.Canceled) {
			t.Fatalf("prompt error = %v, want context.Canceled", promptErr)
		}
	case <-time.After(time.Second):
		t.Fatal("cancelled prompt did not return")
	}
	if err := controller.Stop(); err != nil {
		t.Fatal(err)
	}
}
