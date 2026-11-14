package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"sort"
	"strings"
	"sync"
	"time"

	authv1 "k8s.io/api/authentication/v1"
	authzv1 "k8s.io/api/authorization/v1"
	appsv1 "k8s.io/api/apps/v1"
	coordv1 "k8s.io/api/coordination/v1"
	corev1 "k8s.io/api/core/v1"
	policyv1 "k8s.io/api/policy/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/types"
	yamlutil "k8s.io/apimachinery/pkg/util/yaml"
	"k8s.io/client-go/discovery/cached/memory"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/restmapper"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
)

// session is one live connection to one cluster context.
type session struct {
	id      string
	context string
	cfg     *rest.Config
	cs      *kubernetes.Clientset
	dyn     dynamic.Interface
	mapper  *restmapper.DeferredDiscoveryRESTMapper

	mu       sync.Mutex
	factory  informers.SharedInformerFactory
	stop     chan struct{}
	watchNS  string
	watchNod bool
}

var (
	sessions   = map[string]*session{}
	sessionsMu sync.Mutex
	sessionSeq int
)

func getSession(id string) (*session, error) {
	sessionsMu.Lock()
	defer sessionsMu.Unlock()
	s, ok := sessions[id]
	if !ok {
		return nil, fail("invalid", "not connected (unknown session)")
	}
	return s, nil
}

func closeAllSessions() {
	sessionsMu.Lock()
	defer sessionsMu.Unlock()
	for _, s := range sessions {
		s.stopWatch()
	}
	sessions = map[string]*session{}
}

func (s *session) stopWatch() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stop != nil {
		close(s.stop)
		s.stop = nil
		s.factory = nil
	}
}

func ctxTimeout(sec int) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), time.Duration(sec)*time.Second)
}

// classify turns a Go / API error into one of the kinds the UI shows
// separately: authentication, RBAC, TLS, timeout, unreachable.
func classify(err error) *opError {
	msg := strings.SplitN(err.Error(), "\n", 2)[0]
	if len(msg) > 300 {
		msg = msg[:300]
	}
	var ne net.Error
	switch {
	case apierrors.IsUnauthorized(err):
		return &opError{Kind: "auth", Msg: "the cluster rejected these credentials (expired or invalid): " + msg}
	case apierrors.IsForbidden(err):
		return &opError{Kind: "rbac", Msg: msg}
	case apierrors.IsNotFound(err):
		return &opError{Kind: "notfound", Msg: msg}
	case apierrors.IsConflict(err), apierrors.IsAlreadyExists(err):
		return &opError{Kind: "conflict", Msg: msg}
	case apierrors.IsInvalid(err), apierrors.IsBadRequest(err):
		return &opError{Kind: "invalid", Msg: msg}
	case strings.Contains(msg, "x509:"), strings.Contains(msg, "tls:"), strings.Contains(msg, "certificate"):
		return &opError{Kind: "tls", Msg: msg}
	case errors.Is(err, context.DeadlineExceeded), errors.As(err, &ne) && ne.Timeout(), apierrors.IsTimeout(err), apierrors.IsServerTimeout(err):
		return &opError{Kind: "timeout", Msg: "the cluster did not answer in time"}
	case strings.Contains(msg, "connection refused"), strings.Contains(msg, "no such host"), strings.Contains(msg, "actively refused"), strings.Contains(msg, "unreachable"), strings.Contains(msg, "dial tcp"):
		return &opError{Kind: "unreachable", Msg: msg}
	}
	return &opError{Kind: "other", Msg: msg}
}

func kindOf(obj any, kind string) map[string]any {
	b, _ := json.Marshal(obj)
	m := map[string]any{}
	json.Unmarshal(b, &m)
	m["kind"] = kind
	if md, ok := m["metadata"].(map[string]any); ok {
		delete(md, "managedFields")
	}
	return m
}

type sessArgs struct {
	Session string `json:"session"`
}

