package terminal

import (
	"bytes"
	"context"
	"os"
	"testing"
	"time"
)

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
