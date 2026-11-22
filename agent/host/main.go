// kf-host: KubeFactory's high-availability host service.
//
// Installed as a Windows service or a systemd unit on each Docker host or
// cluster node, it keeps the KubeFactory server container running (checking
// every 30 seconds) and gives players a stable access point that stays up
// while the container, Docker or Kubernetes restart. See docs/HOST_SERVICE.md.
//
//	kf-host run        [--config <file>]   run in the foreground (systemd runs this)
//	kf-host check      [--config <file>]   one check now, then exit
//	kf-host validate   [--config <file>]   read the settings and show them as the service sees them
//	kf-host status                         the last checks, as the service wrote them
//	kf-host install    [--config <file>]   install and start the service (admin)
//	kf-host uninstall  [--remove-container] stop and remove the service (admin)
//	kf-host version
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

const version = "2.2.0-dev"
const serviceName = "KubeFactoryHost"

type Status struct {
	Version  string    `json:"version"`
	Started  time.Time `json:"started"`
	Listen   string    `json:"listen"`
	Image    string    `json:"image"`
	Interval int       `json:"interval_seconds"`
	Players  int       `json:"players"`
	Last     *Result   `json:"last,omitempty"`
	History  []Result  `json:"history"` // checks that changed something or found a problem, newest last
}

type host struct {
	cfg    Config
	rec    *Reconciler
	relay  *Relay
	mu     sync.Mutex
	status Status
	logf   *os.File
}

func newHost(cfg Config) *host {
	h := &host{cfg: cfg}
	h.rec = &Reconciler{cfg: cfg, docker: dockerCLI{bin: cfg.DockerBin}, probe: tcpProbe}
	h.relay = &Relay{Upstream: fmt.Sprintf("ws://127.0.0.1:%d", cfg.Internal), Status: h.snapshot, Log: h.log}
	h.status = Status{Version: version, Started: time.Now(), Listen: cfg.Listen, Image: cfg.Image, Interval: int(cfg.interval() / time.Second)}
	return h
}

func (h *host) log(s string) {
	line := time.Now().Format(time.RFC3339) + " " + s
	fmt.Println(line)
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.logf == nil {
		_ = os.MkdirAll(stateDir(), 0o755)
		p := filepath.Join(stateDir(), "host.log")
		if fi, err := os.Stat(p); err == nil && fi.Size() > 1<<20 {
			_ = os.Rename(p, p+".1")
		}
		h.logf, _ = os.OpenFile(p, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	}
	if h.logf != nil {
		fmt.Fprintln(h.logf, line)
	}
}

func (h *host) snapshot() Status {
	h.mu.Lock()
	defer h.mu.Unlock()
	s := h.status
	s.Players = int(h.relay.sessions.Load())
	s.History = append([]Result(nil), h.status.History...)
	return s
}

func (h *host) record(r Result) {
	for _, a := range r.Actions {
		h.log(a)
	}
	if r.Problem != "" {
		h.log("problem: " + r.Problem)
	}
	h.mu.Lock()
	h.status.Last = &r
	if len(r.Actions) > 0 || r.Problem != "" {
		h.status.History = append(h.status.History, r)
		if len(h.status.History) > 20 {
			h.status.History = h.status.History[len(h.status.History)-20:]
		}
	}
	s := h.status
	s.Players = int(h.relay.sessions.Load())
	h.mu.Unlock()
	if b, err := json.MarshalIndent(s, "", "  "); err == nil {
		_ = os.WriteFile(filepath.Join(stateDir(), "status.json"), b, 0o644)
	}
}

// run keeps the container and the access point going until ctx ends.
func (h *host) run(ctx context.Context) error {
	h.log(fmt.Sprintf("kf-host %s: access point %s, server container %s (%s), checking every %s",
		version, h.cfg.Listen, h.cfg.Container, h.cfg.Image, h.cfg.interval()))
	errc := make(chan error, 1)
	go func() { errc <- h.relay.serve(ctx, h.cfg.Listen, h.cfg.TLSCert, h.cfg.TLSKey) }()
	t := time.NewTicker(h.cfg.interval())
	defer t.Stop()
	h.record(h.rec.Check())
	for {
		select {
		case <-ctx.Done():
			h.log("stopping (the server container keeps running)")
			return nil
		case err := <-errc:
			if err != nil {
				h.log("access point failed: " + err.Error())
			}
			return err
		case <-t.C:
			h.record(h.rec.Check())
		}
	}
}

func configArg(args []string) string {
	for i := 0; i < len(args); i++ {
		if args[i] == "--config" && i+1 < len(args) {
			return args[i+1]
		}
	}
	return defaultConfigPath()
}

func has(args []string, flag string) bool {
	for _, a := range args {
		if a == flag {
			return true
		}
	}
	return false
}

func load(args []string) Config {
	p := configArg(args)
	cfg, err := loadConfig(p)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			fmt.Fprintf(os.Stderr, "no settings at %s: run the installer, or `kf-host install` to write the defaults\n", p)
		} else {
			fmt.Fprintln(os.Stderr, "settings:", err)
		}
		os.Exit(2)
	}
	return cfg
}

