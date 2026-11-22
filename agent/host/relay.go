package main

// The access point: a WebSocket address on the host that players connect to
// instead of the container. It passes every message through to the KubeFactory
// server in the container. When the container, Docker or Kubernetes restarts,
// the player's connection stays open: the game keeps showing the last state
// with a notice, actions are refused with "the server is restarting", and when
// the server is back the access point signs the player in again and the state
// flows as before.
//
// To sign in again it keeps the player's hello message (with the token) in
// memory for as long as that player is connected, and nowhere else. It is
// never logged or written to disk.

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

const (
	maxClientMessage = 1 << 20
	maxServerMessage = 64 << 20
	maxSessions      = 64
	firstWait        = 8 * time.Second // how long a new player waits for a server that is starting
	retryEvery       = 2 * time.Second
)

type Relay struct {
	Upstream string        // ws://127.0.0.1:<internal port>
	Status   func() Status // what /kf-host/status shows
	Log      func(string)

	sessions atomic.Int32
	upgrader websocket.Upgrader
}

func (r *Relay) log(s string) {
	if r.Log != nil {
		r.Log(s)
	}
}

func (r *Relay) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	if req.URL.Path == "/kf-host/status" {
		w.Header().Set("Content-Type", "application/json")
		st := Status{}
		if r.Status != nil {
			st = r.Status()
		}
		_ = json.NewEncoder(w).Encode(st)
		return
	}
	if r.sessions.Load() >= maxSessions {
		http.Error(w, "too many players on this access point", http.StatusServiceUnavailable)
		return
	}
	c, err := r.upgrader.Upgrade(w, req, nil)
	if err != nil {
		r.log("refused a connection from " + req.RemoteAddr + ": " + err.Error())
		return
	}
	r.sessions.Add(1)
	defer r.sessions.Add(-1)
	c.SetReadLimit(maxClientMessage)
	s := &session{relay: r, client: c, done: make(chan struct{})}
	s.run()
}

type session struct {
	relay  *Relay
	client *websocket.Conn
	cw     sync.Mutex // writes to the player
	mu     sync.Mutex
	up     *websocket.Conn // nil while the server is away
	uw     sync.Mutex      // writes to the server
	hello  []byte          // the player's sign-in, kept in memory to sign in again
	done   chan struct{}
	once   sync.Once
}

func (s *session) toClient(msg []byte) error {
	s.cw.Lock()
	defer s.cw.Unlock()
	s.client.SetWriteDeadline(time.Now().Add(15 * time.Second))
	return s.client.WriteMessage(websocket.TextMessage, msg)
}

func (s *session) notice(level, msg string) {
	b, _ := json.Marshal(map[string]string{"type": "notice", "level": level, "msg": msg, "from": "kf-host"})
	_ = s.toClient(b)
}

func (s *session) close() {
	s.once.Do(func() {
		close(s.done)
		// wait, then a proper close frame: Godot drops messages that arrive in
		// the same poll as the close, so a refused sign-in would go unread
		time.Sleep(time.Second)
		s.cw.Lock()
		_ = s.client.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""), time.Now().Add(time.Second))
		s.cw.Unlock()
		time.Sleep(300 * time.Millisecond)
		s.client.Close()
		s.mu.Lock()
		if s.up != nil {
			s.up.Close()
		}
		s.hello = nil
		s.mu.Unlock()
	})
}

