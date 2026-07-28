package transport

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type Config struct {
	LoginPath   string
	MySQLBinary string
	ArgsPrefix  []string
	QueueSize   int
	StderrLines int
}

type lineResult struct {
	line string
	err  error
}

type Session struct {
	cfg Config

	mu       sync.Mutex
	execMu   sync.Mutex
	cmd      *exec.Cmd
	stdin    io.WriteCloser
	lines    chan lineResult
	done     chan struct{}
	overflow chan struct{}
	stopRead chan struct{}
	waitErr  error
	readers  sync.WaitGroup
	sequence uint64
	closed   bool
	stderr   *ringBuffer
}

func New(cfg Config) *Session {
	if cfg.MySQLBinary == "" {
		cfg.MySQLBinary = os.Getenv("MYSQL_BIN")
		if cfg.MySQLBinary == "" {
			cfg.MySQLBinary = "mysql"
		}
	}
	if cfg.QueueSize <= 0 {
		cfg.QueueSize = 4096
	}
	if cfg.StderrLines <= 0 {
		cfg.StderrLines = 100
	}
	return &Session{cfg: cfg, stderr: newRingBuffer(cfg.StderrLines)}
}

func (s *Session) commandArgs() []string {
	args := append([]string{}, s.cfg.ArgsPrefix...)
	return append(args,
		"--login-path="+s.cfg.LoginPath,
		"--batch",
		"--skip-column-names",
		"--unbuffered",
		"--force",
	)
}

func (s *Session) Start(ctx context.Context) error {
	s.execMu.Lock()
	defer s.execMu.Unlock()
	return s.start(ctx)
}

func (s *Session) start(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return errors.New("MySQL session is closed")
	}
	if s.cmd != nil {
		select {
		case <-s.done:
		default:
			s.mu.Unlock()
			return nil
		}
	}
	hadProcess := s.cmd != nil
	s.mu.Unlock()
	if hadProcess {
		_ = s.stopProcess()
	}

	command := exec.Command(s.cfg.MySQLBinary, s.commandArgs()...)
	stdin, err := command.StdinPipe()
	if err != nil {
		return fmt.Errorf("create MySQL stdin: %w", err)
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return fmt.Errorf("create MySQL stdout: %w", err)
	}
	stderr, err := command.StderrPipe()
	if err != nil {
		_ = stdin.Close()
		return fmt.Errorf("create MySQL stderr: %w", err)
	}
	if err := command.Start(); err != nil {
		_ = stdin.Close()
		return fmt.Errorf("start MySQL client: %w", err)
	}

	s.mu.Lock()
	s.cmd = command
	s.stdin = stdin
	s.lines = make(chan lineResult, s.cfg.QueueSize)
	s.done = make(chan struct{})
	s.overflow = make(chan struct{})
	s.stopRead = make(chan struct{})
	s.waitErr = nil
	s.stderr = newRingBuffer(s.cfg.StderrLines)
	lines, done, overflow, stopRead := s.lines, s.done, s.overflow, s.stopRead

	s.readers.Add(2)
	go s.scanStdout(stdout, lines, overflow, stopRead)
	go s.scanStderr(stderr, stopRead)
	go func() {
		err := command.Wait()
		s.mu.Lock()
		s.waitErr = err
		s.mu.Unlock()
		close(done)
	}()
	s.mu.Unlock()
	return nil
}

func (s *Session) Alive() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cmd == nil {
		return false
	}
	select {
	case <-s.done:
		return false
	default:
		return true
	}
}

func (s *Session) Execute(ctx context.Context, sql string, timeout time.Duration) ([]string, error) {
	s.execMu.Lock()
	defer s.execMu.Unlock()
	return s.execute(ctx, sql, timeout)
}

func (s *Session) execute(ctx context.Context, sql string, timeout time.Duration) ([]string, error) {
	if timeout <= 0 {
		return nil, errors.New("timeout must be greater than zero")
	}
	if err := s.start(ctx); err != nil {
		return nil, err
	}

	s.mu.Lock()
	s.sequence++
	sequence := s.sequence
	stdin, lines, done, overflow := s.stdin, s.lines, s.done, s.overflow
	s.mu.Unlock()
	begin := "__PXMON_BEGIN_" + strconv.FormatUint(sequence, 10) + "__"
	end := "__PXMON_END_" + strconv.FormatUint(sequence, 10) + "__"
	payload := fmt.Sprintf("SELECT '%s';\n%s\nSELECT '%s';\n", begin, strings.TrimSpace(sql), end)
	if _, err := io.WriteString(stdin, payload); err != nil {
		return nil, s.withStderr("MySQL write failed", err)
	}

	timer := time.NewTimer(timeout)
	defer timer.Stop()
	collecting := false
	rows := make([]string, 0)
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-timer.C:
			return nil, s.withStderr("MySQL query timed out", nil)
		case <-overflow:
			return nil, errors.New("MySQL stdout queue overflow")
		case <-done:
			s.mu.Lock()
			err := s.waitErr
			s.mu.Unlock()
			return nil, s.withStderr("MySQL client exited", err)
		case result := <-lines:
			if result.err != nil {
				return nil, s.withStderr("read MySQL stdout", result.err)
			}
			switch {
			case result.line == begin:
				collecting = true
				rows = rows[:0]
			case result.line == end && collecting:
				return rows, nil
			case collecting:
				rows = append(rows, result.line)
			}
		}
	}
}

