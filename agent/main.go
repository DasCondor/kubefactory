// kf-agent is KubeFactory's native companion. The game starts it as a child
// process and talks to it over that process's own stdin/stdout, one JSON
// object per line. There is no network listener: only the process that
// spawned the agent can reach it.
//
// The interface is a fixed set of typed operations (see the ops table). There
// is no operation that runs an arbitrary command, here or inside a container.
//
//	request   {"id": 7, "op": "kube.logs", "args": {...}}
//	response  {"id": 7, "ok": true, "data": {...}}
//	          {"id": 7, "ok": false, "error": {"kind": "rbac", "msg": "..."}}
//	event     {"event": "frame", "sid": "b1", ...}        (unsolicited)
//
// Error kinds: config, exec_untrusted, needs_base_dir, auth, rbac, tls,
// timeout, unreachable, notfound, conflict, invalid, unsupported, other.
//
// Nothing read from a kubeconfig (tokens, keys, certificates) is ever logged
// or returned to the game.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"sync"
)

const agentVersion = "2.0.0"

type request struct {
	ID   int64           `json:"id"`
	Op   string          `json:"op"`
	Args json.RawMessage `json:"args"`
}

type opError struct {
	Kind string `json:"kind"`
	Msg  string `json:"msg"`
	// Extra carries structured detail the UI needs to act (for example the
	// name of an exec credential plugin awaiting approval). Never secrets.
	Extra map[string]any `json:"extra,omitempty"`
}

func (e *opError) Error() string { return e.Kind + ": " + e.Msg }

func fail(kind, format string, a ...any) *opError {
	return &opError{Kind: kind, Msg: fmt.Sprintf(format, a...)}
}

type handler func(args json.RawMessage) (any, error)

var (
	out   = bufio.NewWriterSize(os.Stdout, 1<<20)
	outMu sync.Mutex
	ops   = map[string]handler{}

	inFlight sync.WaitGroup
)

func send(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	outMu.Lock()
	out.Write(b)
	out.WriteByte('\n')
	out.Flush()
	outMu.Unlock()
}

// emit sends an unsolicited event (browser frames, forward closed, ...).
func emit(event string, fields map[string]any) {
	fields["event"] = event
	send(fields)
}

func decode[T any](raw json.RawMessage) (T, error) {
	var v T
	if len(raw) == 0 {
		return v, nil
	}
	if err := json.Unmarshal(raw, &v); err != nil {
		return v, fail("invalid", "bad arguments: %v", err)
	}
	return v, nil
}

func registerAll() {
	ops["ping"] = func(json.RawMessage) (any, error) {
		return map[string]any{"version": agentVersion, "pid": os.Getpid()}, nil
	}
	registerKubeconfig()
	registerKube()
	registerFiles()
	registerForward()
	registerBrowser()
	registerProviders()
	registerAI()
	registerKomodo()
}

func main() {
	registerAll()

	in := bufio.NewReaderSize(os.Stdin, 1<<20)
	for {
		line, err := in.ReadBytes('\n')
		line = bytes.TrimPrefix(line, []byte{0xEF, 0xBB, 0xBF}) // a byte-order mark some shells prepend
		if len(line) > 1 {
			var req request
			if json.Unmarshal(line, &req) != nil {
				send(map[string]any{"id": 0, "ok": false, "error": opError{Kind: "invalid", Msg: "not a JSON request"}})
			} else {
				if req.Op == "shutdown" {
					send(map[string]any{"id": req.ID, "ok": true, "data": map[string]any{}})
					break
				}
				inFlight.Add(1)
				go func() { defer inFlight.Done(); serve(req) }()
			}
		}
		if err != nil {
			break // the game closed our stdin (or exited): clean up and leave
		}
	}
	inFlight.Wait() // answer what was already asked before leaving
	shutdownAll()
}

func serve(req request) {
	defer func() {
		if r := recover(); r != nil {
			send(map[string]any{"id": req.ID, "ok": false, "error": opError{Kind: "other", Msg: fmt.Sprint("internal error: ", r)}})
		}
	}()
	h, ok := ops[req.Op]
	if !ok {
		send(map[string]any{"id": req.ID, "ok": false, "error": opError{Kind: "unsupported", Msg: "unknown operation " + req.Op}})
		return
	}
	data, err := h(req.Args)
	if err != nil {
		oe, isOp := err.(*opError)
		if !isOp {
			oe = classify(err)
		}
		send(map[string]any{"id": req.ID, "ok": false, "error": oe})
		return
	}
	send(map[string]any{"id": req.ID, "ok": true, "data": data})
}

// shutdownAll releases everything the agent holds: port-forwards, browser
// sessions and their temporary profiles, informers.
func shutdownAll() {
	closeAllForwards()
	closeAllBrowsers()
	closeAllSessions()
}
