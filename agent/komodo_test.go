package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	testKomodoKey    = "K-testkey-do-not-leak-111"
	testKomodoSecret = "S-testsecret-do-not-leak-222"
)

// A fake Komodo Core: POST /read only, the request shape and headers of
// komodo_client's request.rs, and the list shapes of its entities.
// newNames: answer the 2.3 request name ListAllContainers; otherwise only the
// old ListAllDockerContainers, rejecting the new one as unknown (422).
func fakeKomodo(t *testing.T, seen *[]string, newNames bool) *httptest.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/read", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.Header.Get("content-type") != "application/json" {
			w.WriteHeader(405)
			return
		}
		if r.Header.Get("x-api-key") != testKomodoKey || r.Header.Get("x-api-secret") != testKomodoSecret {
			w.WriteHeader(401)
			w.Write([]byte(`{"error":"invalid key ` + r.Header.Get("x-api-key") + `"}`))
			return
		}
		b, _ := io.ReadAll(r.Body)
		var req struct {
			Type   string         `json:"type"`
			Params map[string]any `json:"params"`
		}
		json.Unmarshal(b, &req)
		*seen = append(*seen, req.Type)
		switch req.Type {
		case "GetVersion":
			w.Write([]byte(`{"version":"1.19.5"}`))
		case "ListServers":
			w.Write([]byte(`[{"id":"s1","name":"pve-docker-1","tags":[],"info":{"state":"Ok","region":"","address":"https://10.0.0.11:8120"}},
				{"id":"s2","name":"nas","tags":[],"info":{"state":"NotOk","region":""}}]`))
		case "ListAllContainers", "ListAllDockerContainers":
			if (req.Type == "ListAllContainers") != newNames {
				w.WriteHeader(422)
				w.Write([]byte(`{"error":"unknown variant"}`))
				return
			}
			// Komodo 2.3 pages this list: without "limit": 0 only the first page
			// (default_pagination_limit, here 1) comes back.
			all := []string{`{"server_id":"s1","name":"immich-server","id":"abc","image":"ghcr.io/immich-app/immich-server:release","state":"running","status":"Up 3 days","ports":[{"IP":"0.0.0.0","PrivatePort":2283,"PublicPort":2283,"Type":"tcp"}],"networks":["immich"]}`,
				`{"server_id":"s1","name":"immich-postgres","id":"def","image":"tensorchord/pgvecto-rs:pg14-v0.2.0","state":"exited","status":"Exited (1) 2 hours ago"}`}
			if l, ok := req.Params["limit"].(float64); !ok || l != 0 {
				all = all[:1]
			}
			w.Write([]byte("[" + strings.Join(all, ",") + "]"))
		case "GetContainerLog":
			// Komodo checks Read plus the Logs permission on the server
			if req.Params["server"] == "s2" {
				w.WriteHeader(500)
				w.Write([]byte(`{"error":"User does not have required permissions on this Server. Must have at least Read permissions, as well as these specific permissions: [Logs]","trace":[]}`))
				return
			}
			if req.Params["server"] != "s1" || req.Params["container"] != "immich-server" || req.Params["tail"] != float64(5000) {
				w.WriteHeader(400)
				return
			}
			w.Write([]byte(`{"stage":"Get Container Log","command":"docker logs immich-server --tail 5000","stdout":"ready on :2283\n","stderr":"warn: slow disk\n","success":true,"start_ts":1,"end_ts":2}`))
		default:
			w.WriteHeader(400)
		}
	})
	mux.HandleFunc("/write", func(w http.ResponseWriter, r *http.Request) { *seen = append(*seen, "WRITE"); w.WriteHeader(200) })
	mux.HandleFunc("/execute", func(w http.ResponseWriter, r *http.Request) { *seen = append(*seen, "EXECUTE"); w.WriteHeader(200) })
	s := httptest.NewServer(mux)
	t.Cleanup(s.Close)
	return s
}