func (s *Session) ExecuteWithRetry(ctx context.Context, sql string, timeout time.Duration) ([]string, error) {
	s.execMu.Lock()
	defer s.execMu.Unlock()
	rows, err := s.execute(ctx, sql, timeout)
	if err == nil {
		return rows, nil
	}
	if reconnectErr := s.stopProcess(); reconnectErr != nil {
		return nil, errors.Join(err, reconnectErr)
	}
	if startErr := s.start(ctx); startErr != nil {
		return nil, errors.Join(err, startErr)
	}
	return s.execute(ctx, sql, timeout)
}

func (s *Session) Reconnect(ctx context.Context) error {
	s.execMu.Lock()
	defer s.execMu.Unlock()
	if err := s.stopProcess(); err != nil {
		return err
	}
	return s.start(ctx)
}

func (s *Session) Stderr() []string {
	return s.stderr.Values()
}

func (s *Session) Close() error {
	s.execMu.Lock()
	defer s.execMu.Unlock()
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil
	}
	s.closed = true
	s.mu.Unlock()
	return s.stopProcess()
}

func (s *Session) stopProcess() error {
	s.mu.Lock()
	command, stdin, done, stopRead := s.cmd, s.stdin, s.done, s.stopRead
	s.cmd, s.stdin = nil, nil
	s.mu.Unlock()
	if command == nil {
		return nil
	}
	if stdin != nil {
		_ = stdin.Close()
	}
	if command.Process != nil {
		_ = command.Process.Signal(syscall.SIGTERM)
	}
	timer := time.NewTimer(time.Second)
	select {
	case <-done:
		timer.Stop()
	case <-timer.C:
		if command.Process != nil {
			_ = command.Process.Kill()
		}
		<-done
	}
	close(stopRead)
	s.readers.Wait()
	return nil
}

func (s *Session) scanStdout(
	reader io.Reader,
	lines chan<- lineResult,
	overflow chan struct{},
	stop <-chan struct{},
) {
	defer s.readers.Done()
	scanner := bufio.NewScanner(reader)
	buffer := make([]byte, 64*1024)
	scanner.Buffer(buffer, 4*1024*1024)
	var overflowOnce sync.Once
	for scanner.Scan() {
		select {
		case lines <- lineResult{line: strings.TrimSuffix(scanner.Text(), "\r")}:
		case <-stop:
			return
		default:
			overflowOnce.Do(func() { close(overflow) })
			return
		}
	}
	if err := scanner.Err(); err != nil {
		select {
		case lines <- lineResult{err: err}:
		case <-stop:
		default:
			overflowOnce.Do(func() { close(overflow) })
		}
	}
}

func (s *Session) scanStderr(reader io.Reader, stop <-chan struct{}) {
	defer s.readers.Done()
	scanner := bufio.NewScanner(reader)
	for scanner.Scan() {
		select {
		case <-stop:
			return
		default:
			s.stderr.Add(strings.TrimSuffix(scanner.Text(), "\r"))
		}
	}
}

func (s *Session) withStderr(prefix string, err error) error {
	message := prefix
	if err != nil {
		message += ": " + err.Error()
	}
	values := s.Stderr()
	if len(values) > 0 {
		message += ": " + values[len(values)-1]
	}
	return errors.New(message)
}

type ringBuffer struct {
	mu     sync.Mutex
	values []string
	next   int
	full   bool
}

func newRingBuffer(size int) *ringBuffer {
	return &ringBuffer{values: make([]string, size)}
}

func (r *ringBuffer) Add(value string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.values[r.next] = value
	r.next = (r.next + 1) % len(r.values)
	if r.next == 0 {
		r.full = true
	}
}

func (r *ringBuffer) Values() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.full {
		return append([]string(nil), r.values[:r.next]...)
	}
	values := append([]string(nil), r.values[r.next:]...)
	return append(values, r.values[:r.next]...)
}
