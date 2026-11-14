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

const testAIKey = "sk-TESTKEY_do_not_leak_9876543210"

// One fake server that speaks both shapes: OpenAI-compatible chat completions
// and the Claude Messages API. It records what it was sent.
type fakeAI struct {
	srv  *httptest.Server
	last map[string]any
	hdr  http.Header
}

func newFakeAI(t *testing.T) *fakeAI {
	f := &fakeAI{}
	mux := http.NewServeMux()
	keyOK := func(w http.ResponseWriter, r *http.Request, h string) bool {
		f.hdr = r.Header.Clone()
		got := r.Header.Get(h)
		if got == testAIKey || got == "Bearer "+testAIKey {
			return true
		}
		w.WriteHeader(401)
		// a provider that echoes what it was given: the key must not reach the game
		w.Write([]byte(`{"error":{"message":"Incorrect API key provided: ` + strings.TrimPrefix(got, "Bearer ") + `"}}`))
		return false
	}
	mux.HandleFunc("/v1/models", func(w http.ResponseWriter, r *http.Request) {
		if !keyOK(w, r, "Authorization") {
			return
		}
		w.Write([]byte(`{"data":[{"id":"model-b"},{"id":"model-a"},{"id":"bad model"}]}`))
	})
	mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		if !keyOK(w, r, "Authorization") {
			return
		}
		b, _ := io.ReadAll(r.Body)
		json.Unmarshal(b, &f.last)
		w.Write([]byte(`{"model":"model-a","choices":[{"message":{"role":"assistant","content":"{\"answer\":\"hello\"}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":5}}`))
	})
	mux.HandleFunc("/v1/messages", func(w http.ResponseWriter, r *http.Request) {
		if !keyOK(w, r, "x-api-key") {
			return
		}
		b, _ := io.ReadAll(r.Body)
		json.Unmarshal(b, &f.last)
		if strings.Contains(string(b), "please refuse") {
			w.Write([]byte(`{"model":"claude-opus-5-5","content":[],"stop_reason":"refusal","usage":{"input_tokens":3,"output_tokens":0}}`))
			return
		}
		w.Write([]byte(`{"model":"claude-opus-5-5","content":[{"type":"thinking","thinking":""},{"type":"text","text":"part one, "},{"type":"text","text":"part two"}],"stop_reason":"end_turn","usage":{"input_tokens":20,"output_tokens":7}}`))
	})
	mux.HandleFunc("/moved/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "https://example.invalid/steal", http.StatusTemporaryRedirect)
	})
	f.srv = httptest.NewServer(mux)
	t.Cleanup(f.srv.Close)
	return f
}

