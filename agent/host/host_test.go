package main

import (
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// fakeDocker answers by the first words of each command; anything unknown fails.
type fakeDocker struct {
	answers map[string]string // prefix -> output; "!" + text fails with that text
	calls   []string
}

func (f *fakeDocker) Run(args ...string) (string, error) {
	cmd := strings.Join(args, " ")
	f.calls = append(f.calls, cmd)
	best := ""
	for p := range f.answers {
		if strings.HasPrefix(cmd, p) && len(p) > len(best) {
			best = p
		}
	}
	if best == "" {
		return "no such object", errors.New("no such object")
	}
	out := f.answers[best]
	if strings.HasPrefix(out, "!") {
		return out[1:], errors.New(out[1:])
	}
	return out, nil
}

func (f *fakeDocker) called(prefix string) bool {
	for _, c := range f.calls {
		if strings.HasPrefix(c, prefix) {
			return true
		}
	}
	return false
}

func newRec(answers map[string]string, healthy bool) (*Reconciler, *fakeDocker) {
	d := &fakeDocker{answers: answers}
	return &Reconciler{cfg: defaultConfig(), docker: d, probe: func(int) bool { return healthy }}, d
}

func TestDockerDownChangesNothing(t *testing.T) {
	r, d := newRec(map[string]string{"version": "!cannot connect"}, true)
	res := r.Check()
	if res.Problem == "" || len(d.calls) != 1 {
		t.Fatalf("want one call and a problem, got %v %q", d.calls, res.Problem)
	}
}

func TestMissingContainerIsCreated(t *testing.T) {
	r, d := newRec(map[string]string{"version": "29.0", "image inspect": "sha256:x", "volume create": "v", "run": "abc"}, true)
	res := r.Check()
	if !d.called("volume create") || !d.called("run -d") || res.Problem != "" {
		t.Fatalf("want volume + run, got %v %q", d.calls, res.Problem)
	}
	run := d.calls[len(d.calls)-1]
	for _, want := range []string{"--label io.kubefactory.managed=host", "-p 127.0.0.1:17666:7666", "--restart unless-stopped", "--server=7666 --listen=0.0.0.0 --demo"} {
		if !strings.Contains(run, want) {
			t.Errorf("run lacks %q: %s", want, run)
		}
	}
	if strings.Contains(run, "docker.sock") {
		t.Errorf("no host mount unless the admin configured one: %s", run)
	}
}

func TestImageNotPulledWhenPullIsOff(t *testing.T) {
	r, d := newRec(map[string]string{"version": "29.0", "volume inspect": "[]"}, true)
	r.cfg.Pull = false
	res := r.Check()
	if d.called("pull") || d.called("run") || !strings.Contains(res.Problem, "pulling is off") {
		t.Fatalf("got %v %q", d.calls, res.Problem)
	}
}

func TestForeignContainerIsLeftAlone(t *testing.T) {
	r, d := newRec(map[string]string{"version": "29.0", "volume inspect": "[]", "container inspect": "||running"}, true)
	res := r.Check()
	if res.Container != "foreign" || d.called("rm") || d.called("run") || d.called("start") || d.called("restart") {
		t.Fatalf("a container the service did not make must not be touched: %v", d.calls)
	}
}

func TestStoppedContainerIsStarted(t *testing.T) {
	r, _ := newRec(nil, true)
	spec := r.specHash()
	r, d := newRec(map[string]string{"version": "29.0", "volume inspect": "[]", "container inspect": "host|" + spec + "|exited", "start": "ok"}, true)
	r.Check()
	if !d.called("start kubefactory-server") || d.called("rm") {
		t.Fatalf("got %v", d.calls)
	}
}

func TestUnhealthyServerRestartsAfterThreeChecks(t *testing.T) {
	r, _ := newRec(nil, false)
	spec := r.specHash()
	r, d := newRec(map[string]string{"version": "29.0", "volume inspect": "[]", "container inspect": "host|" + spec + "|running", "restart": "ok"}, false)
	r.Check()
	r.Check()
	if d.called("restart") {
		t.Fatal("restarted too early")
	}
	res := r.Check()
	if !d.called("restart kubefactory-server") || len(res.Actions) != 1 {
		t.Fatalf("got %v", d.calls)
	}
}

func TestChangedSettingsRecreate(t *testing.T) {
	r, d := newRec(map[string]string{"version": "29.0", "volume inspect": "[]", "container inspect": "host|oldspec|running", "image inspect": "x", "rm -f": "", "run": "id"}, true)
	r.Check()
	if !d.called("rm -f kubefactory-server") || !d.called("run -d") {
		t.Fatalf("got %v", d.calls)
	}
}

func TestValidation(t *testing.T) {
	bad := []func(*Config){
		func(c *Config) { c.Container = "x;rm" },
		func(c *Config) { c.Source = []string{"--server=1"} },
		func(c *Config) { c.Source = []string{"demo"} },
		func(c *Config) { c.Env = []string{"KF_REMOTE_TOKEN=abc"} },
		func(c *Config) { c.Image = "-v /:/host" },
		func(c *Config) { c.Mounts = []Mount{{Host: "/x", Container: "relative"}} },
		func(c *Config) { c.TLSCert = "a.pem" },
	}
	for i, f := range bad {
		c := defaultConfig()
		f(&c)
		if c.validate() == nil {
			t.Errorf("case %d should be refused", i)
		}
	}
	if err := defaultConfig().validate(); err != nil {
		t.Fatal(err)
	}
}

// fakeServer is a KubeFactory server stand-in that can go away and come back on the same address.
type fakeServer struct {
	addr   string
	mu     sync.Mutex
	hellos []string
	srv    *http.Server
	conns  []*websocket.Conn
}

func (f *fakeServer) start(t *testing.T) {
	ln, err := net.Listen("tcp", f.addr)
	if err != nil {
		t.Fatal(err)
	}
	f.addr = ln.Addr().String()
	up := websocket.Upgrader{}
	f.srv = &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := up.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		f.mu.Lock()
		f.conns = append(f.conns, c)
		f.mu.Unlock()
		_, m, err := c.ReadMessage()
		if err != nil {
			return
		}
		f.mu.Lock()
		f.hellos = append(f.hellos, string(m))
		n := len(f.hellos)
		f.mu.Unlock()
		c.WriteMessage(websocket.TextMessage, []byte(`{"type":"hello","ok":true,"role":"operator"}`))
		c.WriteMessage(websocket.TextMessage, []byte(`{"type":"state","state":{"n":`+string(rune('0'+n))+`}}`))
		for {
			if _, _, err := c.ReadMessage(); err != nil {
				return
			}
		}
	})}
	go f.srv.Serve(ln)
}

