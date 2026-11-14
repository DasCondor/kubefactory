package main

// Tests against a fake Kubernetes API server speaking real TLS, so the
// kubeconfig handling, client-certificate and token authentication, and the
// separation of failure kinds are exercised without a cluster.

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type pki struct {
	caPEM, certPEM, keyPEM []byte
	pool                   *x509.CertPool
	server                 tls.Certificate
}

func makePKI(t *testing.T) *pki {
	t.Helper()
	caKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	caTpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "test-ca"}, NotBefore: time.Now().Add(-time.Hour),
		NotAfter: time.Now().Add(time.Hour), IsCA: true, KeyUsage: x509.KeyUsageCertSign, BasicConstraintsValid: true}
	caDER, _ := x509.CreateCertificate(rand.Reader, caTpl, caTpl, &caKey.PublicKey, caKey)
	caCert, _ := x509.ParseCertificate(caDER)
	leaf := func(cn string, server bool) ([]byte, []byte, tls.Certificate) {
		key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		tpl := &x509.Certificate{SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: cn, Organization: []string{"system:masters"}},
			NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature}
		if server {
			tpl.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
			tpl.IPAddresses = []net.IP{net.ParseIP("127.0.0.1")}
		} else {
			tpl.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}
		}
		der, _ := x509.CreateCertificate(rand.Reader, tpl, caCert, &key.PublicKey, caKey)
		kb, _ := x509.MarshalECPrivateKey(key)
		c := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
		k := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kb})
		pair, _ := tls.X509KeyPair(c, k)
		return c, k, pair
	}
	p := &pki{caPEM: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER}), pool: x509.NewCertPool()}
	p.pool.AddCert(caCert)
	_, _, p.server = leaf("apiserver", true)
	p.certPEM, p.keyPEM, _ = leaf("admin", false)
	return p
}

func status(w http.ResponseWriter, code int, reason, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	fmt.Fprintf(w, `{"kind":"Status","apiVersion":"v1","status":"Failure","message":%q,"reason":%q,"code":%d}`, msg, reason, code)
}

// fakeAPI authenticates by client certificate or by bearer token:
// "good" is an admin, "viewer" may not read configmaps, anything else is 401.
func fakeAPI(t *testing.T, p *pki) *httptest.Server {
	t.Helper()
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user := ""
		if len(r.TLS.PeerCertificates) > 0 {
			user = r.TLS.PeerCertificates[0].Subject.CommonName
		} else if tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "); tok == "good" || tok == "viewer" {
			user = tok
		}
		if user == "" {
			status(w, 401, "Unauthorized", "Unauthorized")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.URL.Path == "/version":
			fmt.Fprint(w, `{"major":"1","minor":"31","gitVersion":"v1.31.0-fake"}`)
		case strings.HasSuffix(r.URL.Path, "/selfsubjectreviews"):
			fmt.Fprintf(w, `{"kind":"SelfSubjectReview","apiVersion":"authentication.k8s.io/v1","status":{"userInfo":{"username":%q,"groups":["system:authenticated"]}}}`, user)
		case strings.Contains(r.URL.Path, "/configmaps/"):
			if user == "viewer" {
				status(w, 403, "Forbidden", `configmaps "x" is forbidden: User "viewer" cannot get resource "configmaps"`)
				return
			}
			fmt.Fprint(w, `{"kind":"ConfigMap","apiVersion":"v1","metadata":{"name":"x"},"data":{"k":"v"}}`)
		default:
			status(w, 404, "NotFound", "not found")
		}
	}))
	srv.TLS = &tls.Config{Certificates: []tls.Certificate{p.server}, ClientCAs: p.pool, ClientAuth: tls.VerifyClientCertIfGiven}
	srv.StartTLS()
	t.Cleanup(srv.Close)
	return srv
}

func call(t *testing.T, op string, args any) (map[string]any, *opError) {
	t.Helper()
	raw, _ := json.Marshal(args)
	data, err := ops[op](raw)
	if err != nil {
		oe, ok := err.(*opError)
		if !ok {
			oe = classify(err)
		}
		return nil, oe
	}
	b, _ := json.Marshal(data)
	m := map[string]any{}
	json.Unmarshal(b, &m)
	return m, nil
}

func kubeconfig(server, extra string) string {
	return fmt.Sprintf(`apiVersion: v1
kind: Config
current-context: cert
clusters:
- name: fake
  cluster: {server: %q, certificate-authority: ca.crt}
- name: fake-wrong-ca
  cluster: {server: %q, certificate-authority: other-ca.crt}
contexts:
- name: cert
  context: {cluster: fake, user: cert, namespace: shop}
- name: token
  context: {cluster: fake, user: token}
- name: viewer
  context: {cluster: fake, user: viewer}
- name: expired
  context: {cluster: fake, user: expired}
- name: wrong-ca
  context: {cluster: fake-wrong-ca, user: token}
- name: helper
  context: {cluster: fake, user: helper}
users:
- name: cert
  user: {client-certificate: admin.crt, client-key: admin.key}
- name: token
  user: {token: good}
- name: viewer
  user: {token: viewer}
- name: expired
  user: {token: stale}
- name: helper
  user:
    exec: {apiVersion: client.authentication.k8s.io/v1, command: %s, interactiveMode: Never}
%s`, server, server, "definitely-not-a-real-credential-helper", extra)
}