func TestAIProviders(t *testing.T) {
	provSetup(t)
	ops = map[string]handler{}
	registerAll()
	f := newFakeAI(t)
	if !canSeal() {
		// no protected storage here (Linux, macOS today): a key must be refused, never kept in the clear
		if _, e := call(t, "ai.save", map[string]any{"type": "custom", "base_url": f.srv.URL, "model": "m", "key": testAIKey}); e == nil || e.Kind != "unsupported" {
			t.Fatalf("a key was accepted without protected storage: %v", e)
		}
		t.Skip("keys are refused on this system, as checked; the rest needs protected storage")
	}

	// an OpenAI-compatible endpoint on this computer
	p, e := call(t, "ai.save", map[string]any{"type": "custom", "base_url": f.srv.URL, "model": "model-a", "key": testAIKey})
	if e != nil {
		t.Fatalf("save: %v", e)
	}
	id := p["id"].(string)
	if p["local"] != true || p["has_key"] != true || p["name"] != "Custom endpoint" {
		t.Fatalf("public view: %v", p)
	}
	b, _ := json.Marshal(p)
	if strings.Contains(string(b), testAIKey) {
		t.Fatal("the key is in what the game sees")
	}
	disk, _ := os.ReadFile(filepath.Join(provDir, "ai-providers.json"))
	if strings.Contains(string(disk), testAIKey) {
		t.Fatal("the key is readable on disk")
	}
	r, e := call(t, "ai.test", map[string]any{"id": id})
	if e != nil || r["model_listed"] != true || len(r["models"].([]any)) != 2 {
		t.Fatalf("test: %v %v", r, e)
	}
	r, e = call(t, "ai.ask", map[string]any{"id": id, "system": "be brief", "question": "hi", "max_tokens": 99999})
	if e != nil || r["text"] != `{"answer":"hello"}` || r["input_tokens"].(float64) != 12 || r["cloud"] != false {
		t.Fatalf("ask: %v %v", r, e)
	}
	if f.last["max_tokens"].(float64) != aiMaxTokens {
		t.Fatalf("max tokens not capped: %v", f.last["max_tokens"])
	}
	msgs := f.last["messages"].([]any)
	if msgs[0].(map[string]any)["role"] != "system" || msgs[1].(map[string]any)["content"] != "hi" {
		t.Fatalf("messages: %v", msgs)
	}

	// a wrong key: the provider echoes it, the game must not see it
	_, e = call(t, "ai.save", map[string]any{"id": id, "type": "custom", "base_url": f.srv.URL, "model": "model-a", "key": "sk-WRONG_secret_value"})
	if e != nil {
		t.Fatal(e)
	}
	_, e = call(t, "ai.ask", map[string]any{"id": id, "question": "hi"})
	if e == nil || e.Kind != "auth" || strings.Contains(e.Msg, "sk-WRONG_secret_value") {
		t.Fatalf("wrong key: %v", e)
	}

	// Claude's Messages API: key header, version header, text blocks only
	c, e := call(t, "ai.save", map[string]any{"type": "claude", "base_url": f.srv.URL, "key": testAIKey})
	if e != nil || c["model"] != "claude-opus-5-5" {
		t.Fatalf("claude save: %v %v", c, e)
	}
	r, e = call(t, "ai.ask", map[string]any{"id": c["id"], "system": "sys", "question": "hi"})
	if e != nil || r["text"] != "part one, part two" || r["output_tokens"].(float64) != 7 {
		t.Fatalf("claude ask: %v %v", r, e)
	}
	if f.hdr.Get("anthropic-version") == "" || f.hdr.Get("Authorization") != "" || f.last["system"] != "sys" {
		t.Fatalf("claude request: %v %v", f.hdr, f.last)
	}
	if _, has := f.last["fallbacks"]; has {
		t.Fatal("fallbacks are only for Anthropic's own endpoint")
	}
	_, e = call(t, "ai.ask", map[string]any{"id": c["id"], "question": "please refuse"})
	if e == nil || e.Kind != "refused" {
		t.Fatalf("refusal: %v", e)
	}

	// a redirect is not followed
	m, _ := call(t, "ai.save", map[string]any{"type": "ollama", "base_url": f.srv.URL + "/moved", "model": "llama"})
	_, e = call(t, "ai.ask", map[string]any{"id": m["id"], "question": "hi"})
	if e == nil || !strings.Contains(e.Msg, "redirect") {
		t.Fatalf("redirect: %v", e)
	}

	// cloud: nothing is sent until the operator allows it
	cl, e := call(t, "ai.save", map[string]any{"type": "openai", "base_url": "https://api.example.invalid", "model": "x", "key": testAIKey})
	if e != nil || cl["local"] != false {
		t.Fatalf("cloud save: %v %v", cl, e)
	}
	_, e = call(t, "ai.ask", map[string]any{"id": cl["id"], "question": "hi"})
	if e == nil || e.Kind != "consent" {
		t.Fatalf("cloud consent: %v", e)
	}

	// bounds and validation
	if _, e = call(t, "ai.ask", map[string]any{"id": id, "question": strings.Repeat("x", aiMaxQuestion+1)}); e == nil {
		t.Fatal("oversized question accepted")
	}
	if _, e = call(t, "ai.save", map[string]any{"type": "shell", "base_url": f.srv.URL, "model": "x"}); e == nil {
		t.Fatal("unknown type accepted")
	}
	if _, e = call(t, "ai.save", map[string]any{"type": "ollama", "base_url": f.srv.URL}); e == nil {
		t.Fatal("ollama without a model accepted")
	}
	if _, e = call(t, "ai.save", map[string]any{"type": "custom", "base_url": "http://10.1.2.3:8080", "model": "x"}); e == nil {
		t.Fatal("plain http to another computer accepted without the operator's say-so")
	}
	l, _ := call(t, "ai.list", map[string]any{})
	if len(l["providers"].([]any)) != 4 {
		t.Fatalf("list: %v", l)
	}
	call(t, "ai.remove", map[string]any{"id": id})
	l, _ = call(t, "ai.list", map[string]any{})
	if len(l["providers"].([]any)) != 3 {
		t.Fatalf("remove: %v", l)
	}
}
