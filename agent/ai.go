package main

// Foreman's AI providers: Ollama, LM Studio, OpenAI, Anthropic Claude and any
// OpenAI-compatible endpoint the operator names.
//
// The game sends a question with the context it has already chosen, bounded
// and redacted; this file adds the provider's key, sends it to the provider's
// own address and hands back the text. The model's answer is untrusted text:
// the game parses it, validates any proposed action against its own tool
// registry and runs it only through the normal approval path. Nothing here
// executes anything.
//
// Rules this code keeps, as for the LiveView providers (providers.go):
//   - the key never leaves this process: sealed with the operating system's
//     per-user protection, never returned, never in an error or a log
//   - only the provider's saved address is contacted; redirects are not followed
//   - a provider on another computer is a cloud provider: nothing is sent to it
//     until the operator has said so for that provider (cloud_ok)
//   - bounded: 48 KiB of question, 8192 tokens of answer, 120 s, 2 MiB of reply,
//     one request at a time per provider, no retries

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
	"sort"
	"strings"
	"sync"
	"time"
)

type aiProvider struct {
	ID        string `json:"id"`
	Type      string `json:"type"` // ollama | lmstudio | openai | claude | custom
	Name      string `json:"name"`
	BaseURL   string `json:"base_url"`
	Model     string `json:"model"`
	AllowHTTP bool   `json:"allow_http"`
	CloudOK   bool   `json:"cloud_ok"` // the operator agreed that questions leave this computer
	Sealed    string `json:"sealed,omitempty"`
}

var aiDefaults = map[string][2]string{ // type -> {base address, model}
	"ollama":   {"http://localhost:11434", ""},
	"lmstudio": {"http://localhost:1234", ""},
	"openai":   {"https://api.openai.com", ""},
	"claude":   {"https://api.anthropic.com", "claude-opus-5-5"},
	"custom":   {"", ""},
}

var aiNames = map[string]string{"ollama": "Ollama", "lmstudio": "LM Studio", "openai": "OpenAI", "claude": "Claude", "custom": "Custom endpoint"}

func (p aiProvider) local() bool {
	u, err := url.Parse(p.BaseURL)
	return err == nil && isLoopbackHost(u.Hostname())
}

func (p aiProvider) public() map[string]any {
	return map[string]any{"id": p.ID, "type": p.Type, "name": p.Name, "base_url": p.BaseURL, "model": p.Model,
		"allow_http": p.AllowHTTP, "cloud_ok": p.CloudOK, "local": p.local(), "has_key": p.Sealed != ""}
}

var (
	aiMu   sync.Mutex
	aiBusy = map[string]bool{}
	aiHTTP = &http.Client{Timeout: 120 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
)

const (
	aiMaxQuestion = 48 << 10
	aiMaxTokens   = 8192
	aiMaxReply    = 2 << 20
)

func aiFile() (string, error) {
	f, err := provFile()
	if err != nil {
		return "", err
	}
	return filepath.Join(filepath.Dir(f), "ai-providers.json"), nil
}

func aiLoad() ([]aiProvider, error) {
	f, err := aiFile()
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(f)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fail("other", "cannot read the AI provider list")
	}
	var list []aiProvider
	if json.Unmarshal(b, &list) != nil {
		return nil, fail("config", "the AI provider list is damaged (ai-providers.json)")
	}
	return list, nil
}

func aiSave(list []aiProvider) error {
	f, err := aiFile()
	if err != nil {
		return err
	}
	b, _ := json.MarshalIndent(list, "", "  ")
	if os.WriteFile(f, b, 0o600) != nil {
		return fail("other", "cannot save the AI provider list")
	}
	return nil
}

func aiFind(id string) (aiProvider, error) {
	list, err := aiLoad()
	if err != nil {
		return aiProvider{}, err
	}
	for _, p := range list {
		if p.ID == id {
			return p, nil
		}
	}
	return aiProvider{}, fail("notfound", "that AI provider is no longer saved")
}

func validModel(s string) bool {
	if len(s) > 200 {
		return false
	}
	for _, r := range s {
		if r < 0x21 || r > 0x7e {
			return false
		}
	}
	return true
}

