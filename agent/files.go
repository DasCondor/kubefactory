package main

// Read-only inspection of a pod's mounted volumes, for the storage doors.
//
// What this does and does not do:
//   - It uses only what the user is already allowed to do: `pods/exec` on a
//     running container, running `ls` and `head`/`dd` with a fixed argument
//     list. It creates no helper pods, mounts nothing, adds no privileges.
//   - Browsing is confined to one of the container's declared mount paths.
//     Paths are cleaned, must stay under that mount, and no directory along
//     the way may be a symlink (so a link inside a volume cannot lead out).
//   - Secret and service-account-token volumes can be listed but never read.
//   - Reads are paged (64 KiB) and capped; nothing is written, ever.
//   - A container without `ls` (distroless) is reported as unavailable.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"path"
	"strconv"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/remotecommand"
)

const (
	pageSize   = 64 * 1024
	maxEntries = 500
	maxPages   = 256 // 16 MiB is the furthest into a file a preview will go
)

type fileArgs struct {
	sessArgs
	Namespace, Pod, Container string
	Root, Path                string
	Page                      int
}

// run executes a fixed argv in the container and returns at most `limit` bytes of stdout.
func (s *session) run(ns, pod, container string, argv []string, limit int) (string, string, error) {
	req := s.cs.CoreV1().RESTClient().Post().Resource("pods").Namespace(ns).Name(pod).SubResource("exec").
		VersionedParams(&corev1.PodExecOptions{Container: container, Command: argv, Stdout: true, Stderr: true}, scheme.ParameterCodec)
	ex, err := remotecommand.NewSPDYExecutor(s.cfg, "POST", req.URL())
	if err != nil {
		return "", "", err
	}
	var stdout, stderr capped
	stdout.limit, stderr.limit = limit, 4096
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	err = ex.StreamWithContext(ctx, remotecommand.StreamOptions{Stdout: &stdout, Stderr: &stderr})
	return stdout.buf.String(), stderr.buf.String(), err
}

type capped struct {
	buf   bytes.Buffer
	limit int
}

func (c *capped) Write(p []byte) (int, error) {
	if room := c.limit - c.buf.Len(); room > 0 {
		if len(p) > room {
			c.buf.Write(p[:room])
		} else {
			c.buf.Write(p)
		}
	}
	return len(p), nil // keep draining so the remote command is not blocked
}

type mountInfo struct {
	Container string `json:"container"`
	Path      string `json:"path"`
	ReadOnly  bool   `json:"read_only"`
	Volume    string `json:"volume"`
	Type      string `json:"type"`
	Claim     string `json:"claim,omitempty"`
	PV        string `json:"pv,omitempty"`
	Class     string `json:"storage_class,omitempty"`
	Capacity  string `json:"capacity,omitempty"`
	Phase     string `json:"phase,omitempty"`
	Readable  bool   `json:"readable"` // false: contents are never shown (secrets, tokens)
	Running   bool   `json:"running"`
}

func volumeType(v corev1.Volume) (string, string) {
	switch {
	case v.PersistentVolumeClaim != nil:
		return "pvc", v.PersistentVolumeClaim.ClaimName
	case v.Secret != nil:
		return "secret", ""
	case v.Projected != nil:
		return "projected", ""
	case v.ConfigMap != nil:
		return "configmap", ""
	case v.EmptyDir != nil:
		return "emptydir", ""
	case v.HostPath != nil:
		return "hostpath", ""
	case v.CSI != nil:
		return "csi", ""
	case v.NFS != nil:
		return "nfs", ""
	case v.DownwardAPI != nil:
		return "downward", ""
	}
	return "other", ""
}

