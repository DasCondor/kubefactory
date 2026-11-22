package main

// The host service's settings: one JSON file per machine, written by the
// installer and edited by the admin. Nothing in it is a credential: tokens stay
// in the server's data volume (hashed), and mounts only name host paths.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// Mount is one host path the admin chose to give the server container, such as
// the Docker socket (for a Docker source) or a folder holding a kubeconfig.
// The service never adds one on its own.
type Mount struct {
	Host      string `json:"host"`
	Container string `json:"container"`
	ReadOnly  bool   `json:"read_only"`
}

type Config struct {
	// The container the service keeps running.
	Container string   `json:"container"` // its name; the service only touches a container with this name AND its label
	Image     string   `json:"image"`     // e.g. ghcr.io/dascondor/kubefactory-server:2.1.0
	Pull      bool     `json:"pull"`      // pull the image when it is missing (false: it must already be loaded)
	Source    []string `json:"source"`    // KubeFactory source options, e.g. ["--demo"], ["--docker"], ["--context=prod"]
	ReadOnly  bool     `json:"read_only"` // start the server with --read-only
	Volume    string   `json:"volume"`    // named volume for the server's data (token hashes, audit log)
	Mounts    []Mount  `json:"mounts"`    // host paths the admin chose to share
	Env       []string `json:"env"`       // extra NAME=value for the container; never secrets (they would show in docker inspect)
	Network   string   `json:"network"`   // a Docker network to create and attach (optional)
	// Linux hosts: share the host's network, e.g. to reach a k3s API on
	// 127.0.0.1:6443. The server then listens on 127.0.0.1:<internal_port> itself.
	HostNetwork bool     `json:"host_network"`
	User        string   `json:"user"`          // run the container as this user (default: the image's unprivileged user)
	GroupAdd    []string `json:"group_add"`     // extra groups, e.g. the Docker socket's group id for a Docker source
	Internal    int      `json:"internal_port"` // where the container's server is published, on 127.0.0.1 only

	// The access point players connect to; it stays up while the container,
	// Docker or Kubernetes restart.
	Listen  string `json:"listen"`   // address:port, default 127.0.0.1:7666
	TLSCert string `json:"tls_cert"` // with tls_key: wss:// on the access point
	TLSKey  string `json:"tls_key"`

	Interval  int    `json:"interval_seconds"` // how often the service checks (default 30)
	DockerBin string `json:"docker"`           // the docker CLI to use; default: docker on PATH
}

func defaultConfig() Config {
	return Config{
		Container: "kubefactory-server",
		Image:     "ghcr.io/dascondor/kubefactory-server:latest",
		Pull:      true,
		Source:    []string{"--demo"},
		Volume:    "kubefactory-server-data",
		Internal:  17666,
		Listen:    "127.0.0.1:7666",
		Interval:  30,
	}
}

// dataDir is where the config, status and log live: machine-wide, written by
// the installer with admin rights.
func dataDir() string {
	if d := os.Getenv("KF_HOST_DIR"); d != "" {
		return d
	}
	if runtime.GOOS == "windows" {
		pd := os.Getenv("ProgramData")
		if pd == "" {
			pd = `C:\ProgramData`
		}
		return filepath.Join(pd, "KubeFactory", "Host")
	}
	return "/etc/kubefactory"
}

// stateDir holds the status and the log: the settings folder on Windows,
// /var/lib/kubefactory-host on Linux (settings stay in /etc).
func stateDir() string {
	if os.Getenv("KF_HOST_DIR") != "" || runtime.GOOS == "windows" {
		return dataDir()
	}
	return "/var/lib/kubefactory-host"
}

func defaultConfigPath() string { return filepath.Join(dataDir(), "host.json") }

func (c Config) interval() time.Duration {
	if c.Interval < 5 {
		return 30 * time.Second
	}
	return time.Duration(c.Interval) * time.Second
}

func loadConfig(path string) (Config, error) {
	c := defaultConfig()
	b, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	b = bytes.TrimPrefix(b, []byte("\xef\xbb\xbf")) // Windows PowerShell 5.1 writes a BOM
	if err := json.Unmarshal(b, &c); err != nil {
		return c, fmt.Errorf("%s: %w", path, err)
	}
	return c, c.validate()
}

var errBadName = errors.New("container, volume and network names may use letters, digits, '.', '_' and '-' only")

func validName(s string) bool {
	if s == "" || len(s) > 128 {
		return false
	}
	for _, r := range s {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '.' || r == '_' || r == '-') {
			return false
		}
	}
	return true
}

func (c Config) validate() error {
	if !validName(c.Container) || !validName(c.Volume) || (c.Network != "" && !validName(c.Network)) {
		return errBadName
	}
	if c.Image == "" || strings.ContainsAny(c.Image, " \t\n") || strings.HasPrefix(c.Image, "-") {
		return errors.New("image must be one image reference")
	}
	if c.HostNetwork && c.Network != "" {
		return errors.New("host_network and network cannot both be set")
	}
	for _, s := range append([]string{c.User}, c.GroupAdd...) {
		if strings.ContainsAny(s, " \t\n") || strings.HasPrefix(s, "-") {
			return fmt.Errorf("user and group_add take plain names or ids, not %q", s)
		}
	}
	if c.Internal < 1 || c.Internal > 65535 {
		return errors.New("internal_port must be 1-65535")
	}
	for _, s := range c.Source {
		if !strings.HasPrefix(s, "--") || strings.HasPrefix(s, "--server") || strings.HasPrefix(s, "--listen") {
			return fmt.Errorf("source option %q is not allowed (the service sets --server and --listen itself)", s)
		}
	}
	for _, m := range c.Mounts {
		if m.Host == "" || !strings.HasPrefix(m.Container, "/") || strings.Contains(m.Host+m.Container, ",") {
			return fmt.Errorf("mount %q -> %q: give an absolute container path and no commas", m.Host, m.Container)
		}
	}
	for _, e := range c.Env {
		name := strings.ToUpper(strings.SplitN(e, "=", 2)[0])
		if !strings.Contains(e, "=") {
			return fmt.Errorf("env %q is not NAME=value", e)
		}
		for _, w := range []string{"TOKEN", "PASSWORD", "SECRET", "KEY"} {
			if strings.Contains(name, w) {
				return fmt.Errorf("env %s looks like a secret; secrets do not belong in host.json (docker inspect shows them)", name)
			}
		}
	}
	if (c.TLSCert == "") != (c.TLSKey == "") {
		return errors.New("tls_cert and tls_key go together")
	}
	return nil
}
