package main

// LiveView providers: Grafana and Tautulli.
//
// A provider is an application the operator has pointed KubeFactory at: a base
// address, a name and (optionally) an API token. This file keeps the registry,
// talks to the two applications' read-only APIs, and hands the game what it
// needs to show: dashboard and panel lists, credential-free links for the
// operator's own browser session, and aggregate media activity.
//
// Rules this code keeps:
//   - the token never leaves this process. It is sealed with the operating
//     system's per-user protection (provider_seal_*.go), never returned by any
//     operation, never placed in a link, never written to a log or an error
//   - only the provider's own address is contacted: redirects are not followed,
//     and nothing here takes a URL from the game other than the saved base
//   - http is accepted for this computer (loopback) or when the operator has
//     said so for that provider; everything else must be https, with normal
//     certificate verification
//   - read-only: Grafana search and dashboard reads, Tautulli get_activity.
//     There is no pass-through for arbitrary commands
//   - bounded: 10 s per request, 4 MiB per answer, one request per provider per
//     second, no retries
//   - a number that is missing is reported as missing, never as zero

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type provider struct {
	ID        string `json:"id"`
	Type      string `json:"type"` // grafana | tautulli
	Name      string `json:"name"`
	BaseURL   string `json:"base_url"`
	AllowHTTP bool   `json:"allow_http"`       // operator accepted plain http to a non-loopback host
	LegacyKey bool   `json:"legacy_query_key"` // Tautulli older than 2.18: key in the query string
	Sealed    string `json:"sealed,omitempty"` // the token, protected by the OS for this user
}

// what the game is allowed to see of a provider
func (p provider) public() map[string]any {
	return map[string]any{"id": p.ID, "type": p.Type, "name": p.Name, "base_url": p.BaseURL, "allow_http": p.AllowHTTP,
		"legacy_query_key": p.LegacyKey, "has_token": p.Sealed != "", "plain_http": strings.HasPrefix(p.BaseURL, "http://")}
}

var (
	provMu   sync.Mutex
	provDir  = "" // set by tests; otherwise the user's config folder
	provLast = map[string]time.Time{}
	provHTTP = &http.Client{Timeout: 10 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
)

const provMaxBody = 4 << 20

func provFile() (string, error) {
	dir := provDir
	if dir == "" {
		dir = os.Getenv("KF_CONFIG_DIR") // tests: keep away from the real settings
	}
	if dir == "" {
		base, err := os.UserConfigDir()
		if err != nil {
			return "", fail("other", "no user settings folder on this system")
		}
		dir = filepath.Join(base, "KubeFactory")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fail("other", "cannot create the settings folder")
	}
	return filepath.Join(dir, "providers.json"), nil
}

func provLoad() ([]provider, error) {
	f, err := provFile()
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(f)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fail("other", "cannot read the provider list")
	}
	var list []provider
	if json.Unmarshal(b, &list) != nil {
		return nil, fail("config", "the provider list is damaged (providers.json)")
	}
	return list, nil
}

func provSave(list []provider) error {
	f, err := provFile()
	if err != nil {
		return err
	}
	b, _ := json.MarshalIndent(list, "", "  ")
	if os.WriteFile(f, b, 0o600) != nil {
		return fail("other", "cannot save the provider list")
	}
	return nil
}

func provFind(id string) (provider, error) {
	list, err := provLoad()
	if err != nil {
		return provider{}, err
	}
	for _, p := range list {
		if p.ID == id {
			return p, nil
		}
	}
	return provider{}, fail("notfound", "that provider is no longer saved")
}

func isLoopbackHost(h string) bool {
	if strings.EqualFold(h, "localhost") {
		return true
	}
	ip := net.ParseIP(h)
	return ip != nil && ip.IsLoopback()
}

// checkBase validates and tidies a provider address. A sub-path (a reverse
// proxy prefix such as https://host/grafana) is kept.
func checkBase(raw string, allowHTTP bool) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Hostname() == "" || (u.Scheme != "https" && u.Scheme != "http") {
		return "", fail("invalid", "the address has to start with https:// (or http:// for this computer)")
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", fail("invalid", "the address must not carry a user name, a query or a fragment")
	}
	if u.Scheme == "http" && !isLoopbackHost(u.Hostname()) && !allowHTTP {
		return "", fail("invalid", "plain http to another computer sends the token unprotected: use https, or accept http for this provider")
	}
	u.Path = strings.TrimRight(u.Path, "/")
	u.RawPath = ""
	return u.String(), nil
}

