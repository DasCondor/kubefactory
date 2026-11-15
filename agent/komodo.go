package main

// Komodo (komo.do): a read-only view of every server and container a Komodo
// Core manages, without KubeFactory touching the Docker hosts themselves.
//
// Komodo Core's API is RPC over HTTP: POST <address>/read with
// {"type": <request>, "params": {...}} and the headers x-api-key and
// x-api-secret (komodo_client, request.rs). This file sends only the read
// requests in komodoReads, never /write or /execute, so even a key with
// write rights cannot change anything through KubeFactory. A read-only key
// in Komodo is still the better choice.
//
// The key and secret are sealed like provider tokens and never returned.
// Bounded: 15 s per request, 8 MiB per answer, no redirects, no retries.

import (
	"bytes"
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
	"strings"
	"time"
)

var komodoReads = map[string]bool{"GetVersion": true, "ListServers": true, "ListAllDockerContainers": true}

type komodoConn struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	BaseURL   string `json:"base_url"`
	AllowHTTP bool   `json:"allow_http"`
	Sealed    string `json:"sealed,omitempty"` // {"k": key, "s": secret}, sealed
}

func (c komodoConn) public() map[string]any {
	return map[string]any{"id": c.ID, "name": c.Name, "base_url": c.BaseURL, "allow_http": c.AllowHTTP, "has_key": c.Sealed != ""}
}

var komodoHTTP = &http.Client{Timeout: 15 * time.Second,
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

func komodoFile() (string, error) {
	f, err := provFile()
	if err != nil {
		return "", err
	}
	return filepath.Join(filepath.Dir(f), "komodo.json"), nil
}

func komodoLoad() ([]komodoConn, error) {
	f, err := komodoFile()
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(f)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fail("other", "cannot read the Komodo connections")
	}
	var list []komodoConn
	if json.Unmarshal(b, &list) != nil {
		return nil, fail("config", "the Komodo connection list is damaged (komodo.json)")
	}
	return list, nil
}

func komodoSave(list []komodoConn) error {
	f, err := komodoFile()
	if err != nil {
		return err
	}
	b, _ := json.MarshalIndent(list, "", "  ")
	if os.WriteFile(f, b, 0o600) != nil {
		return fail("other", "cannot save the Komodo connections")
	}
	return nil
}

func komodoFind(id string) (komodoConn, error) {
	list, err := komodoLoad()
	if err != nil {
		return komodoConn{}, err
	}
	for _, c := range list {
		if c.ID == id {
			return c, nil
		}
	}
	return komodoConn{}, fail("notfound", "that Komodo connection is no longer saved")
}

// komodoRead sends one whitelisted read request.
func komodoRead(c komodoConn, typ string, params map[string]any, out any) error {
	if !komodoReads[typ] {
		return fail("invalid", "not a read request KubeFactory sends")
	}
	if c.Sealed == "" {
		return fail("auth", "%s needs its API key and secret", c.Name)
	}
	raw, err := unseal(c.Sealed)
	if err != nil {
		return fail("auth", "the saved key cannot be read on this account any more: enter it again")
	}
	var ks struct {
		K string `json:"k"`
		S string `json:"s"`
	}
	if json.Unmarshal([]byte(raw), &ks) != nil {
		return fail("auth", "the saved key is damaged: enter it again")
	}
	if params == nil {
		params = map[string]any{}
	}
	body, _ := json.Marshal(map[string]any{"type": typ, "params": params})
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, provEndpoint(c.BaseURL, "/read", nil), bytes.NewReader(body))
	if err != nil {
		return fail("invalid", "the Komodo address cannot be used")
	}
	req.Header.Set("content-type", "application/json")
	req.Header.Set("x-api-key", ks.K)
	req.Header.Set("x-api-secret", ks.S)
	resp, err := komodoHTTP.Do(req)
	if err != nil {
		var ne net.Error
		if errors.As(err, &ne) && ne.Timeout() {
			return fail("timeout", "%s did not answer in time", c.Name)
		}
		msg := err.Error()
		if strings.Contains(msg, "x509") || strings.Contains(msg, "tls:") || strings.Contains(msg, "certificate") {
			return fail("tls", "%s presented a certificate this computer does not trust", c.Name)
		}
		return fail("unreachable", "%s cannot be reached", c.Name)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20+1))
	if err != nil || len(data) > 8<<20 {
		return fail("other", "%s sent an answer that is too large or was cut off", c.Name)
	}
	switch {
	case resp.StatusCode == 401 || resp.StatusCode == 403:
		return fail("auth", "%s refused the API key (HTTP %d)", c.Name, resp.StatusCode)
	case resp.StatusCode >= 300 && resp.StatusCode < 400:
		return fail("unsupported", "%s answered with a redirect: check the address", c.Name)
	case resp.StatusCode == 404:
		return fail("unsupported", "%s has no Komodo API at this address (HTTP 404)", c.Name)
	case resp.StatusCode < 200 || resp.StatusCode >= 300:
		detail := strings.Join(strings.Fields(string(data)), " ")
		if len(detail) > 200 {
			detail = detail[:200] + "..."
		}
		detail = strings.ReplaceAll(strings.ReplaceAll(detail, ks.K, "[key]"), ks.S, "[secret]")
		return fail("other", "%s answered HTTP %d: %s", c.Name, resp.StatusCode, detail)
	}
	if json.Unmarshal(data, out) != nil {
		return fail("unsupported", "%s did not answer with JSON: this may not be Komodo Core", c.Name)
	}
	return nil
}

