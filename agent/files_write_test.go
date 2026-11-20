package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestStorageTextLimits(t *testing.T) {
	for _, text := range []string{"", "hello\n", "name: café\n", strings.Repeat("a", pageSize)} {
		if err := editableText(text); err != nil {
			t.Fatalf("valid text: %v", err)
		}
	}
	for _, text := range []string{"db\x00data", "bad\x01", "\xff", strings.Repeat("a", pageSize+1)} {
		if editableText(text) == nil {
			t.Fatal("unsafe or oversized text accepted")
		}
	}
}

func TestStorageWriteRejectsInvalidBeforeConnecting(t *testing.T) {
	registerFiles()
	for _, args := range []fileArgs{{Text: "\x00"}, {Text: "hello", Expected: "missing"}, {Text: "hello", Expected: strings.Repeat("a", 64), Path: "config\n.yaml"}} {
		raw, _ := json.Marshal(args)
		_, err := ops["files.write"](raw)
		if err == nil || !strings.HasPrefix(err.Error(), "invalid:") {
			t.Fatalf("expected validation, got %v", err)
		}
	}
}