func registerKube() {
	// Open a connection to one context of a kubeconfig and prove it works.
	ops["kube.connect"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			source
			Context   string `json:"context"`
			AllowExec bool   `json:"allow_exec"`
		}](raw)
		if err != nil {
			return nil, err
		}
		cfg, err := loadConfig(a.source)
		if err != nil {
			return nil, err
		}
		name := a.Context
		if name == "" {
			name = cfg.CurrentContext
		}
		c, ok := cfg.Contexts[name]
		if !ok {
			return nil, fail("config", "this kubeconfig has no context named %q", name)
		}
		if a.Path == "" && a.BaseDir == "" {
			if rel := relativeRefs(cfg, c); len(rel) > 0 {
				return nil, &opError{Kind: "needs_base_dir", Msg: "this pasted kubeconfig refers to files by relative path (" + strings.Join(rel, ", ") + "); choose the folder they are in"}
			}
		}
		if ai, ok := cfg.AuthInfos[c.AuthInfo]; ok {
			kind, cmd := authKind(ai)
			// A kubeconfig can name any program as a credential helper. It is
			// never run unless the user approved this exact helper.
			if (kind == "exec" || kind == "auth-provider") && !a.AllowExec {
				return nil, &opError{Kind: "exec_untrusted", Msg: "this context gets its credentials by running a program: " + cmd,
					Extra: map[string]any{"command": cmd, "context": name}}
			}
		}
		rc, err := clientcmd.NewNonInteractiveClientConfig(*cfg, name, &clientcmd.ConfigOverrides{}, nil).ClientConfig()
		if err != nil {
			return nil, fail("config", "context %q is not usable: %s", name, scrub(err))
		}
		rc.Timeout = 20 * time.Second
		rc.UserAgent = "kubefactory-agent/" + agentVersion
		rc.QPS, rc.Burst = 40, 80
		cs, err := kubernetes.NewForConfig(rc)
		if err != nil {
			return nil, fail("config", "%s", scrub(err))
		}
		ver, err := cs.Discovery().ServerVersion()
		if err != nil {
			return nil, classify(err)
		}
		dyn, err := dynamic.NewForConfig(rc)
		if err != nil {
			return nil, classify(err)
		}
		s := &session{context: name, cfg: rc, cs: cs, dyn: dyn,
			mapper: restmapper.NewDeferredDiscoveryRESTMapper(memory.NewMemCacheClient(cs.Discovery()))}
		sessionsMu.Lock()
		sessionSeq++
		s.id = fmt.Sprintf("k%d", sessionSeq)
		sessions[s.id] = s
		sessionsMu.Unlock()

		res := map[string]any{"session": s.id, "context": name, "server": rc.Host, "version": ver.GitVersion,
			"namespace": c.Namespace, "user": c.AuthInfo, "groups": []string{}}
		ctx, cancel := ctxTimeout(8)
		defer cancel()
		if who, err := cs.AuthenticationV1().SelfSubjectReviews().Create(ctx, &authv1.SelfSubjectReview{}, metav1.CreateOptions{}); err == nil {
			res["user"] = who.Status.UserInfo.Username
			res["groups"] = who.Status.UserInfo.Groups
		}
		return res, nil
	}

	ops["kube.disconnect"] = func(raw json.RawMessage) (any, error) {
		a, _ := decode[sessArgs](raw)
		sessionsMu.Lock()
		s := sessions[a.Session]
		delete(sessions, a.Session)
		sessionsMu.Unlock()
		if s != nil {
			s.stopWatch()
			closeForwardsOf(s.id)
		}
		return map[string]any{}, nil
	}

	// SelfSubjectAccessReview: may I do this? namespace "" means cluster-wide.
	ops["kube.can"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			sessArgs
			Verb, Group, Resource, Subresource, Namespace string
		}](raw)
		if err != nil {
			return nil, err
		}
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		ctx, cancel := ctxTimeout(8)
		defer cancel()
		r, err := s.cs.AuthorizationV1().SelfSubjectAccessReviews().Create(ctx, &authzv1.SelfSubjectAccessReview{
			Spec: authzv1.SelfSubjectAccessReviewSpec{ResourceAttributes: &authzv1.ResourceAttributes{
				Verb: a.Verb, Group: a.Group, Resource: a.Resource, Subresource: a.Subresource, Namespace: a.Namespace}}}, metav1.CreateOptions{})
		if err != nil {
			return nil, err
		}
		return map[string]any{"allowed": r.Status.Allowed}, nil
	}

	// Start list+watch caches (client-go informers reconnect and recover
	// from expired resourceVersions on their own).
	ops["kube.watch"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			sessArgs
			Namespace string `json:"namespace"` // "" = all namespaces
			Nodes     bool   `json:"nodes"`
		}](raw)
		if err != nil {
			return nil, err
		}
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		s.stopWatch()
		s.mu.Lock()
		opts := []informers.SharedInformerOption{}
		if a.Namespace != "" {
			opts = append(opts, informers.WithNamespace(a.Namespace))
		}
		f := informers.NewSharedInformerFactoryWithOptions(s.cs, 0, opts...)
		inf := []cache.SharedIndexInformer{f.Core().V1().Pods().Informer(), f.Core().V1().Services().Informer(),
			f.Apps().V1().Deployments().Informer(), f.Apps().V1().StatefulSets().Informer(), f.Apps().V1().DaemonSets().Informer()}
		if a.Nodes {
			inf = append(inf, f.Core().V1().Nodes().Informer())
		}
		s.factory, s.stop, s.watchNS, s.watchNod = f, make(chan struct{}), a.Namespace, a.Nodes
		stop := s.stop
		s.mu.Unlock()
		f.Start(stop)
		synced := make(chan bool, 1)
		go func() {
			ok := true
			for _, i := range inf {
				ok = cache.WaitForCacheSync(stop, i.HasSynced) && ok
			}
			synced <- ok
		}()
		select {
		case <-synced:
			return map[string]any{"synced": true}, nil
		case <-time.After(15 * time.Second):
			return nil, fail("timeout", "the cluster did not send its state within 15 s")
		}
	}

	// The current state, in the same shape `kubectl get ... -o json` gives.
	ops["kube.list"] = func(raw json.RawMessage) (any, error) {
		a, _ := decode[sessArgs](raw)
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		s.mu.Lock()
		f, nodes := s.factory, s.watchNod
		s.mu.Unlock()
		if f == nil {
			return nil, fail("invalid", "not watching yet")
		}
		items := []map[string]any{}
		all := labels.Everything()
		if nodes {
			l, _ := f.Core().V1().Nodes().Lister().List(all)
			for _, o := range l {
				items = append(items, kindOf(o, "Node"))
			}
		}
		pods, _ := f.Core().V1().Pods().Lister().List(all)
		for _, o := range pods {
			items = append(items, kindOf(o, "Pod"))
		}
		deps, _ := f.Apps().V1().Deployments().Lister().List(all)
		for _, o := range deps {
			items = append(items, kindOf(o, "Deployment"))
		}
		sts, _ := f.Apps().V1().StatefulSets().Lister().List(all)
		for _, o := range sts {
			items = append(items, kindOf(o, "StatefulSet"))
		}
		dss, _ := f.Apps().V1().DaemonSets().Lister().List(all)
		for _, o := range dss {
			items = append(items, kindOf(o, "DaemonSet"))
		}
		svcs, _ := f.Core().V1().Services().Lister().List(all)
		for _, o := range svcs {
			items = append(items, kindOf(o, "Service"))
		}
		return map[string]any{"items": items}, nil
	}

	ops["kube.configmap"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			sessArgs
			Namespace, Name string
		}](raw)
		if err != nil {
			return nil, err
		}
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		ctx, cancel := ctxTimeout(8)
		defer cancel()
		cm, err := s.cs.CoreV1().ConfigMaps(a.Namespace).Get(ctx, a.Name, metav1.GetOptions{})
		if err != nil {
			return nil, err
		}
		return map[string]any{"data": cm.Data}, nil
	}

	ops["kube.scale"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			sessArgs
			Kind, Namespace, Name string
			Replicas              int32
			Delta                 *int32 // relative scaling, safe when two people do it at once
		}](raw)
		if err != nil {
			return nil, err
		}
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		for attempt := 0; attempt < 5; attempt++ {
			ctx, cancel := ctxTimeout(15)
			var cur int32
			var apply func(int32) error
			switch strings.ToLower(a.Kind) {
			case "deployment":
				sc, e := s.cs.AppsV1().Deployments(a.Namespace).GetScale(ctx, a.Name, metav1.GetOptions{})
				if e != nil {
					cancel()
					return nil, e
				}
				cur = sc.Spec.Replicas
				apply = func(n int32) error {
					sc.Spec.Replicas = n
					_, e := s.cs.AppsV1().Deployments(a.Namespace).UpdateScale(ctx, a.Name, sc, metav1.UpdateOptions{})
					return e
				}
			case "statefulset":
				sc, e := s.cs.AppsV1().StatefulSets(a.Namespace).GetScale(ctx, a.Name, metav1.GetOptions{})
				if e != nil {
					cancel()
					return nil, e
				}
				cur = sc.Spec.Replicas
				apply = func(n int32) error {
					sc.Spec.Replicas = n
					_, e := s.cs.AppsV1().StatefulSets(a.Namespace).UpdateScale(ctx, a.Name, sc, metav1.UpdateOptions{})
					return e
				}
			default:
				cancel()
				return nil, fail("unsupported", "%s cannot be scaled", a.Kind)
			}
			n := a.Replicas
			if a.Delta != nil {
				n = cur + *a.Delta
			}
			if n < 0 {
				n = 0
			}
			e := apply(n) // UpdateScale carries the resourceVersion, so a concurrent change is a conflict
			cancel()
			if e == nil {
				return map[string]any{"replicas": n, "msg": fmt.Sprintf("%s/%s scaled to %d", strings.ToLower(a.Kind), a.Name, n)}, nil
			}
			if !apierrors.IsConflict(e) {
				return nil, e
			}
		}
		return nil, fail("conflict", "%s/%s kept changing under us; try again", strings.ToLower(a.Kind), a.Name)
	}

	ops["kube.restart"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			sessArgs
			Kind, Namespace, Name string
		}](raw)
		if err != nil {
			return nil, err
		}
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		patch := []byte(fmt.Sprintf(`{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":%q}}}}}`, time.Now().UTC().Format(time.RFC3339)))
		ctx, cancel := ctxTimeout(20)
		defer cancel()
		switch strings.ToLower(a.Kind) {
		case "deployment":
			_, err = s.cs.AppsV1().Deployments(a.Namespace).Patch(ctx, a.Name, types.StrategicMergePatchType, patch, metav1.PatchOptions{})
		case "statefulset":
			_, err = s.cs.AppsV1().StatefulSets(a.Namespace).Patch(ctx, a.Name, types.StrategicMergePatchType, patch, metav1.PatchOptions{})
		case "daemonset":
			_, err = s.cs.AppsV1().DaemonSets(a.Namespace).Patch(ctx, a.Name, types.StrategicMergePatchType, patch, metav1.PatchOptions{})
		default:
			return nil, fail("unsupported", "%s cannot be restarted", a.Kind)
		}
		if err != nil {
			return nil, err
		}
		return map[string]any{"msg": fmt.Sprintf("%s/%s restarted", strings.ToLower(a.Kind), a.Name)}, nil
	}

	ops["kube.delete"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			sessArgs
			Kind, Namespace, Name string
		}](raw)
		if err != nil {
			return nil, err
		}
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		ctx, cancel := ctxTimeout(20)
		defer cancel()
		bg := metav1.DeletePropagationBackground
		o := metav1.DeleteOptions{PropagationPolicy: &bg}
		switch strings.ToLower(a.Kind) {
		case "pod":
			err = s.cs.CoreV1().Pods(a.Namespace).Delete(ctx, a.Name, o)
		case "deployment":
			err = s.cs.AppsV1().Deployments(a.Namespace).Delete(ctx, a.Name, o)
		case "statefulset":
			err = s.cs.AppsV1().StatefulSets(a.Namespace).Delete(ctx, a.Name, o)
		case "daemonset":
			err = s.cs.AppsV1().DaemonSets(a.Namespace).Delete(ctx, a.Name, o)
		case "service":
			err = s.cs.CoreV1().Services(a.Namespace).Delete(ctx, a.Name, o)
		case "lease":
			err = s.cs.CoordinationV1().Leases(a.Namespace).Delete(ctx, a.Name, o)
		default:
			return nil, fail("unsupported", "deleting a %s is not something this game does", a.Kind)
		}
		if err != nil && !apierrors.IsNotFound(err) {
			return nil, err
		}
		return map[string]any{"msg": fmt.Sprintf("%s %q deleted", strings.ToLower(a.Kind), a.Name)}, nil
	}

	ops["kube.create_deployment"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			sessArgs
			Namespace, Name, Image string
			Replicas               int32
		}](raw)
		if err != nil {
			return nil, err
		}
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		lbl := map[string]string{"app": a.Name}
		d := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: a.Name, Labels: lbl},
			Spec: appsv1.DeploymentSpec{Replicas: &a.Replicas, Selector: &metav1.LabelSelector{MatchLabels: lbl},
				Template: corev1.PodTemplateSpec{ObjectMeta: metav1.ObjectMeta{Labels: lbl},
					Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: a.Name, Image: a.Image}}}}}}
		ctx, cancel := ctxTimeout(20)
		defer cancel()
		if _, err := s.cs.AppsV1().Deployments(a.Namespace).Create(ctx, d, metav1.CreateOptions{}); err != nil {
			return nil, err
		}
		return map[string]any{"msg": fmt.Sprintf("deployment.apps/%s created", a.Name)}, nil
	}

	ops["kube.cordon"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			sessArgs
			Node string
			On   bool
		}](raw)
		if err != nil {
			return nil, err
		}
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		if err := s.cordon(a.Node, a.On); err != nil {
			return nil, err
		}
		word := "uncordoned"
		if a.On {
			word = "cordoned"
		}
		return map[string]any{"msg": fmt.Sprintf("node/%s %s", a.Node, word)}, nil
	}

	// Cordon the node, then evict every pod on it except DaemonSet and
	// mirror pods (the same as `kubectl drain --ignore-daemonsets
	// --delete-emptydir-data`). Evictions honour PodDisruptionBudgets.
	ops["kube.drain"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			sessArgs
			Node string
		}](raw)
		if err != nil {
			return nil, err
		}
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		if err := s.cordon(a.Node, true); err != nil {
			return nil, err
		}
		ctx, cancel := ctxTimeout(90)
		defer cancel()
		pods, err := s.cs.CoreV1().Pods("").List(ctx, metav1.ListOptions{FieldSelector: "spec.nodeName=" + a.Node})
		if err != nil {
			return nil, err
		}
		evicted, blocked := 0, 0
		for _, p := range pods.Items {
			if _, mirror := p.Annotations["kubernetes.io/config.mirror"]; mirror {
				continue
			}
			ds := false
			for _, o := range p.OwnerReferences {
				ds = ds || o.Kind == "DaemonSet"
			}
			if ds || p.DeletionTimestamp != nil {
				continue
			}
			e := s.cs.PolicyV1().Evictions(p.Namespace).Evict(ctx, &policyv1.Eviction{ObjectMeta: metav1.ObjectMeta{Name: p.Name, Namespace: p.Namespace}})
			if e == nil || apierrors.IsNotFound(e) {
				evicted++
			} else {
				blocked++
			}
		}
		msg := fmt.Sprintf("node/%s drained (%d pods evicted)", a.Node, evicted)
		if blocked > 0 {
			msg = fmt.Sprintf("node/%s cordoned; %d pods evicted, %d held back by a disruption budget", a.Node, evicted, blocked)
		}
		return map[string]any{"msg": msg}, nil
	}

	ops["kube.logs"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			sessArgs
			Namespace, Pod, Container string
			Tail                      int64
			Previous                  bool
		}](raw)
		if err != nil {
			return nil, err
		}
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		if a.Tail <= 0 || a.Tail > 5000 {
			a.Tail = 150
		}
		limit := int64(2 << 20) // never pull more than 2 MB of log into the game
		ctx, cancel := ctxTimeout(20)
		defer cancel()
		rc, err := s.cs.CoreV1().Pods(a.Namespace).GetLogs(a.Pod, &corev1.PodLogOptions{Container: a.Container, TailLines: &a.Tail, Previous: a.Previous, LimitBytes: &limit}).Stream(ctx)
		if err != nil {
			return nil, err
		}
		defer rc.Close()
		b, _ := io.ReadAll(io.LimitReader(rc, limit))
		return map[string]any{"text": string(b)}, nil
	}

	// Events as the same table kubectl prints (LAST, [NAMESPACE,] TYPE, REASON, [OBJECT,] MESSAGE).
	ops["kube.events"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			sessArgs
			Namespace, Name string
			Warnings, Wide  bool
		}](raw)
		if err != nil {
			return nil, err
		}
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		sel := []string{}
		if a.Name != "" {
			sel = append(sel, "involvedObject.name="+a.Name)
		}
		if a.Warnings {
			sel = append(sel, "type=Warning")
		}
		ctx, cancel := ctxTimeout(20)
		defer cancel()
		evs, err := s.cs.CoreV1().Events(a.Namespace).List(ctx, metav1.ListOptions{FieldSelector: strings.Join(sel, ","), Limit: 2000})
		if err != nil {
			return nil, err
		}
		last := func(e *corev1.Event) time.Time {
			if !e.LastTimestamp.IsZero() {
				return e.LastTimestamp.Time
			}
			if !e.EventTime.IsZero() {
				return e.EventTime.Time
			}
			return e.CreationTimestamp.Time
		}
		sort.Slice(evs.Items, func(i, j int) bool { return last(&evs.Items[i]).Before(last(&evs.Items[j])) })
		if len(evs.Items) > 300 {
			evs.Items = evs.Items[len(evs.Items)-300:]
		}
		var b strings.Builder
		if a.Wide {
			b.WriteString("LAST                   NAMESPACE      TYPE      REASON      OBJECT                   MESSAGE\n")
		} else {
			b.WriteString("LAST                   TYPE      REASON      MESSAGE\n")
		}
		for i := range evs.Items {
			e := &evs.Items[i]
			ts := last(e).UTC().Format("2006-01-02T15:04:05Z")
			msg := strings.ReplaceAll(e.Message, "\n", " ")
			if a.Wide {
				fmt.Fprintf(&b, "%-22s %-14s %-9s %-11s %-24s %s\n", ts, e.Namespace, e.Type, e.Reason, e.InvolvedObject.Name, msg)
			} else {
				fmt.Fprintf(&b, "%-22s %-9s %-11s %s\n", ts, e.Type, e.Reason, msg)
			}
		}
		return map[string]any{"text": b.String()}, nil
	}

	ops["kube.ensure_namespace"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			sessArgs
			Namespace string
		}](raw)
		if err != nil {
			return nil, err
		}
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		ctx, cancel := ctxTimeout(15)
		defer cancel()
		_, err = s.cs.CoreV1().Namespaces().Create(ctx, &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: a.Namespace}}, metav1.CreateOptions{})
		if err != nil && !apierrors.IsAlreadyExists(err) {
			return nil, err
		}
		return map[string]any{}, nil
	}

	// A secret created from a value sent over the pipe: it never touches a
	// command line or a file. Returns created=false if one already existed.
	ops["kube.create_secret"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			sessArgs
			Namespace, Name, Key, Value string
		}](raw)
		if err != nil {
			return nil, err
		}
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		ctx, cancel := ctxTimeout(15)
		defer cancel()
		_, err = s.cs.CoreV1().Secrets(a.Namespace).Create(ctx, &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: a.Name},
			StringData: map[string]string{a.Key: a.Value}}, metav1.CreateOptions{})
		if apierrors.IsAlreadyExists(err) {
			return map[string]any{"created": false}, nil
		}
		if err != nil {
			return nil, err
		}
		return map[string]any{"created": true}, nil
	}

	// Apply or delete every object in a (multi-document) manifest. Apply is
	// server-side apply; dry_run asks the API server to validate only.
	manifest := func(del bool) handler {
		return func(raw json.RawMessage) (any, error) {
			a, err := decode[struct {
				sessArgs
				Namespace, Yaml string
				DryRun          bool `json:"dry_run"`
			}](raw)
			if err != nil {
				return nil, err
			}
			s, err := getSession(a.Session)
			if err != nil {
				return nil, err
			}
			dec := yamlutil.NewYAMLOrJSONDecoder(bufio.NewReader(strings.NewReader(a.Yaml)), 4096)
			var done []string
			for {
				obj := &unstructured.Unstructured{}
				if e := dec.Decode(obj); e != nil {
					if e == io.EOF {
						break
					}
					return nil, fail("invalid", "the manifest is not valid YAML: %s", scrub(e))
				}
				if len(obj.Object) == 0 {
					continue
				}
				gvk := obj.GroupVersionKind()
				m, e := s.mapper.RESTMapping(gvk.GroupKind(), gvk.Version)
				if e != nil {
					s.mapper.Reset()
					if m, e = s.mapper.RESTMapping(gvk.GroupKind(), gvk.Version); e != nil {
						return nil, fail("unsupported", "this cluster has no %s (%s)", gvk.Kind, gvk.GroupVersion())
					}
				}
				var ri dynamic.ResourceInterface = s.dyn.Resource(m.Resource)
				if m.Scope.Name() == meta.RESTScopeNameNamespace {
					ns := obj.GetNamespace()
					if ns == "" {
						ns = a.Namespace
					}
					if ns == "" {
						ns = "default"
					}
					obj.SetNamespace(ns)
					ri = s.dyn.Resource(m.Resource).Namespace(ns)
				}
				ctx, cancel := ctxTimeout(30)
				name := strings.ToLower(gvk.Kind) + "/" + obj.GetName()
				if del {
					bg := metav1.DeletePropagationBackground
					e = ri.Delete(ctx, obj.GetName(), metav1.DeleteOptions{PropagationPolicy: &bg})
					if apierrors.IsNotFound(e) {
						e = nil
					}
				} else {
					force := true
					o := metav1.ApplyOptions{FieldManager: "kubefactory", Force: force}
					if a.DryRun {
						o.DryRun = []string{metav1.DryRunAll}
					}
					_, e = ri.Apply(ctx, obj.GetName(), obj, o)
				}
				cancel()
				if e != nil {
					oe := classify(e)
					oe.Msg = name + ": " + oe.Msg
					return nil, oe
				}
				done = append(done, name)
			}
			return map[string]any{"objects": done}, nil
		}
	}
	ops["kube.apply"] = manifest(false)
	ops["kube.delete_manifest"] = manifest(true)

	// Multi-user presence: renew my Lease, list everyone else's, read the shared action feed.
	ops["kube.presence"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			sessArgs
			Lease, User, Holder, Pos, Tool, Doing string
		}](raw)
		if err != nil {
			return nil, err
		}
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		const ns = "kubefactory"
		ctx, cancel := ctxTimeout(8)
		defer cancel()
		now := metav1.NowMicro()
		dur := int32(15)
		want := &coordv1.Lease{ObjectMeta: metav1.ObjectMeta{Name: a.Lease, Namespace: ns, Labels: map[string]string{"app": "kubefactory"},
			Annotations: map[string]string{"kubefactory/user": a.User, "kubefactory/pos": a.Pos, "kubefactory/tool": a.Tool, "kubefactory/doing": a.Doing}},
			Spec: coordv1.LeaseSpec{HolderIdentity: &a.Holder, RenewTime: &now, LeaseDurationSeconds: &dur}}
		leases := s.cs.CoordinationV1().Leases(ns)
		if cur, e := leases.Get(ctx, a.Lease, metav1.GetOptions{}); e == nil {
			want.ResourceVersion = cur.ResourceVersion
			_, err = leases.Update(ctx, want, metav1.UpdateOptions{})
		} else if apierrors.IsNotFound(e) {
			_, err = leases.Create(ctx, want, metav1.CreateOptions{})
		} else {
			err = e
		}
		if err != nil {
			return nil, err
		}
		peers := []map[string]any{}
		if l, e := leases.List(ctx, metav1.ListOptions{LabelSelector: "app=kubefactory"}); e == nil {
			for _, it := range l.Items {
				if it.Name == a.Lease || it.Spec.RenewTime == nil || time.Since(it.Spec.RenewTime.Time) > 30*time.Second {
					continue
				}
				an := it.Annotations
				peers = append(peers, map[string]any{"id": it.Name, "user": an["kubefactory/user"], "pos": an["kubefactory/pos"], "tool": an["kubefactory/tool"], "doing": an["kubefactory/doing"]})
			}
		}
		events := []map[string]any{}
		if l, e := s.cs.CoreV1().Events(ns).List(ctx, metav1.ListOptions{FieldSelector: "reason=KubeFactory"}); e == nil {
			for _, it := range l.Items {
				events = append(events, map[string]any{"id": it.Name, "user": it.Annotations["kubefactory/user"], "msg": it.Message,
					"ok": it.Type != "Warning", "time": it.LastTimestamp.Unix()})
			}
		}
		return map[string]any{"peers": peers, "events": events}, nil
	}

	ops["kube.post_event"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			sessArgs
			Lease, User, Msg string
			Ok               bool
		}](raw)
		if err != nil {
			return nil, err
		}
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		typ := "Normal"
		if !a.Ok {
			typ = "Warning"
		}
		now := metav1.Now()
		ctx, cancel := ctxTimeout(8)
		defer cancel()
		_, err = s.cs.CoreV1().Events("kubefactory").Create(ctx, &corev1.Event{
			ObjectMeta:     metav1.ObjectMeta{GenerateName: "kf-", Namespace: "kubefactory", Annotations: map[string]string{"kubefactory/user": a.User}},
			InvolvedObject: corev1.ObjectReference{APIVersion: "coordination.k8s.io/v1", Kind: "Lease", Name: a.Lease, Namespace: "kubefactory"},
			Reason:         "KubeFactory", Message: a.Msg, Type: typ, FirstTimestamp: now, LastTimestamp: now,
			Source: corev1.EventSource{Component: "kubefactory"}}, metav1.CreateOptions{})
		if err != nil {
			return nil, err
		}
		return map[string]any{}, nil
	}
}

func (s *session) cordon(node string, on bool) error {
	patch := []byte(fmt.Sprintf(`{"spec":{"unschedulable":%t}}`, on))
	ctx, cancel := ctxTimeout(15)
	defer cancel()
	_, err := s.cs.CoreV1().Nodes().Patch(ctx, node, types.StrategicMergePatchType, patch, metav1.PatchOptions{})
	return err
}

var _ = bytes.NewReader