func registerKomodo() {
	ops["komodo.list"] = func(json.RawMessage) (any, error) {
		list, err := komodoLoad()
		if err != nil {
			return nil, err
		}
		out := []map[string]any{}
		for _, c := range list {
			out = append(out, c.public())
		}
		return map[string]any{"connections": out, "can_store_keys": canSeal()}, nil
	}

	ops["komodo.save"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			ID        string `json:"id"`
			Name      string `json:"name"`
			BaseURL   string `json:"base_url"`
			Key       string `json:"key"`    // "" keeps the saved pair
			Secret    string `json:"secret"`
			AllowHTTP bool   `json:"allow_http"`
		}](raw)
		if err != nil {
			return nil, err
		}
		base, err := checkBase(a.BaseURL, a.AllowHTTP)
		if err != nil {
			return nil, err
		}
		for _, v := range []string{a.Key, a.Secret} {
			if strings.ContainsAny(v, "\r\n\x00") || len(v) > 4096 {
				return nil, fail("invalid", "that is not an API key")
			}
		}
		if (a.Key == "") != (a.Secret == "") {
			return nil, fail("invalid", "enter both the API key and its secret")
		}
		list, err := komodoLoad()
		if err != nil {
			return nil, err
		}
		c := komodoConn{}
		idx := -1
		for i := range list {
			if list[i].ID == a.ID && a.ID != "" {
				c, idx = list[i], i
			}
		}
		if a.ID != "" && idx < 0 {
			return nil, fail("notfound", "that Komodo connection is no longer saved")
		}
		if idx >= 0 && c.BaseURL != base {
			c.Sealed = "" // a key belongs to the address it was entered for
		}
		c.Name, c.BaseURL, c.AllowHTTP = strings.TrimSpace(a.Name), base, a.AllowHTTP
		if c.Name == "" {
			u, _ := url.Parse(base)
			c.Name = "Komodo (" + u.Host + ")"
		}
		if a.Key != "" {
			if !canSeal() {
				return nil, fail("unsupported", "this system has no protected storage KubeFactory can use, so a key cannot be kept")
			}
			pair, _ := json.Marshal(map[string]string{"k": a.Key, "s": a.Secret})
			s, err := seal(string(pair))
			if err != nil {
				return nil, fail("other", "the key could not be stored safely")
			}
			c.Sealed = s
		}
		if c.Sealed == "" {
			return nil, fail("invalid", "enter the API key and secret (Komodo: Settings > API keys; a read-only key is enough)")
		}
		if idx < 0 {
			b := make([]byte, 6)
			rand.Read(b)
			c.ID = hex.EncodeToString(b)
			list = append(list, c)
		} else {
			list[idx] = c
		}
		if err := komodoSave(list); err != nil {
			return nil, err
		}
		return c.public(), nil
	}

	ops["komodo.remove"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			ID string `json:"id"`
		}](raw)
		if err != nil {
			return nil, err
		}
		list, err := komodoLoad()
		if err != nil {
			return nil, err
		}
		kept := list[:0]
		for _, c := range list {
			if c.ID != a.ID {
				kept = append(kept, c)
			}
		}
		return map[string]any{}, komodoSave(kept)
	}

	ops["komodo.test"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			ID string `json:"id"`
		}](raw)
		if err != nil {
			return nil, err
		}
		c, err := komodoFind(a.ID)
		if err != nil {
			return nil, err
		}
		var v struct {
			Version string `json:"version"`
		}
		if err := komodoRead(c, "GetVersion", nil, &v); err != nil {
			return nil, err
		}
		return map[string]any{"version": v.Version}, nil
	}

	// Every server and every container, in one answer for the game to normalise.
	ops["komodo.state"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			ID string `json:"id"`
		}](raw)
		if err != nil {
			return nil, err
		}
		c, err := komodoFind(a.ID)
		if err != nil {
			return nil, err
		}
		var servers []json.RawMessage
		if err := komodoRead(c, "ListServers", nil, &servers); err != nil {
			return nil, err
		}
		// Komodo 2.3 pages this list (Core's default_pagination_limit, 30 unless
		// configured) and returns only the first page when no limit is given.
		// limit 0 asks for every container; older Cores ignore the field.
		var containers []json.RawMessage
		if err := komodoRead(c, "ListAllDockerContainers", map[string]any{"limit": 0}, &containers); err != nil {
			return nil, err
		}
		return map[string]any{"servers": servers, "containers": containers}, nil
	}
}
