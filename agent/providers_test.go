package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testToken = "glsa_TESTTOKEN_do_not_leak_0123456789"

func provSetup(t *testing.T) {
	t.Helper()
	provDir = t.TempDir()
	provLast = map[string]time.Time{}
	t.Cleanup(func() { provDir = "" })
}

// a Grafana behind a reverse-proxy prefix (/grafana), as many are
func fakeGrafana(t *testing.T) *httptest.Server {
	mux := http.NewServeMux()
	authed := func(w http.ResponseWriter, r *http.Request) bool {
		switch r.Header.Get("Authorization") {
		case "Bearer " + testToken:
			return true
		case "":
			http.Redirect(w, r, "/grafana/login", http.StatusFound)
		default:
			w.WriteHeader(http.StatusUnauthorized)
			w.Write([]byte(`{"message":"invalid API key"}`))
		}
		return false
	}
	mux.HandleFunc("/grafana/api/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"database":"ok","version":"11.2.0"}`))
	})
	mux.HandleFunc("/grafana/api/search", func(w http.ResponseWriter, r *http.Request) {
		if !authed(w, r) {
			return
		}
		w.Write([]byte(`[{"uid":"cont-1","title":"Containers","folderTitle":"Infra"},{"uid":"bad uid!","title":"ignored"},{"uid":"new-layout","title":"New layout"}]`))
	})
	mux.HandleFunc("/grafana/api/dashboards/uid/cont-1", func(w http.ResponseWriter, r *http.Request) {
		if !authed(w, r) {
			return
		}
		w.Write([]byte(`{"dashboard":{"title":"Containers","templating":{"list":[{"name":"namespace","type":"query"},{"name":"ds","type":"datasource"}]},
			"panels":[{"id":1,"title":"CPU","type":"timeseries"},
			          {"id":2,"title":"Workloads","type":"row","panels":[{"id":3,"title":"Memory","type":"gauge"}]},
			          {"id":4,"title":"Network","type":"timeseries"}]}}`))
	})
	mux.HandleFunc("/grafana/api/dashboards/uid/new-layout", func(w http.ResponseWriter, r *http.Request) {
		if !authed(w, r) {
			return
		}
		w.Write([]byte(`{"dashboard":{"title":"New layout","elements":{"panel-1":{}}}}`))
	})
	s := httptest.NewServer(mux)
	t.Cleanup(s.Close)
	return s
}

