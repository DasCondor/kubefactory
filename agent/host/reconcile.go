package main

// One check of the host: is Docker answering, do the server's volume, network
// and image exist, and is the KubeFactory server container running and
// accepting connections? Whatever is missing is created, whatever stopped is
// started. Only things carrying the service's label are ever changed or
// removed; a same-named container someone else made is left alone and
// reported.

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

const (
	managedLabel = "io.kubefactory.managed"
	managedValue = "host"
	specLabel    = "io.kubefactory.spec"
	serverPort   = 7666 // the server's port inside the container
	unhealthyMax = 3    // checks in a row the server may refuse connections before a restart
)

// Docker runs one docker command and returns its output. Tests replace it.
type Docker interface {
	Run(args ...string) (string, error)
}

type dockerCLI struct{ bin string }

func (d dockerCLI) Run(args ...string) (string, error) {
	bin := d.bin
	if bin == "" {
		bin = "docker"
	}
	cmd := exec.Command(bin, args...)
	hideWindow(cmd)
	out, err := cmd.CombinedOutput()
	s := strings.TrimSpace(string(out))
	if err != nil {
		if s == "" {
			s = err.Error()
		}
		return s, fmt.Errorf("docker %s: %s", args[0], firstLine(s))
	}
	return s, nil
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// Probe says whether the server inside the container accepts connections.
type Probe func(port int) bool

func tcpProbe(port int) bool {
	c, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 2*time.Second)
	if err != nil {
		return false
	}
	c.Close()
	return true
}

type Reconciler struct {
	cfg       Config
	docker    Docker
	probe     Probe
	unhealthy int
}

// Result of one check: what was found and what was done.
type Result struct {
	At        time.Time `json:"at"`
	Docker    string    `json:"docker"`    // engine version, or "" when unreachable
	Container string    `json:"container"` // running, exited, missing, foreign...
	Healthy   bool      `json:"healthy"`   // the server accepted a connection
	Actions   []string  `json:"actions"`   // what this check changed
	Problem   string    `json:"problem"`   // why it could not finish, if it could not
}

// runArgs is the exact docker run command for the configured server.
func (r *Reconciler) runArgs(spec string) []string {
	c := r.cfg
	a := []string{"run", "-d", "--name", c.Container,
		"--label", managedLabel + "=" + managedValue, "--label", specLabel + "=" + spec,
		"--restart", "unless-stopped",
		"-v", c.Volume + ":/data", "-e", "KF_SERVER_DIR=/data"}
	port, listen := serverPort, "0.0.0.0"
	if c.HostNetwork {
		// no port mapping on the host network: the server itself stays on loopback
		port, listen = c.Internal, "127.0.0.1"
		a = append(a, "--network", "host")
	} else {
		a = append(a, "-p", fmt.Sprintf("127.0.0.1:%d:%d", c.Internal, serverPort))
		if c.Network != "" {
			a = append(a, "--network", c.Network)
		}
	}
	if c.User != "" {
		a = append(a, "--user", c.User)
	}
	for _, g := range c.GroupAdd {
		a = append(a, "--group-add", g)
	}
	for _, m := range c.Mounts {
		v := m.Host + ":" + m.Container
		if m.ReadOnly {
			v += ":ro"
		}
		a = append(a, "-v", v)
	}
	for _, e := range c.Env {
		a = append(a, "-e", e)
	}
	a = append(a, c.Image, fmt.Sprintf("--server=%d", port), "--listen="+listen)
	if c.ReadOnly {
		a = append(a, "--read-only")
	}
	return append(a, c.Source...)
}

// specHash fingerprints the configuration, so a changed host.json recreates
// the container on the next check instead of leaving the old one running.
func (r *Reconciler) specHash() string {
	h := sha256.Sum256([]byte(strings.Join(r.runArgs(""), "\x00")))
	return hex.EncodeToString(h[:])[:16]
}