func provEndpoint(base, path string, q url.Values) string {
	u, _ := url.Parse(base)
	u.Path = strings.TrimRight(u.Path, "/") + path
	u.RawPath = ""
	u.RawQuery = q.Encode()
	return u.String()
}

// provGet reads one JSON document from a provider. Errors never contain the
// request URL (a legacy Tautulli request carries the key in it) or the token.
func provGet(p provider, path string, q url.Values, withToken bool, out any) error {
	provMu.Lock()
	wait := time.Second - time.Since(provLast[p.ID])
	if wait > 0 && wait < time.Second {
		provMu.Unlock()
		time.Sleep(wait)
		provMu.Lock()
	}
	provLast[p.ID] = time.Now()
	provMu.Unlock()

	token := ""
	if withToken && p.Sealed != "" {
		t, err := unseal(p.Sealed)
		if err != nil {
			return fail("auth", "the saved token cannot be read on this account any more: enter it again")
		}
		token = t
	}
	if q == nil {
		q = url.Values{}
	}
	if token != "" && p.Type == "tautulli" && p.LegacyKey {
		q.Set("apikey", token)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, provEndpoint(p.BaseURL, path, q), nil)
	if err != nil {
		return fail("invalid", "the provider address cannot be used")
	}
	req.Header.Set("Accept", "application/json")
	if token != "" {
		if p.Type == "grafana" {
			req.Header.Set("Authorization", "Bearer "+token)
		} else if !p.LegacyKey {
			req.Header.Set("X-Api-Key", token)
		}
	}
	resp, err := provHTTP.Do(req)
	if err != nil {
		var ne net.Error
		if errors.As(err, &ne) && ne.Timeout() {
			return fail("timeout", "%s did not answer in time", p.Name)
		}
		msg := err.Error()
		if strings.Contains(msg, "x509") || strings.Contains(msg, "tls:") || strings.Contains(msg, "certificate") {
			return fail("tls", "%s presented a certificate this computer does not trust", p.Name)
		}
		return fail("unreachable", "%s cannot be reached", p.Name)
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == 401 || resp.StatusCode == 403:
		return fail("auth", "%s refused the token (HTTP %d): it is missing, wrong, expired or lacks permission", p.Name, resp.StatusCode)
	case resp.StatusCode >= 300 && resp.StatusCode < 400:
		return fail("auth", "%s answered with a redirect (usually to a sign-in page): the token was not accepted, or the address needs its sub-path", p.Name)
	case resp.StatusCode == 404:
		return fail("unsupported", "%s has no such API at this address (HTTP 404): check the address and its sub-path", p.Name)
	case resp.StatusCode < 200 || resp.StatusCode >= 300:
		return fail("other", "%s answered HTTP %d", p.Name, resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, provMaxBody+1))
	if err != nil || len(data) > provMaxBody {
		return fail("other", "%s sent an answer that is too large or was cut off", p.Name)
	}
	if json.Unmarshal(data, out) != nil {
		return fail("unsupported", "%s did not answer with JSON: this may not be the application's own address", p.Name)
	}
	return nil
}

func validUID(s string) bool {
	if len(s) == 0 || len(s) > 128 {
		return false
	}
	for _, r := range s {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '-') {
			return false
		}
	}
	return true
}

// ---- Grafana

type grafanaPanel struct {
	ID     int            `json:"id"`
	Title  string         `json:"title"`
	Type   string         `json:"type"`
	Panels []grafanaPanel `json:"panels"`
}

// rows and nested panels flattened, in dashboard order; rows themselves are not panels to show
func flattenPanels(in []grafanaPanel, row string, out *[]map[string]any) {
	for _, p := range in {
		if p.Type == "row" {
			flattenPanels(p.Panels, p.Title, out)
			continue
		}
		if p.ID > 0 {
			*out = append(*out, map[string]any{"id": p.ID, "title": p.Title, "type": p.Type, "row": row})
		}
		flattenPanels(p.Panels, row, out)
	}
}

