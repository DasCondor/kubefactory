//go:build !windows

package main

// The Linux service: a systemd unit that runs `kf-host run`. It does not
// require docker.service, so it stays up (and keeps its access point open)
// while Docker or Kubernetes restart.

import (
	"fmt"
	"os"
	"os/exec"
)

const unitPath = "/etc/systemd/system/kubefactory-host.service"

func hideWindow(*exec.Cmd)       {}
func isWindowsService() bool     { return false }
func runAsWindowsService(Config) {}

func unitFile(exe, config string) string {
	return fmt.Sprintf(`[Unit]
Description=KubeFactory host service (keeps the KubeFactory server container running)
Documentation=https://github.com/DasCondor/kubefactory/blob/main/docs/HOST_SERVICE.md
After=network-online.target docker.service
Wants=network-online.target

[Service]
ExecStart=%s run --config %s
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
`, exe, config)
}

func systemctl(args ...string) error {
	out, err := exec.Command("systemctl", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("systemctl %v: %s", args, out)
	}
	return nil
}

func installService(config string) error {
	if os.Geteuid() != 0 {
		return fmt.Errorf("run this with sudo")
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	if _, err := os.Stat(unitPath); err == nil {
		return fmt.Errorf("%s exists; run `kf-host uninstall` first", unitPath)
	}
	if err := os.WriteFile(unitPath, []byte(unitFile(exe, config)), 0o644); err != nil {
		return err
	}
	if err := systemctl("daemon-reload"); err != nil {
		return err
	}
	return systemctl("enable", "--now", "kubefactory-host.service")
}

func uninstallService() error {
	if os.Geteuid() != 0 {
		return fmt.Errorf("run this with sudo")
	}
	if _, err := os.Stat(unitPath); err != nil {
		return fmt.Errorf("kubefactory-host is not installed")
	}
	_ = systemctl("disable", "--now", "kubefactory-host.service")
	if err := os.Remove(unitPath); err != nil {
		return err
	}
	return systemctl("daemon-reload")
}
