package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
)

// source says where a kubeconfig comes from: a file on disk, or text the
// user pasted / dropped (then relative file references need a base dir).
type source struct {
	Path    string `json:"path"`
	Content string `json:"content"`
	BaseDir string `json:"base_dir"`
}

type contextInfo struct {
	Name      string `json:"name"`
	Cluster   string `json:"cluster"`
	Server    string `json:"server"`
	User      string `json:"user"`
	Namespace string `json:"namespace"`
	Auth      string `json:"auth"`            // token | client-cert | exec | auth-provider | basic | none
	ExecCmd   string `json:"exec,omitempty"`  // the credential plugin this context would run
	Insecure  bool   `json:"insecure"`        // insecure-skip-tls-verify is set
	Current   bool   `json:"current"`
	Problem   string `json:"problem,omitempty"`
}

func registerKubeconfig() {
	// Where kubeconfigs usually live on this machine. Only names are
	// returned; nothing is loaded until the user picks one.
	ops["kubeconfig.discover"] = func(json.RawMessage) (any, error) {
		var found []map[string]any
		seen := map[string]bool{}
		add := func(p, why string) {
			if p == "" || seen[p] {
				return
			}
			if st, err := os.Stat(p); err == nil && !st.IsDir() {
				seen[p] = true
				found = append(found, map[string]any{"path": p, "why": why})
			}
		}
		if home, err := os.UserHomeDir(); err == nil {
			add(filepath.Join(home, ".kube", "config"), "default location")
		}
		for _, p := range filepath.SplitList(os.Getenv("KUBECONFIG")) {
			add(p, "KUBECONFIG")
		}
		return map[string]any{"files": found}, nil
	}

	ops["kubeconfig.inspect"] = func(raw json.RawMessage) (any, error) {
		src, err := decode[source](raw)
		if err != nil {
			return nil, err
		}
		cfg, err := loadConfig(src)
		if err != nil {
			return nil, err
		}
		var list []contextInfo
		for name, c := range cfg.Contexts {
			ci := contextInfo{Name: name, Cluster: c.Cluster, User: c.AuthInfo, Namespace: c.Namespace, Current: name == cfg.CurrentContext}
			if cl, ok := cfg.Clusters[c.Cluster]; ok {
				ci.Server = cl.Server
				ci.Insecure = cl.InsecureSkipTLSVerify
			} else {
				ci.Problem = "cluster \"" + c.Cluster + "\" is not defined in this file"
			}
			if ai, ok := cfg.AuthInfos[c.AuthInfo]; ok {
				ci.Auth, ci.ExecCmd = authKind(ai)
			} else {
				ci.Auth = "none"
			}
			if ci.Problem == "" {
				if rel := relativeRefs(cfg, c); len(rel) > 0 && src.Path == "" && src.BaseDir == "" {
					ci.Problem = "refers to files by relative path (" + strings.Join(rel, ", ") + "): choose the folder they are in"
				}
			}
			list = append(list, ci)
		}
		sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
		return map[string]any{"contexts": list, "current": cfg.CurrentContext, "clusters": len(cfg.Clusters), "users": len(cfg.AuthInfos)}, nil
	}
}

func authKind(ai *clientcmdapi.AuthInfo) (kind, execCmd string) {
	switch {
	case ai.Exec != nil:
		return "exec", ai.Exec.Command
	case ai.AuthProvider != nil:
		return "auth-provider", ai.AuthProvider.Name
	case ai.Token != "" || ai.TokenFile != "":
		return "token", ""
	case len(ai.ClientCertificateData) > 0 || ai.ClientCertificate != "":
		return "client-cert", ""
	case ai.Username != "":
		return "basic", ""
	}
	return "none", ""
}

// loadConfig parses a kubeconfig from a file or from pasted text. For a file,
// client-go resolves relative paths against the file's own directory. For
// pasted text we resolve them against BaseDir when one was given.
func loadConfig(src source) (*clientcmdapi.Config, error) {
	var cfg *clientcmdapi.Config
	var err error
	if src.Path != "" {
		if cfg, err = clientcmd.LoadFromFile(src.Path); err != nil {
			return nil, fail("config", "could not read that kubeconfig: %s", scrub(err))
		}
		// relative references in a file mean "relative to that file"
		if abs, e := filepath.Abs(src.Path); e == nil {
			src.BaseDir = filepath.Dir(abs)
		}
	} else {
		if strings.TrimSpace(src.Content) == "" {
			return nil, fail("config", "no kubeconfig given")
		}
		if cfg, err = clientcmd.Load([]byte(src.Content)); err != nil {
			return nil, fail("config", "that text is not a valid kubeconfig: %s", scrub(err))
		}
	}
	if len(cfg.Contexts) == 0 {
		return nil, fail("config", "that kubeconfig has no contexts")
	}
	if src.BaseDir != "" {
		for _, cl := range cfg.Clusters {
			cl.CertificateAuthority = resolve(src.BaseDir, cl.CertificateAuthority)
		}
		for _, ai := range cfg.AuthInfos {
			ai.ClientCertificate = resolve(src.BaseDir, ai.ClientCertificate)
			ai.ClientKey = resolve(src.BaseDir, ai.ClientKey)
			ai.TokenFile = resolve(src.BaseDir, ai.TokenFile)
		}
	}
	return cfg, nil
}

func resolve(base, p string) string {
	if p == "" || filepath.IsAbs(p) {
		return p
	}
	return filepath.Join(base, p)
}

// relativeRefs lists the kinds of relative file reference a context uses.
func relativeRefs(cfg *clientcmdapi.Config, c *clientcmdapi.Context) []string {
	var r []string
	rel := func(p string) bool { return p != "" && !filepath.IsAbs(p) }
	if cl, ok := cfg.Clusters[c.Cluster]; ok && rel(cl.CertificateAuthority) {
		r = append(r, "certificate-authority")
	}
	if ai, ok := cfg.AuthInfos[c.AuthInfo]; ok {
		if rel(ai.ClientCertificate) {
			r = append(r, "client-certificate")
		}
		if rel(ai.ClientKey) {
			r = append(r, "client-key")
		}
		if rel(ai.TokenFile) {
			r = append(r, "tokenFile")
		}
	}
	return r
}

// scrub keeps error text from echoing kubeconfig contents back: only the
// first line, capped. (client-go parse errors can quote the offending line.)
func scrub(err error) string {
	s := strings.SplitN(err.Error(), "\n", 2)[0]
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}
