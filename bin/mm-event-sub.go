// mm-event-sub connects to the mintmux Unix socket, discovers firstmate
// sessions from state/*.meta files, subscribes to every pane it finds,
// and outputs one JSONL event per mintmux server event to stdout.
// Each output line is a compact {"ts","pane_id","event_type","summary"}.
//
// Env vars:
//   MM_SOCK          mintmux socket path (default ~/.cache/.../mintmux-<uid>.sock)
//   MM_SESSION       session filter (optional; when unset, reads from state/*.meta)
//   FM_STATE_OVERRIDE firstmate state dir
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

type Event struct {
	V       int    `json:"v"`
	Kind    string `json:"kind"`
	Pane    uint64 `json:"pane,omitempty"`
	Seq     uint64 `json:"seq,omitempty"`
	Data    []byte `json:"data,omitempty"`
	Code    int    `json:"code,omitempty"`
	Sig     int    `json:"sig,omitempty"`
	Cols    uint16 `json:"cols,omitempty"`
	Rows    uint16 `json:"rows,omitempty"`
	Dropped uint64 `json:"dropped,omitempty"`
	Result  string `json:"result,omitempty"`
	Meta    any    `json:"meta,omitempty"`
	Fatal   string `json:"fatal,omitempty"`
}

type Cmd struct {
	V       int    `json:"v"`
	Kind    string `json:"kind"`
	Pane    uint64 `json:"pane,omitempty"`
	Session string `json:"session,omitempty"`
}

type outEvent struct {
	Ts        int64  `json:"ts"`
	PaneID    uint64 `json:"pane_id"`
	EventType string `json:"event_type"`
	Summary   string `json:"summary"`
}

var verbose bool

func logf(f string, a ...any) {
	if verbose {
		fmt.Fprintf(os.Stderr, f+"\n", a...)
	}
}

func main() {
	for _, a := range os.Args[1:] {
		if a == "-v" || a == "--verbose" {
			verbose = true
		}
	}
	sock := os.Getenv("MM_SOCK")
	if sock == "" {
		sock = fmt.Sprintf("%s/.cache/mintmux/mintmux-%d.sock", os.Getenv("HOME"), os.Getuid())
	}
	sessionFilter := os.Getenv("MM_SESSION")
	stateDir := os.Getenv("FM_STATE_OVERRIDE")
	if stateDir == "" {
		if h := os.Getenv("FM_HOME"); h != "" {
			stateDir = filepath.Join(h, "state")
		}
	}

	conn, err := net.Dial("unix", sock)
	if err != nil {
		fmt.Fprintf(os.Stderr, "mm-event-sub: dial %s: %v\n", sock, err)
		os.Exit(1)
	}
	defer conn.Close()
	br := bufio.NewReader(conn)

	wh := func(kind string, opts ...func(*Cmd)) error {
		c := &Cmd{V: 1, Kind: kind}
		for _, o := range opts {
			o(c)
		}
		line, _ := json.Marshal(c)
		line = append(line, '\n')
		_, err := conn.Write(line)
		if err != nil {
			logf("wh %s: write error: %v", kind, err)
			conn.Close()
		}
		return err
	}
	withSession := func(s string) func(*Cmd) { return func(c *Cmd) { c.Session = s } }
	withPane := func(p uint64) func(*Cmd) { return func(c *Cmd) { c.Pane = p } }

	re := func() (*Event, error) {
		for {
			line, err := br.ReadBytes('\n')
		if err != nil {
				return nil, err
		}
			var ev Event
			if err := json.Unmarshal(line, &ev); err != nil {
				continue
		}
			return &ev, nil
		}
	}

	// Handshake.
	if err := wh("hello"); err != nil {
		logf("wh hello: %v", err)
	}
	ack, err := re()
	if err != nil || ack.Kind != "ctrl_ack" || ack.Result != "OK" {
		if err != nil {
			fmt.Fprintf(os.Stderr, "mm-event-sub: hello: %v\n", err)
		} else {
			fmt.Fprintf(os.Stderr, "mm-event-sub: hello rejected: kind=%s result=%s\n", ack.Kind, ack.Result)
		}
		os.Exit(1)
	}
	logf("connected to mintmux")

	// Discover sessions.
	sessions := discoverSessions(stateDir, sessionFilter)
	if len(sessions) == 0 {
		logf("no sessions to watch; set MM_SESSION or ensure state/*.meta files exist")
	}

	// Subscribe every pane in each session.
	for _, sess := range sessions {
		logf("subscribing to session %s", sess)
		if err := wh("list_panes", withSession(sess)); err != nil {
			logf("wh list_panes: %v", err)
			break
		}
		for i := 0; i < 64; i++ {
			ev, err := re()
		if err != nil {
				break
		}
			if ev.Kind == "ctrl_ack" {
				break
		}
			if ev.Kind == "meta" && ev.Meta != nil {
				if mm, ok := ev.Meta.(map[string]any); ok {
					if raw, ok := mm["panes"].([]any); ok {
						for _, p := range raw {
							if pm, ok := p.(map[string]any); ok {
								if id, ok := pm["id"].(float64); ok {
									pid := uint64(id)
									if err := wh("subscribe", withPane(pid)); err != nil {
										logf("wh subscribe: %v", err)
									}
									logf("subscribed to pane %d", pid)
								}
							}
						}
					}
				}
		}
		}
	}

	// Emitter goroutine.
	ec := make(chan outEvent, 256)
	go func() {
		enc := json.NewEncoder(os.Stdout)
		for oe := range ec {
			enc.Encode(oe)
		}
	}()

	// Reader goroutine.
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			ev, err := re()
		if err != nil {
				if err != io.EOF {
					logf("read error: %v", err)
				}
				return
		}
			if oe := classify(ev); oe != nil {
				ec <- *oe
		}
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	select {
	case <-sig:
		logf("shutting down")
		wh("unsubscribe")
		conn.Close()
		<-done
		close(ec)
	case <-done:
		close(ec)
	}
}