func (f *fakeServer) stop() {
	f.srv.Close()
	f.mu.Lock()
	for _, c := range f.conns {
		c.Close()
	}
	f.conns = nil
	f.mu.Unlock()
}

func readType(t *testing.T, c *websocket.Conn, want string) map[string]any {
	c.SetReadDeadline(time.Now().Add(10 * time.Second))
	for {
		_, m, err := c.ReadMessage()
		if err != nil {
			t.Fatalf("waiting for %s: %v", want, err)
		}
		var d map[string]any
		json.Unmarshal(m, &d)
		if d["type"] == want {
			return d
		}
	}
}

func TestRelayKeepsPlayersThroughARestart(t *testing.T) {
	up := &fakeServer{addr: "127.0.0.1:0"}
	up.start(t)
	relay := &Relay{Upstream: "ws://" + up.addr}
	ap := httptest.NewServer(relay)
	defer ap.Close()
	c, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(ap.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.WriteMessage(websocket.TextMessage, []byte(`{"op":"hello","token":"t0k","protocol":1}`))
	if h := readType(t, c, "hello"); h["ok"] != true {
		t.Fatalf("hello: %v", h)
	}
	readType(t, c, "state")
	// the server goes away: the player stays connected and is told
	up.stop()
	if n := readType(t, c, "notice"); n["level"] != "warn" {
		t.Fatalf("notice: %v", n)
	}
	c.WriteMessage(websocket.TextMessage, []byte(`{"op":"act","id":7,"action":{"op":"restart"}}`))
	r := readType(t, c, "result")
	if r["id"] != float64(7) || r["result"].(map[string]any)["ok"] != false {
		t.Fatalf("an action while restarting is refused: %v", r)
	}
	// it comes back on the same address: signed in again with the same hello, state flows
	up.start(t)
	if n := readType(t, c, "notice"); n["level"] != "ok" {
		t.Fatalf("notice: %v", n)
	}
	if s := readType(t, c, "state"); s["state"].(map[string]any)["n"] != float64(2) {
		t.Fatalf("state after restart: %v", s)
	}
	up.mu.Lock()
	hellos := append([]string(nil), up.hellos...)
	up.mu.Unlock()
	up.stop()
	if len(hellos) != 2 || hellos[0] != hellos[1] {
		t.Fatalf("the access point signs in again with the player's hello: %v", hellos)
	}
}

func TestStatusPageHasNoToken(t *testing.T) {
	relay := &Relay{Upstream: "ws://127.0.0.1:1", Status: func() Status { return Status{Version: version} }}
	ap := httptest.NewServer(relay)
	defer ap.Close()
	resp, err := http.Get(ap.URL + "/kf-host/status")
	if err != nil {
		t.Fatal(err)
	}
	var s Status
	json.NewDecoder(resp.Body).Decode(&s)
	if s.Version != version {
		t.Fatalf("got %+v", s)
	}
}