// values as they come back through JSON
func rows(v any) []map[string]any {
	out := []map[string]any{}
	list, _ := v.([]any)
	for _, x := range list {
		if m, ok := x.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

func num(v any) float64 {
	switch n := v.(type) {
	case float64:
		return n
	case int64:
		return float64(n)
	case int:
		return float64(n)
	}
	return -1
}

func saveProvider(t *testing.T, args map[string]any) map[string]any {
	t.Helper()
	d, e := call(t, "provider.save", args)
	if e != nil {
		t.Fatalf("save: %v", e)
	}
	return d
}

func TestProviderTokenIsSealedAndNeverReturned(t *testing.T) {
	if !canSeal() {
		t.Skip("no protected storage on this system")
	}
	provSetup(t)
	g := fakeGrafana(t)
	p := saveProvider(t, map[string]any{"type": "grafana", "name": "Lab", "base_url": g.URL + "/grafana/", "token": testToken})
	if p["has_token"] != true || p["base_url"] != g.URL+"/grafana" {
		t.Fatalf("unexpected entry: %v", p)
	}
	list, _ := call(t, "provider.list", map[string]any{})
	if b, _ := json.Marshal([]any{p, list}); strings.Contains(string(b), testToken) || strings.Contains(string(b), "sealed") {
		t.Fatalf("an operation returned the token or its sealed form: %s", b)
	}
	disk, _ := os.ReadFile(filepath.Join(provDir, "providers.json"))
	if strings.Contains(string(disk), testToken) {
		t.Fatal("the token is on disk in the clear")
	}
	if !strings.Contains(string(disk), `"sealed"`) {
		t.Fatal("the token was not stored at all")
	}
}

func TestGrafanaBehindASubPath(t *testing.T) {
	if !canSeal() {
		t.Skip("no protected storage on this system")
	}
	provSetup(t)
	g := fakeGrafana(t)
	id := saveProvider(t, map[string]any{"type": "grafana", "base_url": g.URL + "/grafana", "token": testToken})["id"]

	d, e := call(t, "provider.test", map[string]any{"id": id})
	if e != nil || d["version"] != "11.2.0" || d["token"] != "accepted" {
		t.Fatalf("test: %v %v", d, e)
	}
	d, e = call(t, "grafana.dashboards", map[string]any{"id": id})
	if e != nil {
		t.Fatal(e)
	}
	if ds := rows(d["dashboards"]); len(ds) != 2 || ds[0]["uid"] != "cont-1" || ds[0]["folder"] != "Infra" {
		t.Fatalf("dashboards (the one with an unusable id must be dropped): %v", ds)
	}
	d, e = call(t, "grafana.panels", map[string]any{"id": id, "uid": "cont-1"})
	if e != nil {
		t.Fatal(e)
	}
	ps := rows(d["panels"])
	if len(ps) != 3 || ps[1]["title"] != "Memory" || ps[1]["row"] != "Workloads" || num(ps[2]["id"]) != 4 {
		t.Fatalf("panels (rows flattened, the row itself left out): %v", ps)
	}
	if vs, _ := d["variables"].([]any); len(vs) != 1 || vs[0] != "namespace" {
		t.Fatalf("variables: %v", vs)
	}
	// a layout this code cannot read: say so, do not invent panels
	d, e = call(t, "grafana.panels", map[string]any{"id": id, "uid": "new-layout"})
	if e != nil || d["panels_readable"] != false || len(rows(d["panels"])) != 0 {
		t.Fatalf("new layout: %v %v", d, e)
	}
}

func TestGrafanaLinksCarryNoCredential(t *testing.T) {
	if !canSeal() {
		t.Skip("no protected storage on this system")
	}
	provSetup(t)
	g := fakeGrafana(t)
	id := saveProvider(t, map[string]any{"type": "grafana", "base_url": g.URL + "/grafana", "token": testToken})["id"]
	d, e := call(t, "grafana.link", map[string]any{"id": id, "uid": "cont-1", "panel": 3, "from": "now-6h", "to": "now", "vars": map[string]string{"namespace": "shop"}})
	if e != nil {
		t.Fatal(e)
	}
	u := d["url"].(string)
	if !strings.HasPrefix(u, g.URL+"/grafana/d-solo/cont-1/_?") || !strings.Contains(u, "panelId=3") || !strings.Contains(u, "var-namespace=shop") || !strings.Contains(u, "from=now-6h") {
		t.Fatalf("panel link: %s", u)
	}
	if strings.Contains(u, testToken) || strings.Contains(strings.ToLower(u), "token") || strings.Contains(strings.ToLower(u), "auth") {
		t.Fatalf("a credential in a link: %s", u)
	}
	d, _ = call(t, "grafana.link", map[string]any{"id": id, "uid": "cont-1"})
	if u := d["url"].(string); !strings.HasPrefix(u, g.URL+"/grafana/d/cont-1/_?") {
		t.Fatalf("dashboard link: %s", u)
	}
	for _, bad := range []map[string]any{
		{"id": id, "uid": "../../admin"},
		{"id": id, "uid": "cont-1", "from": "now&auth_token=x", "to": "now"},
		{"id": id, "uid": "cont-1", "vars": map[string]string{"a&b": "1"}},
	} {
		if _, e := call(t, "grafana.link", bad); e == nil || e.Kind != "invalid" {
			t.Fatalf("accepted %v", bad)
		}
	}
}

func TestGrafanaRefusalsAreNamedAndLeakNothing(t *testing.T) {
	if !canSeal() {
		t.Skip("no protected storage on this system")
	}
	provSetup(t)
	g := fakeGrafana(t)
	wrong := saveProvider(t, map[string]any{"type": "grafana", "base_url": g.URL + "/grafana", "token": "glsa_WRONG_SECRET_VALUE"})["id"]
	_, e := call(t, "grafana.dashboards", map[string]any{"id": wrong})
	if e == nil || e.Kind != "auth" || strings.Contains(e.Msg, "glsa_WRONG") {
		t.Fatalf("wrong token: %v", e)
	}
	// no token: Grafana redirects to its sign-in page; that is not followed
	none := saveProvider(t, map[string]any{"type": "grafana", "base_url": g.URL + "/grafana"})["id"]
	if _, e = call(t, "grafana.dashboards", map[string]any{"id": none}); e == nil || e.Kind != "auth" {
		t.Fatalf("no token: %v", e)
	}
	// the wrong address (no sub-path): not Grafana's API
	off := saveProvider(t, map[string]any{"type": "grafana", "base_url": g.URL, "token": testToken})["id"]
	if _, e = call(t, "provider.test", map[string]any{"id": off}); e == nil || e.Kind != "unsupported" {
		t.Fatalf("wrong sub-path: %v", e)
	}
	// nothing listening
	dead := saveProvider(t, map[string]any{"type": "grafana", "base_url": "http://127.0.0.1:1", "token": testToken})["id"]
	if _, e = call(t, "provider.test", map[string]any{"id": dead}); e == nil || e.Kind != "unreachable" || strings.Contains(e.Msg, testToken) {
		t.Fatalf("unreachable: %v", e)
	}
}

func TestProviderAddressRules(t *testing.T) {
	provSetup(t)
	for _, bad := range []string{"ftp://host/", "http://grafana.example.org/", "https://user:pw@host/", "https://host/?x=1", "grafana.example.org", ""} {
		if _, e := call(t, "provider.save", map[string]any{"type": "grafana", "base_url": bad}); e == nil || e.Kind != "invalid" {
			t.Fatalf("accepted %q", bad)
		}
	}
	// plain http to another computer only when the operator has said so
	if _, e := call(t, "provider.save", map[string]any{"type": "grafana", "base_url": "http://grafana.example.org/", "allow_http": true}); e != nil {
		t.Fatal(e)
	}
	if _, e := call(t, "provider.save", map[string]any{"type": "plex", "base_url": "https://host/"}); e == nil {
		t.Fatal("accepted an unknown provider type")
	}
	if _, e := call(t, "provider.save", map[string]any{"type": "grafana", "base_url": "https://host/", "legacy_query_key": true}); e == nil {
		t.Fatal("legacy key mode accepted for Grafana")
	}
}

func fakeTautulli(t *testing.T, body string, legacy bool, sawKeyIn *string) *httptest.Server {
	const key = "tautulli-KEY-do-not-leak"
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/tautulli/api/v2" || r.URL.Query().Get("cmd") != "get_activity" {
			w.WriteHeader(404)
			return
		}
		got := ""
		if r.Header.Get("X-Api-Key") == key {
			got = "header"
		} else if r.URL.Query().Get("apikey") == key {
			got = "query"
		}
		*sawKeyIn = got
		if got == "" || (got == "query") != legacy {
			w.Write([]byte(`{"response":{"result":"error","message":"Invalid apikey","data":{}}}`))
			return
		}
		w.Write([]byte(body))
	}))
	t.Cleanup(s.Close)
	return s
}