func discoverSessions(stateDir, filter string) []string {
	if filter != "" {
		return []string{filter}
	}
	seen := make(map[string]bool)
	entries, err := os.ReadDir(stateDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "mm-event-sub: reading state directory %s: %v\n", stateDir, err)
		return nil
	}
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".meta") {
			continue
		}
		data, _ := os.ReadFile(filepath.Join(stateDir, e.Name()))
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "window=") {
				val := strings.TrimPrefix(line, "window=")
				s := val
				if colon := strings.Index(val, ":"); colon > 0 {
					s = val[:colon]
				}
				if !seen[s] {
					seen[s] = true
				}
		}
		}
	}
	var r []string
	for s := range seen {
		r = append(r, s)
	}
	return r
}

func classify(ev *Event) *outEvent {
	if ev == nil {
		return nil
	}
	now := time.Now().Unix()
	switch ev.Kind {
	case "out":
		t := decode(ev.Data)
		if len(t) > 120 {
			t = t[:120] + "..."
		}
		return &outEvent{Ts: now, PaneID: ev.Pane, EventType: "output", Summary: t}
	case "exit":
		return &outEvent{Ts: now, PaneID: ev.Pane, EventType: "exit", Summary: fmt.Sprintf("exit code %d", ev.Code)}
	case "overflow":
		return &outEvent{Ts: now, PaneID: ev.Pane, EventType: "overflow", Summary: fmt.Sprintf("dropped %d events", ev.Dropped)}
	case "resize":
		return &outEvent{Ts: now, PaneID: ev.Pane, EventType: "resize", Summary: fmt.Sprintf("resized %dx%d", ev.Cols, ev.Rows)}
	case "signal":
		sn := fmt.Sprintf("SIG%d", ev.Sig)
		return &outEvent{Ts: now, PaneID: ev.Pane, EventType: "signal", Summary: sn}
	case "send_ack":
		return &outEvent{Ts: now, PaneID: ev.Pane, EventType: "send_ack", Summary: "write acked"}
	case "fatal":
		return &outEvent{Ts: now, PaneID: ev.Pane, EventType: "fatal", Summary: ev.Fatal}
	}
	return nil
}

func decode(data []byte) string {
	if len(data) == 0 {
		return ""
	}
	s := string(data)
	s = strings.Map(func(r rune) rune {
		if r >= 32 && r <= 126 || r == '\n' || r == '\t' {
			return r
		}
		return -1
	}, s)
	return strings.TrimSpace(s)
}