func (s *session) mounts(ns, pod string) ([]mountInfo, error) {
	ctx, cancel := ctxTimeout(15)
	defer cancel()
	p, err := s.cs.CoreV1().Pods(ns).Get(ctx, pod, metav1.GetOptions{})
	if err != nil {
		return nil, err
	}
	vols := map[string]corev1.Volume{}
	for _, v := range p.Spec.Volumes {
		vols[v.Name] = v
	}
	running := map[string]bool{}
	for _, cs := range p.Status.ContainerStatuses {
		running[cs.Name] = cs.State.Running != nil
	}
	out := []mountInfo{}
	for _, c := range p.Spec.Containers {
		for _, vm := range c.VolumeMounts {
			typ, claim := volumeType(vols[vm.Name])
			mi := mountInfo{Container: c.Name, Path: path.Clean(vm.MountPath), ReadOnly: vm.ReadOnly, Volume: vm.Name, Type: typ, Claim: claim,
				Readable: typ != "secret" && typ != "projected", Running: running[c.Name]}
			if claim != "" {
				if pvc, e := s.cs.CoreV1().PersistentVolumeClaims(ns).Get(ctx, claim, metav1.GetOptions{}); e == nil {
					mi.PV, mi.Phase = pvc.Spec.VolumeName, string(pvc.Status.Phase)
					if pvc.Spec.StorageClassName != nil {
						mi.Class = *pvc.Spec.StorageClassName
					}
					if q, ok := pvc.Status.Capacity[corev1.ResourceStorage]; ok {
						mi.Capacity = q.String()
					}
				}
			}
			out = append(out, mi)
		}
	}
	return out, nil
}

// guard checks that root is a real mount of this container and that p stays
// inside it, then returns the cleaned absolute path and the mount.
func (s *session) guard(a fileArgs) (string, *mountInfo, error) {
	// the path is judged first, on its own: a request that leaves the volume is
	// refused before the cluster is asked anything
	root := path.Clean(a.Root)
	full := path.Clean(path.Join(root, a.Path))
	if strings.ContainsRune(a.Path, 0) || (full != root && !strings.HasPrefix(full, strings.TrimSuffix(root, "/")+"/")) {
		return "", nil, fail("invalid", "that path is outside the mounted volume")
	}
	ms, err := s.mounts(a.Namespace, a.Pod)
	if err != nil {
		return "", nil, err
	}
	var m *mountInfo
	for i := range ms {
		if ms[i].Container == a.Container && ms[i].Path == root {
			m = &ms[i]
		}
	}
	if m == nil {
		return "", nil, fail("invalid", "%s is not a mounted volume of container %s", root, a.Container)
	}
	if !m.Running {
		return "", nil, fail("unsupported", "container %s is not running, so its files cannot be read", a.Container)
	}
	// no directory between the mount and the target may be a symlink
	if full != root {
		var chain []string
		for p := path.Dir(full); len(p) >= len(root) && p != root; p = path.Dir(p) {
			chain = append(chain, p)
		}
		if len(chain) > 0 {
			o, _, e := s.run(a.Namespace, a.Pod, a.Container, append([]string{"ls", "-ldn", "--"}, chain...), 16384)
			if e != nil {
				return "", nil, noTools(e)
			}
			for _, ln := range strings.Split(strings.TrimSpace(o), "\n") {
				if !strings.HasPrefix(ln, "d") {
					return "", nil, fail("invalid", "that path goes through a link, which is not followed")
				}
			}
		}
		// nor may the target itself be one: a linked file or folder inside the
		// volume can point anywhere in the container, and reading "through" it
		// would leave the volume without the path ever saying so
		o, _, e := s.run(a.Namespace, a.Pod, a.Container, []string{"ls", "-ldn", "--", full}, 4096)
		if e != nil {
			if strings.Contains(e.Error(), "No such file") || strings.Contains(e.Error(), "exit code 1") || strings.Contains(e.Error(), "exit code 2") {
				return "", nil, fail("notfound", "there is no such file or folder in this volume")
			}
			return "", nil, noTools(e)
		}
		if strings.HasPrefix(strings.TrimSpace(o), "l") {
			return "", nil, fail("invalid", "that is a link, which is not followed: it may point outside the volume")
		}
	}
	return full, m, nil
}

func noTools(err error) *opError {
	m := err.Error()
	if strings.Contains(m, "executable file not found") || strings.Contains(m, "no such file or directory") && strings.Contains(m, "exec") {
		return fail("unsupported", "this container has no file tools (no `ls`), so its volumes cannot be browsed from inside it")
	}
	return classify(err)
}

type entry struct {
	Name  string `json:"name"`
	Type  string `json:"type"` // dir | file | link | other
	Size  int64  `json:"size"`
	Mode  string `json:"mode"`
	Owner string `json:"owner"`
	Group string `json:"group"`
	MTime string `json:"mtime"`
	Link  string `json:"link,omitempty"`
}