func main() {
	if isWindowsService() {
		runAsWindowsService(load(os.Args[1:]))
		return
	}
	if len(os.Args) < 2 {
		fmt.Println("usage: kf-host run|check|validate|status|install|uninstall|version  (see docs/HOST_SERVICE.md)")
		os.Exit(2)
	}
	args := os.Args[2:]
	switch os.Args[1] {
	case "version":
		fmt.Println("kf-host", version)
	case "run":
		h := newHost(load(args))
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		if err := h.run(ctx); err != nil {
			os.Exit(1)
		}
	case "validate":
		cfg := load(args)
		b, _ := json.MarshalIndent(cfg, "", "  ")
		fmt.Println(string(b))
	case "check":
		cfg := load(args)
		r := (&Reconciler{cfg: cfg, docker: dockerCLI{bin: cfg.DockerBin}, probe: tcpProbe}).Check()
		b, _ := json.MarshalIndent(r, "", "  ")
		fmt.Println(string(b))
	case "status":
		b, err := os.ReadFile(filepath.Join(stateDir(), "status.json"))
		if err != nil {
			fmt.Println("no status yet: the service has not run a check on this machine")
			os.Exit(1)
		}
		fmt.Println(string(b))
	case "install":
		p := configArg(args)
		if _, err := os.Stat(p); errors.Is(err, os.ErrNotExist) {
			_ = os.MkdirAll(filepath.Dir(p), 0o755)
			b, _ := json.MarshalIndent(defaultConfig(), "", "  ")
			if err := os.WriteFile(p, b, 0o644); err != nil {
				fmt.Fprintln(os.Stderr, "cannot write", p+":", err)
				os.Exit(1)
			}
			fmt.Println("wrote default settings to", p)
		}
		if _, err := loadConfig(p); err != nil {
			fmt.Fprintln(os.Stderr, "settings:", err)
			os.Exit(2)
		}
		if err := installService(p); err != nil {
			fmt.Fprintln(os.Stderr, "install:", err)
			os.Exit(1)
		}
		fmt.Println("installed and started", serviceName)
	case "uninstall":
		if err := uninstallService(); err != nil {
			fmt.Fprintln(os.Stderr, "uninstall:", err)
			os.Exit(1)
		}
		fmt.Println("removed", serviceName)
		if has(args, "--remove-container") {
			cfg, err := loadConfig(configArg(args))
			if err == nil {
				d := dockerCLI{bin: cfg.DockerBin}
				if out, err := d.Run("container", "inspect", "--format", "{{index .Config.Labels \""+managedLabel+"\"}}", cfg.Container); err == nil && out == managedValue {
					if _, err := d.Run("rm", "-f", cfg.Container); err == nil {
						fmt.Println("removed the server container", cfg.Container, "(its data volume", cfg.Volume, "is kept)")
					}
				}
			}
		} else {
			fmt.Println("the server container keeps running; remove it with: kf-host uninstall --remove-container, or docker rm -f <name>")
		}
	default:
		fmt.Println("unknown command", os.Args[1])
		os.Exit(2)
	}
}