func setup(t *testing.T) (dir, path, server string) {
	t.Helper()
	ops = map[string]handler{}
	registerAll()
	p := makePKI(t)
	srv := fakeAPI(t, p)
	other := makePKI(t)
	dir = t.TempDir()
	os.WriteFile(filepath.Join(dir, "ca.crt"), p.caPEM, 0o600)
	os.WriteFile(filepath.Join(dir, "other-ca.crt"), other.caPEM, 0o600)
	os.WriteFile(filepath.Join(dir, "admin.crt"), p.certPEM, 0o600)
	os.WriteFile(filepath.Join(dir, "admin.key"), p.keyPEM, 0o600)
	path = filepath.Join(dir, "config")
	os.WriteFile(path, []byte(kubeconfig(srv.URL, "")), 0o600)
	t.Cleanup(closeAllSessions)
	return dir, path, srv.URL
}

func TestInspectListsContextsWithoutSecrets(t *testing.T) {
	_, path, _ := setup(t)
	d, e := call(t, "kubeconfig.inspect", map[string]any{"path": path})
	if e != nil {
		t.Fatal(e)
	}
	if d["current"] != "cert" || len(d["contexts"].([]any)) != 6 {
		t.Fatalf("unexpected inspect result: %v", d)
	}
	b, _ := json.Marshal(d)
	for _, secret := range []string{"good", "stale", "PRIVATE KEY"} {
		if strings.Contains(string(b), secret) {
			t.Fatalf("inspect leaked credential material %q", secret)
		}
	}
	kinds := map[string]string{}
	for _, c := range d["contexts"].([]any) {
		m := c.(map[string]any)
		kinds[m["name"].(string)] = m["auth"].(string)
	}
	if kinds["cert"] != "client-cert" || kinds["token"] != "token" || kinds["helper"] != "exec" {
		t.Fatalf("auth kinds wrong: %v", kinds)
	}
}

func TestConnectWithClientCertificateFromFile(t *testing.T) {
	_, path, _ := setup(t)
	d, e := call(t, "kube.connect", map[string]any{"path": path, "context": "cert"})
	if e != nil {
		t.Fatal(e)
	}
	if d["user"] != "admin" || d["version"] != "v1.31.0-fake" || d["namespace"] != "shop" {
		t.Fatalf("unexpected connect result: %v", d)
	}
}

func TestConnectWithToken(t *testing.T) {
	_, path, _ := setup(t)
	d, e := call(t, "kube.connect", map[string]any{"path": path, "context": "token"})
	if e != nil || d["user"] != "good" {
		t.Fatalf("token connect: %v %v", d, e)
	}
}

func TestExpiredCredentialsAreAnAuthFailure(t *testing.T) {
	_, path, _ := setup(t)
	_, e := call(t, "kube.connect", map[string]any{"path": path, "context": "expired"})
	if e == nil || e.Kind != "auth" {
		t.Fatalf("want auth failure, got %v", e)
	}
}

func TestUntrustedCertificateIsATLSFailure(t *testing.T) {
	_, path, _ := setup(t)
	_, e := call(t, "kube.connect", map[string]any{"path": path, "context": "wrong-ca"})
	if e == nil || e.Kind != "tls" {
		t.Fatalf("want tls failure, got %v", e)
	}
}

func TestDeniedRBACIsReportedAsRBAC(t *testing.T) {
	_, path, _ := setup(t)
	d, e := call(t, "kube.connect", map[string]any{"path": path, "context": "viewer"})
	if e != nil {
		t.Fatal(e)
	}
	_, e = call(t, "kube.configmap", map[string]any{"session": d["session"], "namespace": "kubefactory", "name": "x"})
	if e == nil || e.Kind != "rbac" {
		t.Fatalf("want rbac failure, got %v", e)
	}
}

func TestUnreachableServer(t *testing.T) {
	dir, _, _ := setup(t)
	l, _ := net.Listen("tcp", "127.0.0.1:0") // a port nobody is listening on once closed
	addr := l.Addr().String()
	l.Close()
	p := filepath.Join(dir, "dead")
	os.WriteFile(p, []byte(kubeconfig("https://"+addr, "")), 0o600)
	_, e := call(t, "kube.connect", map[string]any{"path": p, "context": "token"})
	if e == nil || (e.Kind != "unreachable" && e.Kind != "timeout") {
		t.Fatalf("want unreachable, got %v", e)
	}
}