func TestKomodo(t *testing.T) {
	provSetup(t)
	ops = map[string]handler{}
	registerAll()
	var seen []string
	f := fakeKomodo(t, &seen, false)
	if !canSeal() {
		// no protected storage here (Linux, macOS today): a key must be refused, never kept in the clear
		if _, e := call(t, "komodo.save", map[string]any{"base_url": f.URL, "key": testKomodoKey, "secret": testKomodoSecret}); e == nil || e.Kind != "unsupported" {
			t.Fatalf("a key was accepted without protected storage: %v", e)
		}
		t.Skip("keys are refused on this system, as checked; the rest needs protected storage")
	}

	if _, e := call(t, "komodo.save", map[string]any{"base_url": f.URL, "key": testKomodoKey}); e == nil {
		t.Fatal("a key without its secret was accepted")
	}
	c, e := call(t, "komodo.save", map[string]any{"name": "Home Komodo", "base_url": f.URL, "key": testKomodoKey, "secret": testKomodoSecret})
	if e != nil || c["has_key"] != true {
		t.Fatalf("save: %v %v", c, e)
	}
	b, _ := json.Marshal(c)
	disk, _ := os.ReadFile(filepath.Join(provDir, "komodo.json"))
	for _, s := range []string{testKomodoKey, testKomodoSecret} {
		if strings.Contains(string(b), s) || strings.Contains(string(disk), s) {
			t.Fatal("the key or secret is visible")
		}
	}
	v, e := call(t, "komodo.test", map[string]any{"id": c["id"]})
	if e != nil || v["version"] != "1.19.5" {
		t.Fatalf("test: %v %v", v, e)
	}
	st, e := call(t, "komodo.state", map[string]any{"id": c["id"]})
	if e != nil || len(st["servers"].([]any)) != 2 || len(st["containers"].([]any)) != 2 {
		t.Fatalf("state: %v %v", st, e)
	}
	for _, s := range seen {
		if s == "WRITE" || s == "EXECUTE" {
			t.Fatal("something other than /read was called")
		}
	}
	// an older Core: the new name is refused, the old one answers
	if strings.Join(seen, ",") != "GetVersion,ListServers,ListAllContainers,ListAllDockerContainers" {
		t.Fatalf("requests: %v", seen)
	}
	// a 2.3 Core: the new name answers and the old one is not sent
	var seen23 []string
	f23 := fakeKomodo(t, &seen23, true)
	c23, e := call(t, "komodo.save", map[string]any{"name": "Komodo 2.3", "base_url": f23.URL, "key": testKomodoKey, "secret": testKomodoSecret})
	if e != nil {
		t.Fatal(e)
	}
	st, e = call(t, "komodo.state", map[string]any{"id": c23["id"]})
	if e != nil || len(st["containers"].([]any)) != 2 || strings.Join(seen23, ",") != "ListServers,ListAllContainers" {
		t.Fatalf("2.3 state: %v %v %v", st, e, seen23)
	}
	// a container's log: both streams, the tail capped at Komodo's 5000
	lg, e := call(t, "komodo.logs", map[string]any{"id": c23["id"], "server": "s1", "container": "immich-server", "tail": 99999})
	if e != nil || lg["text"] != "ready on :2283\n--- stderr ---\nwarn: slow disk" {
		t.Fatalf("logs: %v %v", lg, e)
	}
	for _, c := range [][3]string{{"", "", "(no log output)"}, {"", "only err\n", "only err"}, {"only out\n", "", "only out"}} {
		if got := komodoLogText(c[0], c[1]); got != c[2] {
			t.Fatalf("log text %q %q: %q", c[0], c[1], got)
		}
	}
	// a key without the Logs permission: said plainly, as an auth problem
	if _, e = call(t, "komodo.logs", map[string]any{"id": c23["id"], "server": "s2", "container": "paperless"}); e == nil || e.Kind != "auth" || !strings.Contains(e.Msg, "Logs permission") {
		t.Fatalf("logs without permission: %v", e)
	}
	call(t, "komodo.remove", map[string]any{"id": c23["id"]})
	// the whitelist holds even inside the package
	cc, _ := komodoFind(c["id"].(string))
	var x any
	if err := komodoRead(cc, "DeleteServer", nil, &x); err == nil {
		t.Fatal("a non-read request type was sent")
	}
	// a wrong key: refused, and the key the server echoes does not reach the game
	_, e = call(t, "komodo.save", map[string]any{"id": c["id"], "base_url": f.URL, "key": "K-wrong-secret-value", "secret": "S-x"})
	if e != nil {
		t.Fatal(e)
	}
	_, e = call(t, "komodo.test", map[string]any{"id": c["id"]})
	if e == nil || e.Kind != "auth" || strings.Contains(e.Msg, "K-wrong-secret-value") {
		t.Fatalf("wrong key: %v", e)
	}
	// plain http to another computer needs the operator's say-so
	if _, e = call(t, "komodo.save", map[string]any{"base_url": "http://10.0.0.5:9120", "key": "a", "secret": "b"}); e == nil {
		t.Fatal("plain http to another computer accepted")
	}
	call(t, "komodo.remove", map[string]any{"id": c["id"]})
	l, _ := call(t, "komodo.list", map[string]any{})
	if len(l["connections"].([]any)) != 0 {
		t.Fatalf("remove: %v", l)
	}
}