func (s *session) run() {
	defer s.close()
	// the player must say hello first, as with the server itself
	s.client.SetReadDeadline(time.Now().Add(10 * time.Second))
	_, hello, err := s.client.ReadMessage()
	if err != nil {
		return
	}
	var h map[string]any
	if json.Unmarshal(hello, &h) != nil || h["op"] != "hello" {
		return
	}
	s.client.SetReadDeadline(time.Time{})
	s.hello = hello
	// first sign-in: wait a little for a server that is starting
	deadline := time.Now().Add(firstWait)
	var up *websocket.Conn
	var reply []byte
	for {
		up, reply, err = s.signIn()
		if err == nil || time.Now().After(deadline) {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if err != nil {
		b, _ := json.Marshal(map[string]any{"type": "hello", "ok": false,
			"msg": "the KubeFactory server on this host is starting (its access point is up); try again in a minute"})
		_ = s.toClient(b)
		return
	}
	_ = s.toClient(reply)
	var r map[string]any
	if json.Unmarshal(reply, &r) != nil || r["ok"] != true {
		up.Close()
		return
	}
	s.setUp(up)
	go s.fromClient()
	for {
		s.fromServer(up) // returns when the server connection ends
		s.setUp(nil)
		select {
		case <-s.done:
			return
		default:
		}
		s.relay.log("server connection lost; holding the player's connection")
		s.notice("warn", "the KubeFactory server is restarting; your connection is kept and you will see live data again when it is back")
		for {
			select {
			case <-s.done:
				return
			case <-time.After(retryEvery):
			}
			up, reply, err = s.signIn()
			if err != nil {
				continue
			}
			if json.Unmarshal(reply, &r) != nil || r["ok"] != true {
				// the server is back but no longer accepts this token
				_ = s.toClient(reply)
				up.Close()
				return
			}
			s.setUp(up)
			s.notice("ok", "the KubeFactory server is back")
			break
		}
	}
}

func (s *session) setUp(c *websocket.Conn) {
	s.mu.Lock()
	s.up = c
	s.mu.Unlock()
}

// signIn opens a connection to the server and repeats the player's hello.
func (s *session) signIn() (*websocket.Conn, []byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	d := websocket.Dialer{HandshakeTimeout: 3 * time.Second}
	up, _, err := d.DialContext(ctx, s.relay.Upstream, nil)
	if err != nil {
		return nil, nil, err
	}
	up.SetReadLimit(maxServerMessage)
	s.mu.Lock()
	hello := s.hello
	s.mu.Unlock()
	if hello == nil {
		up.Close()
		return nil, nil, context.Canceled
	}
	if err := up.WriteMessage(websocket.TextMessage, hello); err != nil {
		up.Close()
		return nil, nil, err
	}
	up.SetReadDeadline(time.Now().Add(15 * time.Second))
	for {
		_, msg, err := up.ReadMessage()
		if err != nil {
			up.Close()
			return nil, nil, err
		}
		var m map[string]any
		if json.Unmarshal(msg, &m) == nil && m["type"] == "hello" {
			up.SetReadDeadline(time.Time{})
			return up, msg, nil
		}
	}
}

func (s *session) fromServer(up *websocket.Conn) {
	for {
		_, msg, err := up.ReadMessage()
		if err != nil {
			up.Close()
			return
		}
		if s.toClient(msg) != nil {
			up.Close()
			s.close()
			return
		}
	}
}

func (s *session) fromClient() {
	defer s.close()
	for {
		_, msg, err := s.client.ReadMessage()
		if err != nil {
			return
		}
		s.mu.Lock()
		up := s.up
		s.mu.Unlock()
		if up != nil {
			s.uw.Lock()
			up.SetWriteDeadline(time.Now().Add(15 * time.Second))
			err = up.WriteMessage(websocket.TextMessage, msg)
			s.uw.Unlock()
			if err == nil {
				continue
			}
			up.Close() // fromServer notices and starts signing in again
		}
		// the server is away: answer actions so the game does not wait for them
		var m map[string]any
		if json.Unmarshal(msg, &m) == nil && m["op"] == "act" {
			b, _ := json.Marshal(map[string]any{"type": "result", "id": m["id"],
				"result": map[string]any{"ok": false, "msg": "the KubeFactory server is restarting; nothing was done. Try again in a moment."}})
			_ = s.toClient(b)
		}
	}
}

// serve runs the access point until ctx ends.
func (r *Relay) serve(ctx context.Context, listen, cert, key string) error {
	srv := &http.Server{Addr: listen, Handler: r, ReadHeaderTimeout: 10 * time.Second}
	if cert != "" {
		srv.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	}
	go func() {
		<-ctx.Done()
		c, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = srv.Shutdown(c)
	}()
	var err error
	if cert != "" {
		err = srv.ListenAndServeTLS(cert, key)
	} else {
		err = srv.ListenAndServe()
	}
	if err == http.ErrServerClosed {
		return nil
	}
	return err
}