func TestExecCredentialHelperIsNotRunWithoutApproval(t *testing.T) {
	_, path, _ := setup(t)
	_, e := call(t, "kube.connect", map[string]any{"path": path, "context": "helper"})
	if e == nil || e.Kind != "exec_untrusted" || e.Extra["command"] != "definitely-not-a-real-credential-helper" {
		t.Fatalf("want exec_untrusted naming the helper, got %v", e)
	}
	// approved: now it is attempted (and fails, because the helper does not exist) -
	// the point is that it was only attempted after approval
	_, e = call(t, "kube.connect", map[string]any{"path": path, "context": "helper", "allow_exec": true})
	if e == nil || e.Kind == "exec_untrusted" {
		t.Fatalf("approved helper should have been attempted, got %v", e)
	}
}

func TestPastedConfigNeedsABaseDirForRelativeFiles(t *testing.T) {
	dir, path, _ := setup(t)
	content, _ := os.ReadFile(path)
	_, e := call(t, "kube.connect", map[string]any{"content": string(content), "context": "cert"})
	if e == nil || e.Kind != "needs_base_dir" {
		t.Fatalf("want needs_base_dir, got %v", e)
	}
	d, e := call(t, "kube.connect", map[string]any{"content": string(content), "context": "cert", "base_dir": dir})
	if e != nil || d["user"] != "admin" {
		t.Fatalf("pasted config with base dir: %v %v", d, e)
	}
	// a pasted config that carries everything inline needs no folder
	d, e = call(t, "kube.connect", map[string]any{"content": string(content), "context": "token", "base_dir": dir})
	if e != nil || d["user"] != "good" {
		t.Fatalf("pasted token config: %v %v", d, e)
	}
}

func TestContextsAreIsolated(t *testing.T) {
	_, path, _ := setup(t)
	a, e1 := call(t, "kube.connect", map[string]any{"path": path, "context": "cert"})
	b, e2 := call(t, "kube.connect", map[string]any{"path": path, "context": "viewer"})
	if e1 != nil || e2 != nil || a["session"] == b["session"] {
		t.Fatalf("sessions: %v %v %v %v", a, b, e1, e2)
	}
	// the admin session can read what the viewer session cannot: neither borrows the other's identity
	if _, e := call(t, "kube.configmap", map[string]any{"session": a["session"], "namespace": "n", "name": "x"}); e != nil {
		t.Fatalf("admin session: %v", e)
	}
	if _, e := call(t, "kube.configmap", map[string]any{"session": b["session"], "namespace": "n", "name": "x"}); e == nil || e.Kind != "rbac" {
		t.Fatalf("viewer session should be denied, got %v", e)
	}
	if _, e := call(t, "kube.configmap", map[string]any{"session": "k999", "namespace": "n", "name": "x"}); e == nil || e.Kind != "invalid" {
		t.Fatalf("unknown session should be rejected, got %v", e)
	}
}

func TestBadKubeconfigErrorsDoNotEchoContents(t *testing.T) {
	setup(t)
	_, e := call(t, "kubeconfig.inspect", map[string]any{"content": "users:\n- name: x\n  user: {token: SUPERSECRET\n"})
	if e == nil || e.Kind != "config" || strings.Contains(e.Msg, "SUPERSECRET") {
		t.Fatalf("want a config error without the token in it, got %v", e)
	}
}

func TestParseLs(t *testing.T) {
	es := parseLs(`total 24
drwxr-xr-x    3 999      999           4096 Nov 13 21:19 .
drwxr-xr-x    1 root     root          4096 Nov 13 21:19 ..
-rw-------    1 999      999             88 Nov 13 21:19 postgresql.auto.conf
drwx------    2 999      999           4096 Nov 13  2025 pg wal
lrwxrwxrwx    1 root     root            11 Nov 13 21:19 current -> /etc/passwd
`)
	if len(es) != 3 {
		t.Fatalf("want 3 entries, got %d: %+v", len(es), es)
	}
	if es[0].Name != "postgresql.auto.conf" || es[0].Type != "file" || es[0].Size != 88 {
		t.Fatalf("file entry wrong: %+v", es[0])
	}
	if es[1].Name != "pg wal" || es[1].Type != "dir" {
		t.Fatalf("name with a space wrong: %+v", es[1])
	}
	if es[2].Type != "link" || es[2].Name != "current" || es[2].Link != "/etc/passwd" {
		t.Fatalf("link entry wrong: %+v", es[2])
	}
}

func TestBrowserRefusesNonWebAddresses(t *testing.T) {
	setup(t)
	for _, u := range []string{"file:///C:/Windows/win.ini", "javascript:alert(1)", "ftp://example.com", "not a url"} {
		if _, e := call(t, "browser.open", map[string]any{"url": u}); e == nil || e.Kind != "invalid" {
			t.Fatalf("%q should be refused as invalid, got %v", u, e)
		}
	}
}
