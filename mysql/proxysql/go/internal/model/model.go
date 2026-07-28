package model

import "time"

type View string

const (
	ViewConn    View = "CONN"
	ViewQuery   View = "QUERY"
	ViewDigest  View = "DIGEST"
	ViewBackend View = "BACKEND"
)

type SortMode string

const (
	SortConn SortMode = "CONN"
	SortUser SortMode = "USER"
)

type Config struct {
	LoginPaths []string
	Refresh    time.Duration
	UserFilter string
	Threshold  int
	OutputFile string
	SmokeTest  bool
	Timeout    time.Duration
}

type ConnectionRow struct {
	User, ClientHost, ServerHost, Schema string
	Connections                          int
}

type QueryRow struct {
	SessionID, Hostgroup, User, ClientHost, ServerHost string
	TimeMS                                             int
	Query                                              string
}

type DigestRow struct {
	Digest                           string
	Count, SumTime, MinTime, MaxTime int
	Query                            string
}

type PoolRow struct {
	Hostgroup, ServerHost, Status       string
	ConnUsed, ConnFree, ConnOK, ConnErr int
}

type PingRow struct {
	Hostname, LastPing, Error string
	SuccessUS                 *int
}

type BackendRows struct {
	Pool []PoolRow
	Ping []PingRow
}

type RenderedView struct {
	Colored  string
	Clean    string
	RowCount int
}

type State struct {
	View                View
	Sort                SortMode
	Paused              bool
	Stale               bool
	LastError           string
	PreviousConnections []ConnectionRow
	LastRendered        string
}

func NewState() State {
	return State{View: ViewConn, Sort: SortConn}
}

type SmokeResult struct {
	LoginPath string
	View      View
	Rows      int
	Elapsed   time.Duration
	Success   bool
	Error     string
}
