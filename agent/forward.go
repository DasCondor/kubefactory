package main

// Port-forwarding to a pod or to the pods behind a Service. The local end is
// always bound to 127.0.0.1 on a port the OS picks, and every forward is
// closed when its session disconnects or the agent exits.

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/client-go/tools/portforward"
	"k8s.io/client-go/transport/spdy"
)

type forward struct {
	id, session string
	stop        chan struct{}
	local       int
}

var (
	forwards   = map[string]*forward{}
	forwardsMu sync.Mutex
	forwardSeq int
)

func closeForward(id string) {
	forwardsMu.Lock()
	f := forwards[id]
	delete(forwards, id)
	forwardsMu.Unlock()
	if f != nil {
		close(f.stop)
	}
}

func closeForwardsOf(session string) {
	forwardsMu.Lock()
	var ids []string
	for id, f := range forwards {
		if f.session == session {
			ids = append(ids, id)
		}
	}
	forwardsMu.Unlock()
	for _, id := range ids {
		closeForward(id)
	}
}

func closeAllForwards() {
	forwardsMu.Lock()
	var ids []string
	for id := range forwards {
		ids = append(ids, id)
	}
	forwardsMu.Unlock()
	for _, id := range ids {
		closeForward(id)
	}
}

// podFor resolves "a service port" to "a ready pod and its container port".
func (s *session) podFor(ns, service string, port int) (string, int, error) {
	ctx, cancel := ctxTimeout(15)
	defer cancel()
	svc, err := s.cs.CoreV1().Services(ns).Get(ctx, service, metav1.GetOptions{})
	if err != nil {
		return "", 0, err
	}
	if len(svc.Spec.Selector) == 0 {
		return "", 0, fail("unsupported", "service %s has no selector, so there is no pod to forward to", service)
	}
	var sp *corev1.ServicePort
	for i := range svc.Spec.Ports {
		if int(svc.Spec.Ports[i].Port) == port {
			sp = &svc.Spec.Ports[i]
		}
	}
	if sp == nil {
		return "", 0, fail("notfound", "service %s has no port %d", service, port)
	}
	pods, err := s.cs.CoreV1().Pods(ns).List(ctx, metav1.ListOptions{LabelSelector: labels.SelectorFromSet(svc.Spec.Selector).String()})
	if err != nil {
		return "", 0, err
	}
	for _, p := range pods.Items {
		ready := p.Status.Phase == corev1.PodRunning
		for _, c := range p.Status.Conditions {
			if c.Type == corev1.PodReady && c.Status != corev1.ConditionTrue {
				ready = false
			}
		}
		if !ready {
			continue
		}
		target := sp.TargetPort.IntValue()
		if target == 0 && sp.TargetPort.StrVal != "" { // a named container port
			for _, c := range p.Spec.Containers {
				for _, cp := range c.Ports {
					if cp.Name == sp.TargetPort.StrVal {
						target = int(cp.ContainerPort)
					}
				}
			}
		}
		if target == 0 {
			target = port
		}
		return p.Name, target, nil
	}
	return "", 0, fail("unreachable", "service %s has no ready pod behind it", service)
}

func registerForward() {
	ops["kube.forward"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			sessArgs
			Namespace, Service, Pod string
			Port                    int
		}](raw)
		if err != nil {
			return nil, err
		}
		s, err := getSession(a.Session)
		if err != nil {
			return nil, err
		}
		pod, target := a.Pod, a.Port
		if a.Service != "" {
			if pod, target, err = s.podFor(a.Namespace, a.Service, a.Port); err != nil {
				return nil, err
			}
		}
		rt, upgrader, err := spdy.RoundTripperFor(s.cfg)
		if err != nil {
			return nil, err
		}
		url := s.cs.CoreV1().RESTClient().Post().Resource("pods").Namespace(a.Namespace).Name(pod).SubResource("portforward").URL()
		dialer := spdy.NewDialer(upgrader, &http.Client{Transport: rt}, "POST", url)
		stop, ready := make(chan struct{}), make(chan struct{})
		fw, err := portforward.NewOnAddresses(dialer, []string{"127.0.0.1"}, []string{fmt.Sprintf("0:%d", target)}, stop, ready, io.Discard, io.Discard)
		if err != nil {
			return nil, err
		}
		forwardsMu.Lock()
		forwardSeq++
		f := &forward{id: fmt.Sprintf("f%d", forwardSeq), session: s.id, stop: stop}
		forwardsMu.Unlock()
		errc := make(chan error, 1)
		go func() {
			e := fw.ForwardPorts()
			errc <- e
			forwardsMu.Lock()
			_, live := forwards[f.id]
			delete(forwards, f.id)
			forwardsMu.Unlock()
			if live { // it ended on its own (pod gone, connection lost)
				msg := "the forward closed"
				if e != nil {
					msg = strings.SplitN(e.Error(), "\n", 2)[0]
				}
				emit("forward_closed", map[string]any{"forward": f.id, "msg": msg})
			}
		}()
		select {
		case <-ready:
		case e := <-errc:
			if e == nil {
				e = fail("other", "the forward closed before it was ready")
			}
			return nil, e
		}
		ports, err := fw.GetPorts()
		if err != nil || len(ports) == 0 {
			close(stop)
			return nil, fail("other", "could not open a local port")
		}
		f.local = int(ports[0].Local)
		forwardsMu.Lock()
		forwards[f.id] = f
		forwardsMu.Unlock()
		return map[string]any{"forward": f.id, "local_port": f.local, "address": fmt.Sprintf("127.0.0.1:%d", f.local), "pod": pod, "target_port": target}, nil
	}

	ops["kube.forward_stop"] = func(raw json.RawMessage) (any, error) {
		a, _ := decode[struct{ Forward string }](raw)
		closeForward(a.Forward)
		return map[string]any{}, nil
	}
}
