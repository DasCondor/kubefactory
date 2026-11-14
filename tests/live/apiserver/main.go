// A disposable, real Kubernetes API server for testing the companion without
// Docker: the Kubernetes project's own kube-apiserver and etcd, started by
// envtest, with nothing behind them (no nodes, no controllers, no kubelet).
//
// Usage: apiserver <admin-kubeconfig-out> <viewer-kubeconfig-out>
// Prints READY when both files are written; stops when stdin closes.
// KUBEBUILDER_ASSETS must point at the envtest binaries (tools\live-test.ps1 fetches them).
package main

import (
	"bufio"
	"fmt"
	"os"

	"sigs.k8s.io/controller-runtime/pkg/envtest"
)

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: apiserver <admin-kubeconfig> <viewer-kubeconfig>")
		os.Exit(2)
	}
	env := &envtest.Environment{}
	if _, err := env.Start(); err != nil {
		fmt.Fprintln(os.Stderr, "start:", err)
		os.Exit(1)
	}
	defer env.Stop()
	users := []struct {
		out    string
		name   string
		groups []string
	}{
		{os.Args[1], "kf-admin", []string{"system:masters"}},
		{os.Args[2], "kf-nobody", nil}, // authenticated, permitted nothing: for the RBAC path
	}
	for _, u := range users {
		au, err := env.AddUser(envtest.User{Name: u.name, Groups: u.groups}, nil)
		if err == nil {
			var kc []byte
			if kc, err = au.KubeConfig(); err == nil {
				err = os.WriteFile(u.out, kc, 0o600)
			}
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "user:", err)
			env.Stop()
			os.Exit(1)
		}
	}
	fmt.Println("READY")
	bufio.NewReader(os.Stdin).ReadString('\n')
}