// grafanaLink builds an address for the operator's own browser session. It
// never carries a credential: the page asks them to sign in if it has to.
func grafanaLink(p provider, uid string, panel int, from, to string, vars map[string]string) (string, error) {
	if !validUID(uid) {
		return "", fail("invalid", "that is not a dashboard id")
	}
	q := url.Values{}
	okRange := func(s string) bool {
		if len(s) == 0 || len(s) > 40 {
			return false
		}
		for _, r := range s {
			if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("-+/:.", r)) {
				return false
			}
		}
		return true
	}
	if from != "" || to != "" {
		if !okRange(from) || !okRange(to) {
			return "", fail("invalid", "that is not a time range Grafana understands (for example now-6h and now)")
		}
		q.Set("from", from)
		q.Set("to", to)
	}
	keys := make([]string, 0, len(vars))
	for k := range vars {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if !validUID(k) {
			return "", fail("invalid", "that is not a dashboard variable name")
		}
		q.Set("var-"+k, vars[k])
	}
	if panel > 0 {
		q.Set("panelId", strconv.Itoa(panel))
		return provEndpoint(p.BaseURL, "/d-solo/"+uid+"/_", q), nil
	}
	q.Set("kiosk", "")
	return provEndpoint(p.BaseURL, "/d/"+uid+"/_", q), nil
}

// ---- Tautulli

// a count that Tautulli sends as a number or as a string; nil when absent or not a number
type optNum struct {
	v  int64
	ok bool
}

func (n *optNum) UnmarshalJSON(b []byte) error {
	s := strings.Trim(strings.TrimSpace(string(b)), `"`)
	if v, err := strconv.ParseInt(s, 10, 64); err == nil && v >= 0 {
		n.v, n.ok = v, true
	}
	return nil // anything else stays "missing": one odd field must not lose the rest
}

func (n *optNum) value() any {
	if n == nil || !n.ok {
		return nil
	}
	return n.v
}

