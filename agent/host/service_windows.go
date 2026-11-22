//go:build windows

package main

// The Windows service: started by the Service Control Manager at boot
// (delayed), restarted by it if it ever stops unexpectedly.

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"time"

	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000} // CREATE_NO_WINDOW
}

func isWindowsService() bool {
	ok, err := svc.IsWindowsService()
	return err == nil && ok
}

type winService struct{ cfg Config }

func (w winService) Execute(_ []string, req <-chan svc.ChangeRequest, st chan<- svc.Status) (bool, uint32) {
	st <- svc.Status{State: svc.StartPending}
	ctx, cancel := context.WithCancel(context.Background())
	h := newHost(w.cfg)
	done := make(chan error, 1)
	go func() { done <- h.run(ctx) }()
	st <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for {
		select {
		case err := <-done:
			cancel()
			if err != nil {
				return false, 1
			}
			return false, 0
		case c := <-req:
			switch c.Cmd {
			case svc.Interrogate:
				st <- c.CurrentStatus
			case svc.Stop, svc.Shutdown:
				st <- svc.Status{State: svc.StopPending}
				cancel()
				select {
				case <-done:
				case <-time.After(5 * time.Second):
				}
				return false, 0
			}
		}
	}
}

func runAsWindowsService(cfg Config) {
	if err := svc.Run(serviceName, winService{cfg}); err != nil {
		os.Exit(1)
	}
}

func installService(config string) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("%w (run this from an administrator PowerShell)", err)
	}
	defer m.Disconnect()
	if s, err := m.OpenService(serviceName); err == nil {
		s.Close()
		return fmt.Errorf("%s is already installed; run `kf-host uninstall` first", serviceName)
	}
	s, err := m.CreateService(serviceName, exe, mgr.Config{
		DisplayName:      "KubeFactory host service",
		Description:      "Keeps the KubeFactory server container running and its access point online. See docs/HOST_SERVICE.md.",
		StartType:        mgr.StartAutomatic,
		DelayedAutoStart: true,
	}, "--config", config)
	if err != nil {
		return err
	}
	defer s.Close()
	_ = s.SetRecoveryActions([]mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: 10 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 30 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 60 * time.Second},
	}, 86400)
	return s.Start()
}

func uninstallService() error {
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("%w (run this from an administrator PowerShell)", err)
	}
	defer m.Disconnect()
	s, err := m.OpenService(serviceName)
	if err != nil {
		return fmt.Errorf("%s is not installed", serviceName)
	}
	defer s.Close()
	if st, err := s.Query(); err == nil && st.State != svc.Stopped {
		_, _ = s.Control(svc.Stop)
		for i := 0; i < 20; i++ {
			time.Sleep(500 * time.Millisecond)
			if st, err := s.Query(); err != nil || st.State == svc.Stopped {
				break
			}
		}
	}
	return s.Delete()
}
