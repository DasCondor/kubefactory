package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"testing"
	"time"
)

func TestShutdownRequest(t *testing.T) {
	if os.Getenv("KF_TEST_AGENT_PROCESS") == "1" {
		main()
		os.Exit(0)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestShutdownRequest$")
	cmd.Env = append(os.Environ(), "KF_TEST_AGENT_PROCESS=1")
	in, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	defer in.Close()
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	dec := json.NewDecoder(out)
	for i, op := range []string{"ping", "shutdown"} {
		if _, err := fmt.Fprintf(in, "{\"id\":%d,\"op\":%q}\n", i+1, op); err != nil {
			t.Fatal(err)
		}
		var reply struct {
			ID int  `json:"id"`
			OK bool `json:"ok"`
		}
		if err := dec.Decode(&reply); err != nil || !reply.OK || reply.ID != i+1 {
			t.Fatalf("%s reply: %+v, %v", op, reply, err)
		}
	}
	// Stdin is still open: only the shutdown request can make the child exit.
	if err := cmd.Wait(); err != nil {
		t.Fatalf("agent did not shut down: %v", err)
	}
}