func registerProviders() {
	ops["provider.list"] = func(json.RawMessage) (any, error) {
		list, err := provLoad()
		if err != nil {
			return nil, err
		}
		out := []map[string]any{}
		for _, p := range list {
			out = append(out, p.public())
		}
		return map[string]any{"providers": out, "can_store_tokens": canSeal()}, nil
	}

	ops["provider.save"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			ID        string `json:"id"`
			Type      string `json:"type"`
			Name      string `json:"name"`
			BaseURL   string `json:"base_url"`
			Token     string `json:"token"`       // "" keeps the saved one
			DropToken bool   `json:"drop_token"`  // forget the saved one
			AllowHTTP bool   `json:"allow_http"`
			LegacyKey bool   `json:"legacy_query_key"`
		}](raw)
		if err != nil {
			return nil, err
		}
		if a.Type != "grafana" && a.Type != "tautulli" {
			return nil, fail("invalid", "a provider is Grafana or Tautulli")
		}
		base, err := checkBase(a.BaseURL, a.AllowHTTP)
		if err != nil {
			return nil, err
		}
		if strings.ContainsAny(a.Token, "\r\n\x00") || len(a.Token) > 4096 {
			return nil, fail("invalid", "that is not a token")
		}
		if a.LegacyKey && a.Type != "tautulli" {
			return nil, fail("invalid", "the key-in-address mode exists for old Tautulli servers only")
		}
		name := strings.TrimSpace(a.Name)
		if name == "" {
			u, _ := url.Parse(base)
			name = map[string]string{"grafana": "Grafana", "tautulli": "Tautulli"}[a.Type] + " (" + u.Host + ")"
		}
		list, err := provLoad()
		if err != nil {
			return nil, err
		}
		p := provider{Type: a.Type}
		idx := -1
		for i := range list {
			if list[i].ID == a.ID && a.ID != "" {
				p, idx = list[i], i
			}
		}
		if a.ID != "" && idx < 0 {
			return nil, fail("notfound", "that provider is no longer saved")
		}
		if idx >= 0 && p.BaseURL != base {
			p.Sealed = "" // a token belongs to the address it was entered for
		}
		p.Type, p.Name, p.BaseURL, p.AllowHTTP, p.LegacyKey = a.Type, name, base, a.AllowHTTP, a.LegacyKey
		if a.DropToken {
			p.Sealed = ""
		}
		if a.Token != "" {
			if !canSeal() {
				return nil, fail("unsupported", "this system has no protected storage KubeFactory can use, so a token cannot be kept")
			}
			s, err := seal(a.Token)
			if err != nil {
				return nil, fail("other", "the token could not be stored safely")
			}
			p.Sealed = s
		}
		if idx < 0 {
			b := make([]byte, 6)
			rand.Read(b)
			p.ID = hex.EncodeToString(b)
			list = append(list, p)
		} else {
			list[idx] = p
		}
		if err := provSave(list); err != nil {
			return nil, err
		}
		return p.public(), nil
	}

	ops["provider.remove"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			ID string `json:"id"`
		}](raw)
		if err != nil {
			return nil, err
		}
		list, err := provLoad()
		if err != nil {
			return nil, err
		}
		kept := list[:0]
		for _, p := range list {
			if p.ID != a.ID {
				kept = append(kept, p)
			}
		}
		return map[string]any{}, provSave(kept)
	}

	// Is this really that application, and is the token accepted?
	ops["provider.test"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			ID string `json:"id"`
		}](raw)
		if err != nil {
			return nil, err
		}
		p, err := provFind(a.ID)
		if err != nil {
			return nil, err
		}
		if p.Type == "grafana" {
			var h struct {
				Version  string `json:"version"`
				Database string `json:"database"`
			}
			if err := provGet(p, "/api/health", nil, false, &h); err != nil {
				return nil, err
			}
			if h.Version == "" && h.Database == "" {
				return nil, fail("unsupported", "%s answered, but not like Grafana", p.Name)
			}
			res := map[string]any{"app": "Grafana", "version": h.Version, "token": "none saved"}
			if p.Sealed != "" {
				var s []json.RawMessage
				if err := provGet(p, "/api/search", url.Values{"type": {"dash-db"}, "limit": {"1"}}, true, &s); err != nil {
					return nil, err
				}
				res["token"] = "accepted"
			}
			return res, nil
		}
		if _, err := tautulliActivity(p); err != nil {
			return nil, err
		}
		return map[string]any{"app": "Tautulli", "version": "", "token": "accepted"}, nil
	}

	ops["grafana.dashboards"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			ID    string `json:"id"`
			Query string `json:"query"`
			Page  int    `json:"page"`
		}](raw)
		if err != nil {
			return nil, err
		}
		p, err := provFind(a.ID)
		if err != nil {
			return nil, err
		}
		if p.Type != "grafana" {
			return nil, fail("invalid", "%s is not Grafana", p.Name)
		}
		if a.Page < 1 {
			a.Page = 1
		}
		var found []struct {
			UID    string `json:"uid"`
			Title  string `json:"title"`
			Folder string `json:"folderTitle"`
		}
		q := url.Values{"type": {"dash-db"}, "limit": {"100"}, "page": {strconv.Itoa(a.Page)}, "query": {a.Query}}
		if err := provGet(p, "/api/search", q, true, &found); err != nil {
			return nil, err
		}
		out := []map[string]any{}
		for _, d := range found {
			if validUID(d.UID) {
				out = append(out, map[string]any{"uid": d.UID, "title": d.Title, "folder": d.Folder})
			}
		}
		return map[string]any{"dashboards": out, "page": a.Page, "more": len(found) == 100}, nil
	}

	// The panels of one dashboard. This is the dashboard's layout, not its data.
	ops["grafana.panels"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			ID  string `json:"id"`
			UID string `json:"uid"`
		}](raw)
		if err != nil {
			return nil, err
		}
		p, err := provFind(a.ID)
		if err != nil {
			return nil, err
		}
		if p.Type != "grafana" || !validUID(a.UID) {
			return nil, fail("invalid", "that is not a Grafana dashboard")
		}
		var v struct {
			Dashboard struct {
				Title      string         `json:"title"`
				Panels     []grafanaPanel `json:"panels"`
				Templating struct {
					List []struct {
						Name string `json:"name"`
						Type string `json:"type"`
					} `json:"list"`
				} `json:"templating"`
			} `json:"dashboard"`
		}
		if err := provGet(p, "/api/dashboards/uid/"+a.UID, nil, true, &v); err != nil {
			return nil, err
		}
		panels := []map[string]any{}
		flattenPanels(v.Dashboard.Panels, "", &panels)
		vars := []string{}
		for _, t := range v.Dashboard.Templating.List {
			if validUID(t.Name) && t.Type != "datasource" {
				vars = append(vars, t.Name)
			}
		}
		// a dashboard in a newer layout this code does not read has no classic panel list:
		// the whole dashboard can still be opened, and nothing is made up
		return map[string]any{"title": v.Dashboard.Title, "panels": panels, "variables": vars, "panels_readable": v.Dashboard.Panels != nil}, nil
	}

	ops["grafana.link"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			ID    string            `json:"id"`
			UID   string            `json:"uid"`
			Panel int               `json:"panel"`
			From  string            `json:"from"`
			To    string            `json:"to"`
			Vars  map[string]string `json:"vars"`
		}](raw)
		if err != nil {
			return nil, err
		}
		p, err := provFind(a.ID)
		if err != nil {
			return nil, err
		}
		if p.Type != "grafana" {
			return nil, fail("invalid", "%s is not Grafana", p.Name)
		}
		link, err := grafanaLink(p, a.UID, a.Panel, a.From, a.To, a.Vars)
		if err != nil {
			return nil, err
		}
		u, _ := url.Parse(p.BaseURL)
		return map[string]any{"url": link, "host": u.Host}, nil
	}

	// Aggregate activity only: how many streams and how they are being served.
	// No user, address, title or history is read out of the answer.
	ops["tautulli.activity"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			ID string `json:"id"`
		}](raw)
		if err != nil {
			return nil, err
		}
		p, err := provFind(a.ID)
		if err != nil {
			return nil, err
		}
		if p.Type != "tautulli" {
			return nil, fail("invalid", "%s is not Tautulli", p.Name)
		}
		return tautulliActivity(p)
	}

	// The address of a provider's own web interface, for LiveView.
	ops["provider.link"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			ID string `json:"id"`
		}](raw)
		if err != nil {
			return nil, err
		}
		p, err := provFind(a.ID)
		if err != nil {
			return nil, err
		}
		u, _ := url.Parse(p.BaseURL)
		return map[string]any{"url": p.BaseURL + "/", "host": u.Host}, nil
	}
}