// parseLs reads `ls -la` output (POSIX long format, as GNU and BusyBox print it).
func parseLs(text string) []entry {
	out := []entry{}
	for _, ln := range strings.Split(text, "\n") {
		f := strings.Fields(ln)
		if len(f) < 9 || len(f[0]) < 10 {
			continue
		}
		// the name is everything after the 8th field, spaces included
		rest := ln
		for i := 0; i < 8; i++ {
			rest = strings.TrimLeft(rest, " ")
			if j := strings.IndexByte(rest, ' '); j >= 0 {
				rest = rest[j:]
			}
		}
		name := strings.TrimLeft(rest, " ")
		if name == "." || name == ".." || name == "" {
			continue
		}
		e := entry{Mode: f[0], Owner: f[2], Group: f[3], MTime: strings.Join(f[5:8], " ")}
		e.Size, _ = strconv.ParseInt(f[4], 10, 64)
		switch f[0][0] {
		case 'd':
			e.Type = "dir"
		case '-':
			e.Type = "file"
		case 'l':
			e.Type = "link"
			if i := strings.Index(name, " -> "); i >= 0 {
				name, e.Link = name[:i], name[i+4:]
			}
		default:
			e.Type = "other"
		}
		e.Name = name
		out = append(out, e)
	}
	return out
}

func registerFiles() {
	ops["files.mounts"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[fileArgs](raw)
		if err != nil {
			return nil, err
		}
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		ms, err := s.mounts(a.Namespace, a.Pod)
		if err != nil {
			return nil, err
		}
		return map[string]any{"mounts": ms}, nil
	}

	ops["files.list"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[fileArgs](raw)
		if err != nil {
			return nil, err
		}
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		full, m, err := s.guard(a)
		if err != nil {
			return nil, err
		}
		// the trailing "/." lists the directory itself and refuses a non-directory
		o, e, err := s.run(a.Namespace, a.Pod, a.Container, []string{"ls", "-la", "--", full + "/."}, 256*1024)
		if err != nil {
			if strings.Contains(e, "Permission denied") {
				return nil, fail("rbac", "the container's user may not read %s", full)
			}
			if strings.Contains(e, "No such file") || strings.Contains(e, "Not a directory") {
				return nil, fail("notfound", "%s is not a directory", full)
			}
			return nil, noTools(err)
		}
		es := parseLs(o)
		truncated := len(es) > maxEntries
		if truncated {
			es = es[:maxEntries]
		}
		return map[string]any{"path": full, "entries": es, "truncated": truncated, "readable": m.Readable}, nil
	}

	ops["files.read"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[fileArgs](raw)
		if err != nil {
			return nil, err
		}
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		full, m, err := s.guard(a)
		if err != nil {
			return nil, err
		}
		if !m.Readable {
			return nil, fail("unsupported", "this is a %s volume: its contents are never shown", m.Type)
		}
		if a.Page < 0 || a.Page >= maxPages {
			return nil, fail("invalid", "previews stop at %d MiB", maxPages*pageSize/(1<<20))
		}
		o, _, err := s.run(a.Namespace, a.Pod, a.Container, []string{"ls", "-ldn", "--", full}, 4096)
		if err != nil {
			return nil, noTools(err)
		}
		f := strings.Fields(o)
		if len(f) < 5 || f[0][0] != '-' {
			return nil, fail("invalid", "only regular files can be previewed (links and devices are not followed)")
		}
		size, _ := strconv.ParseInt(f[4], 10, 64)
		argv := []string{"head", "-c", strconv.Itoa(pageSize), "--", full}
		if a.Page > 0 {
			argv = []string{"dd", "if=" + full, "bs=" + strconv.Itoa(pageSize), "skip=" + strconv.Itoa(a.Page), "count=1"}
		}
		data, e, err := s.run(a.Namespace, a.Pod, a.Container, argv, pageSize)
		if err != nil {
			if strings.Contains(e, "Permission denied") {
				return nil, fail("rbac", "the container's user may not read this file")
			}
			return nil, noTools(err)
		}
		pages := int((size + pageSize - 1) / pageSize)
		if pages > maxPages {
			pages = maxPages
		}
		return map[string]any{"path": full, "size": size, "page": a.Page, "pages": pages,
			"data": base64.StdEncoding.EncodeToString([]byte(data))}, nil
	}
}