// aiScrub removes the key from text that came back from a provider.
func aiScrub(s, key string) string {
	if key != "" {
		s = strings.ReplaceAll(s, key, "[key]")
	}
	s = strings.Join(strings.Fields(s), " ")
	if len(s) > 240 {
		s = s[:240] + "..."
	}
	return s
}

// aiDo sends one request and decodes the JSON answer into out.
func aiDo(p aiProvider, method, path string, body any, out any) error {
	key := ""
	if p.Sealed != "" {
		k, err := unseal(p.Sealed)
		if err != nil {
			return fail("auth", "the saved key cannot be read on this account any more: enter it again")
		}
		key = k
	}
	if !p.local() && !p.CloudOK {
		return fail("consent", "%s is not on this computer: allow sending questions to it first", p.Name)
	}
	if p.Type == "openai" || p.Type == "claude" {
		if key == "" {
			return fail("auth", "%s needs an API key", p.Name)
		}
	}
	var rdr io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rdr = bytes.NewReader(b)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, provEndpoint(p.BaseURL, path, nil), rdr)
	if err != nil {
		return fail("invalid", "the provider address cannot be used")
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if p.Type == "claude" {
		req.Header.Set("x-api-key", key)
		req.Header.Set("anthropic-version", "2026-10-21")
		if claudeOfficial(p) && strings.HasSuffix(path, "/messages") {
			req.Header.Set("anthropic-beta", "server-side-fallback-2026-07-01")
		}
	} else if key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	resp, err := aiHTTP.Do(req)
	if err != nil {
		var ne net.Error
		if errors.As(err, &ne) && ne.Timeout() {
			return fail("timeout", "%s did not answer in time", p.Name)
		}
		msg := err.Error()
		if strings.Contains(msg, "x509") || strings.Contains(msg, "tls:") || strings.Contains(msg, "certificate") {
			return fail("tls", "%s presented a certificate this computer does not trust", p.Name)
		}
		return fail("unreachable", "%s cannot be reached: is it running?", p.Name)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, aiMaxReply+1))
	if err != nil || len(data) > aiMaxReply {
		return fail("other", "%s sent an answer that is too large or was cut off", p.Name)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var e struct {
			Error json.RawMessage `json:"error"`
		}
		detail := ""
		if json.Unmarshal(data, &e) == nil && len(e.Error) > 0 {
			var obj struct {
				Message string `json:"message"`
			}
			if json.Unmarshal(e.Error, &obj) == nil && obj.Message != "" {
				detail = obj.Message
			} else {
				var s string
				if json.Unmarshal(e.Error, &s) == nil {
					detail = s
				}
			}
		}
		if detail != "" {
			detail = ": " + aiScrub(detail, key)
		}
		switch {
		case resp.StatusCode == 401 || resp.StatusCode == 403:
			return fail("auth", "%s refused the key (HTTP %d)%s", p.Name, resp.StatusCode, detail)
		case resp.StatusCode == 429:
			return fail("limit", "%s is rate-limiting or out of quota (HTTP 429)%s", p.Name, detail)
		case resp.StatusCode >= 300 && resp.StatusCode < 400:
			return fail("unsupported", "%s answered with a redirect: check the address", p.Name)
		case resp.StatusCode == 404:
			return fail("unsupported", "%s has no such model or API at this address (HTTP 404)%s", p.Name, detail)
		}
		return fail("other", "%s answered HTTP %d%s", p.Name, resp.StatusCode, detail)
	}
	if json.Unmarshal(data, out) != nil {
		return fail("unsupported", "%s did not answer with JSON: this may not be an AI endpoint", p.Name)
	}
	return nil
}

func claudeOfficial(p aiProvider) bool {
	u, err := url.Parse(p.BaseURL)
	return err == nil && strings.EqualFold(u.Hostname(), "api.anthropic.com")
}