func tautulliActivity(p provider) (map[string]any, error) {
	if p.Sealed == "" {
		return nil, fail("auth", "Tautulli needs its API key (Settings > Web Interface > API)")
	}
	var v struct {
		Response struct {
			Result  string `json:"result"`
			Message string `json:"message"`
			Data    *struct {
				Streams      *optNum `json:"stream_count"`
				DirectPlay   *optNum `json:"stream_count_direct_play"`
				DirectStream *optNum `json:"stream_count_direct_stream"`
				Transcode    *optNum `json:"stream_count_transcode"`
				Total        *optNum `json:"total_bandwidth"`
				LAN          *optNum `json:"lan_bandwidth"`
				WAN          *optNum `json:"wan_bandwidth"`
			} `json:"data"`
		} `json:"response"`
	}
	if err := provGet(p, "/api/v2", url.Values{"cmd": {"get_activity"}}, true, &v); err != nil {
		return nil, err
	}
	if v.Response.Result != "success" || v.Response.Data == nil {
		if strings.Contains(strings.ToLower(v.Response.Message), "api key") || strings.Contains(strings.ToLower(v.Response.Message), "apikey") {
			return nil, fail("auth", "Tautulli did not accept the API key")
		}
		return nil, fail("unsupported", "Tautulli answered, but without activity (is Plex connected to it?)")
	}
	d := v.Response.Data
	// Tautulli reports bandwidth in kbps
	return map[string]any{"streams": d.Streams.value(), "direct_play": d.DirectPlay.value(), "direct_stream": d.DirectStream.value(),
		"transcode": d.Transcode.value(), "total_kbps": d.Total.value(), "lan_kbps": d.LAN.value(), "wan_kbps": d.WAN.value(),
		"at": time.Now().UTC().Format(time.RFC3339), "source": p.Name}, nil
}