func TestTautulliAggregateActivityOnly(t *testing.T) {
	if !canSeal() {
		t.Skip("no protected storage on this system")
	}
	provSetup(t)
	saw := ""
	// counts as strings and numbers, one field absent, and viewer details that must not come through
	body := `{"response":{"result":"success","data":{"stream_count":"3","stream_count_direct_play":1,"stream_count_direct_stream":"0",
		"stream_count_transcode":2,"total_bandwidth":18250,"lan_bandwidth":"6200",
		"sessions":[{"user":"alice","ip_address":"203.0.113.9","full_title":"Some Film","friendly_name":"Alice"}]}}}`
	s := fakeTautulli(t, body, false, &saw)
	id := saveProvider(t, map[string]any{"type": "tautulli", "base_url": s.URL + "/tautulli", "token": "tautulli-KEY-do-not-leak"})["id"]
	d, e := call(t, "tautulli.activity", map[string]any{"id": id})
	if e != nil {
		t.Fatal(e)
	}
	if saw != "header" {
		t.Fatalf("the key went in the %q, not the header", saw)
	}
	if num(d["streams"]) != 3 || num(d["direct_stream"]) != 0 || num(d["transcode"]) != 2 || num(d["lan_kbps"]) != 6200 || num(d["total_kbps"]) != 18250 {
		t.Fatalf("counts: %v", d)
	}
	if d["wan_kbps"] != nil {
		t.Fatalf("a missing number was reported as %v, not as missing", d["wan_kbps"])
	}
	b, _ := json.Marshal(d)
	for _, private := range []string{"alice", "Alice", "203.0.113.9", "Some Film", "tautulli-KEY"} {
		if strings.Contains(string(b), private) {
			t.Fatalf("viewer detail or key in the result: %s", b)
		}
	}
}

func TestTautulliLegacyKeyAndFailures(t *testing.T) {
	if !canSeal() {
		t.Skip("no protected storage on this system")
	}
	provSetup(t)
	saw := ""
	s := fakeTautulli(t, `{"response":{"result":"success","data":{"stream_count":"0"}}}`, true, &saw)
	base := s.URL + "/tautulli"
	// header mode against an old server: refused as a key problem, key not echoed
	id := saveProvider(t, map[string]any{"type": "tautulli", "base_url": base, "token": "tautulli-KEY-do-not-leak"})["id"]
	_, e := call(t, "tautulli.activity", map[string]any{"id": id})
	if e == nil || e.Kind != "auth" || strings.Contains(e.Msg, "tautulli-KEY") {
		t.Fatalf("old server, header mode: %v", e)
	}
	// legacy mode, chosen explicitly
	id = saveProvider(t, map[string]any{"id": id, "type": "tautulli", "base_url": base, "legacy_query_key": true})["id"]
	d, e := call(t, "tautulli.activity", map[string]any{"id": id})
	if e != nil || saw != "query" || num(d["streams"]) != 0 || d["transcode"] != nil {
		t.Fatalf("legacy mode: %v %v (key in %q)", d, e, saw)
	}
	// no key at all
	none := saveProvider(t, map[string]any{"type": "tautulli", "base_url": base})["id"]
	if _, e = call(t, "tautulli.activity", map[string]any{"id": none}); e == nil || e.Kind != "auth" {
		t.Fatalf("no key: %v", e)
	}
	// not Tautulli at this address
	other := saveProvider(t, map[string]any{"type": "tautulli", "base_url": s.URL, "token": "tautulli-KEY-do-not-leak"})["id"]
	if _, e = call(t, "tautulli.activity", map[string]any{"id": other}); e == nil || e.Kind != "unsupported" {
		t.Fatalf("wrong address: %v", e)
	}
	// a changed address drops the token that was entered for the old one
	moved := saveProvider(t, map[string]any{"id": id, "type": "tautulli", "base_url": "https://elsewhere.example.org/tautulli"})
	if moved["has_token"] != false {
		t.Fatal("the token followed the provider to a different address")
	}
}