func (r *Reconciler) Check() Result {
	res := Result{At: time.Now()}
	c := r.cfg
	v, err := r.docker.Run("version", "--format", "{{.Server.Version}}")
	if err != nil || v == "" {
		res.Problem = "Docker is not answering; the access point stays up and the server is started when Docker is back"
		res.Container = "unknown"
		r.unhealthy = 0
		return res
	}
	res.Docker = v
	// the data volume and the optional network
	if _, err := r.docker.Run("volume", "inspect", c.Volume); err != nil {
		if _, err := r.docker.Run("volume", "create", "--label", managedLabel+"="+managedValue, c.Volume); err != nil {
			res.Problem = err.Error()
			return res
		}
		res.Actions = append(res.Actions, "created volume "+c.Volume)
	}
	if c.Network != "" {
		if _, err := r.docker.Run("network", "inspect", c.Network); err != nil {
			if _, err := r.docker.Run("network", "create", "--label", managedLabel+"="+managedValue, c.Network); err != nil {
				res.Problem = err.Error()
				return res
			}
			res.Actions = append(res.Actions, "created network "+c.Network)
		}
	}
	spec := r.specHash()
	out, err := r.docker.Run("container", "inspect", "--format",
		"{{index .Config.Labels \""+managedLabel+"\"}}|{{index .Config.Labels \""+specLabel+"\"}}|{{.State.Status}}", c.Container)
	if err != nil {
		res.Container = "missing"
		if !r.ensureImage(&res) {
			return res
		}
		if _, err := r.docker.Run(r.runArgs(spec)...); err != nil {
			res.Problem = err.Error()
			return res
		}
		res.Actions = append(res.Actions, "started a new server container")
		res.Container = "running"
		r.unhealthy = 0
		return res
	}
	f := strings.SplitN(out, "|", 3)
	for len(f) < 3 {
		f = append(f, "")
	}
	if f[0] != managedValue {
		res.Container = "foreign"
		res.Problem = fmt.Sprintf("a container named %s exists that this service did not create; it is left alone (rename it, or choose another name in host.json)", c.Container)
		return res
	}
	res.Container = f[2]
	if f[1] != spec {
		if !r.ensureImage(&res) {
			return res
		}
		if _, err := r.docker.Run("rm", "-f", c.Container); err != nil {
			res.Problem = err.Error()
			return res
		}
		if _, err := r.docker.Run(r.runArgs(spec)...); err != nil {
			res.Problem = err.Error()
			return res
		}
		res.Actions = append(res.Actions, "recreated the server container for the changed settings")
		res.Container = "running"
		r.unhealthy = 0
		return res
	}
	switch f[2] {
	case "running":
		if r.probe(c.Internal) {
			res.Healthy = true
			r.unhealthy = 0
			return res
		}
		r.unhealthy++
		if r.unhealthy >= unhealthyMax {
			if _, err := r.docker.Run("restart", c.Container); err != nil {
				res.Problem = err.Error()
				return res
			}
			res.Actions = append(res.Actions, fmt.Sprintf("restarted the server: it refused connections %d checks in a row", r.unhealthy))
			r.unhealthy = 0
		}
	case "paused":
		if _, err := r.docker.Run("unpause", c.Container); err != nil {
			res.Problem = err.Error()
			return res
		}
		res.Actions = append(res.Actions, "unpaused the server container")
	case "restarting":
		// Docker is already on it
	default: // created, exited, dead
		if _, err := r.docker.Run("start", c.Container); err != nil {
			res.Problem = err.Error()
			return res
		}
		res.Actions = append(res.Actions, "started the server container (it was "+f[2]+")")
		r.unhealthy = 0
	}
	return res
}

func (r *Reconciler) ensureImage(res *Result) bool {
	if _, err := r.docker.Run("image", "inspect", "--format", "{{.Id}}", r.cfg.Image); err == nil {
		return true
	}
	if !r.cfg.Pull {
		res.Problem = "the image " + r.cfg.Image + " is not on this host and pulling is off in host.json"
		return false
	}
	if _, err := r.docker.Run("pull", r.cfg.Image); err != nil {
		res.Problem = err.Error()
		return false
	}
	res.Actions = append(res.Actions, "pulled "+r.cfg.Image)
	return true
}