type aiAnswer struct {
	Text   string `json:"text"`
	Model  string `json:"model"`
	In     int    `json:"input_tokens"`
	Out    int    `json:"output_tokens"`
	Stop   string `json:"stop"`
	Cloud  bool   `json:"cloud"`
	Millis int64  `json:"ms"`
}

func aiAsk(p aiProvider, system, question string, maxTokens int) (aiAnswer, error) {
	start := time.Now()
	ans := aiAnswer{Cloud: !p.local()}
	if p.Type == "claude" {
		body := map[string]any{"model": p.Model, "max_tokens": maxTokens, "system": system,
			"messages": []map[string]any{{"role": "user", "content": question}}}
		if claudeOfficial(p) {
			body["fallbacks"] = "default"
		}
		var r struct {
			Model   string `json:"model"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
			StopReason string `json:"stop_reason"`
			Usage      struct {
				In  int `json:"input_tokens"`
				Out int `json:"output_tokens"`
			} `json:"usage"`
		}
		if err := aiDo(p, http.MethodPost, "/v1/messages", body, &r); err != nil {
			return ans, err
		}
		if r.StopReason == "refusal" {
			return ans, fail("refused", "%s declined to answer this question", p.Name)
		}
		var parts []string
		for _, c := range r.Content {
			if c.Type == "text" {
				parts = append(parts, c.Text)
			}
		}
		ans.Text, ans.Model, ans.In, ans.Out, ans.Stop = strings.Join(parts, ""), r.Model, r.Usage.In, r.Usage.Out, r.StopReason
	} else {
		body := map[string]any{"model": p.Model, "messages": []map[string]any{
			{"role": "system", "content": system}, {"role": "user", "content": question}}}
		if p.Type == "openai" {
			body["max_completion_tokens"] = maxTokens
		} else {
			body["max_tokens"] = maxTokens
		}
		var r struct {
			Model   string `json:"model"`
			Choices []struct {
				Message struct {
					Content string `json:"content"`
				} `json:"message"`
				Finish string `json:"finish_reason"`
			} `json:"choices"`
			Usage struct {
				In  int `json:"prompt_tokens"`
				Out int `json:"completion_tokens"`
			} `json:"usage"`
		}
		if err := aiDo(p, http.MethodPost, "/v1/chat/completions", body, &r); err != nil {
			return ans, err
		}
		if len(r.Choices) == 0 {
			return ans, fail("unsupported", "%s answered without a reply", p.Name)
		}
		ans.Text, ans.Model, ans.In, ans.Out, ans.Stop = r.Choices[0].Message.Content, r.Model, r.Usage.In, r.Usage.Out, r.Choices[0].Finish
	}
	if ans.Model == "" {
		ans.Model = p.Model
	}
	ans.Millis = time.Since(start).Milliseconds()
	return ans, nil
}

func registerAI() {
	ops["ai.list"] = func(json.RawMessage) (any, error) {
		list, err := aiLoad()
		if err != nil {
			return nil, err
		}
		out := []map[string]any{}
		for _, p := range list {
			out = append(out, p.public())
		}
		return map[string]any{"providers": out, "can_store_keys": canSeal()}, nil
	}

	ops["ai.save"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			ID        string `json:"id"`
			Type      string `json:"type"`
			Name      string `json:"name"`
			BaseURL   string `json:"base_url"`
			Model     string `json:"model"`
			Key       string `json:"key"`      // "" keeps the saved one
			DropKey   bool   `json:"drop_key"` // forget the saved one
			AllowHTTP bool   `json:"allow_http"`
			CloudOK   bool   `json:"cloud_ok"`
		}](raw)
		if err != nil {
			return nil, err
		}
		def, ok := aiDefaults[a.Type]
		if !ok {
			return nil, fail("invalid", "an AI provider is Ollama, LM Studio, OpenAI, Claude or a custom endpoint")
		}
		base := strings.TrimSpace(a.BaseURL)
		if base == "" {
			base = def[0]
		}
		if base == "" {
			return nil, fail("invalid", "a custom endpoint needs its address")
		}
		if base, err = checkBase(base, a.AllowHTTP); err != nil {
			return nil, err
		}
		model := strings.TrimSpace(a.Model)
		if model == "" {
			model = def[1]
		}
		if model == "" {
			return nil, fail("invalid", "choose a model (Test lists the ones this provider has)")
		}
		if !validModel(model) {
			return nil, fail("invalid", "that is not a model name")
		}
		if strings.ContainsAny(a.Key, "\r\n\x00") || len(a.Key) > 4096 {
			return nil, fail("invalid", "that is not an API key")
		}
		list, err := aiLoad()
		if err != nil {
			return nil, err
		}
		p := aiProvider{}
		idx := -1
		for i := range list {
			if list[i].ID == a.ID && a.ID != "" {
				p, idx = list[i], i
			}
		}
		if a.ID != "" && idx < 0 {
			return nil, fail("notfound", "that AI provider is no longer saved")
		}
		if idx >= 0 && p.BaseURL != base {
			p.Sealed = "" // a key belongs to the address it was entered for
		}
		name := strings.TrimSpace(a.Name)
		if name == "" {
			name = aiNames[a.Type]
		}
		p.Type, p.Name, p.BaseURL, p.Model, p.AllowHTTP, p.CloudOK = a.Type, name, base, model, a.AllowHTTP, a.CloudOK
		if a.DropKey {
			p.Sealed = ""
		}
		if a.Key != "" {
			if !canSeal() {
				return nil, fail("unsupported", "this system has no protected storage KubeFactory can use, so a key cannot be kept")
			}
			s, err := seal(a.Key)
			if err != nil {
				return nil, fail("other", "the key could not be stored safely")
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
		if err := aiSave(list); err != nil {
			return nil, err
		}
		return p.public(), nil
	}

	ops["ai.remove"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			ID string `json:"id"`
		}](raw)
		if err != nil {
			return nil, err
		}
		list, err := aiLoad()
		if err != nil {
			return nil, err
		}
		kept := list[:0]
		for _, p := range list {
			if p.ID != a.ID {
				kept = append(kept, p)
			}
		}
		return map[string]any{}, aiSave(kept)
	}

	// Is it there, is the key accepted, and which models does it offer?
	ops["ai.test"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			ID string `json:"id"`
		}](raw)
		if err != nil {
			return nil, err
		}
		p, err := aiFind(a.ID)
		if err != nil {
			return nil, err
		}
		var r struct {
			Data []struct {
				ID string `json:"id"`
			} `json:"data"`
		}
		if err := aiDo(p, http.MethodGet, "/v1/models", nil, &r); err != nil {
			return nil, err
		}
		models := []string{}
		for _, m := range r.Data {
			if validModel(m.ID) {
				models = append(models, m.ID)
			}
		}
		sort.Strings(models)
		if len(models) > 100 {
			models = models[:100]
		}
		has := false
		for _, m := range models {
			has = has || m == p.Model
		}
		return map[string]any{"models": models, "model_listed": has}, nil
	}

	ops["ai.ask"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			ID        string `json:"id"`
			System    string `json:"system"`
			Question  string `json:"question"`
			MaxTokens int    `json:"max_tokens"`
		}](raw)
		if err != nil {
			return nil, err
		}
		if len(a.System)+len(a.Question) > aiMaxQuestion {
			return nil, fail("invalid", "the question and its context are larger than 48 KiB")
		}
		if strings.TrimSpace(a.Question) == "" {
			return nil, fail("invalid", "ask a question")
		}
		if a.MaxTokens <= 0 {
			a.MaxTokens = 2048
		}
		if a.MaxTokens > aiMaxTokens {
			a.MaxTokens = aiMaxTokens
		}
		p, err := aiFind(a.ID)
		if err != nil {
			return nil, err
		}
		aiMu.Lock()
		if aiBusy[p.ID] {
			aiMu.Unlock()
			return nil, fail("busy", "%s is still answering the previous question", p.Name)
		}
		aiBusy[p.ID] = true
		aiMu.Unlock()
		defer func() { aiMu.Lock(); delete(aiBusy, p.ID); aiMu.Unlock() }()
		return aiAsk(p, a.System, a.Question, a.MaxTokens)
	}
}
