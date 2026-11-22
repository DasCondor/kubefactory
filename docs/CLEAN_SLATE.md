# Clean slate: set up Docker or Kubernetes from nothing

<sub>[KubeFactory](../README.md) · [Host service](HOST_SERVICE.md) · [Known limitations](KNOWN_LIMITATIONS.md#clean-slate)</sub>

No Docker host or cluster yet? **Clean slate** sets one up with you. In the
game, open it from the start menu, the game menu (Esc), or the bottom of
Switch cluster.

1. **This machine.** KubeFactory looks at what is already installed: WSL 2,
   Docker and whether its engine answers, kubectl, kind and its clusters,
   Docker Desktop's Kubernetes, and k3s. This only reads. In the browser demo
   it can't look at your machine, so you pick what to build and take the
   script to the machine you want to set up.
2. **What to build.** Pick one:

   | Target | Windows | Linux |
   |---|---|---|
   | Docker host | WSL 2 and Docker Desktop | Docker Engine (Docker's installer) |
   | Docker Desktop Kubernetes | Docker Desktop, then you turn on its Kubernetes; the script waits | not offered |
   | kind cluster | Docker Desktop, kubectl and kind from winget, then `kind create cluster` | Docker Engine, kubectl and kind (checksums checked), then `kind create cluster` |
   | k3s cluster | k3s inside a WSL distribution that runs systemd | k3s's installer |

   Turn on **Also install the host service** to finish with the
   [host service](HOST_SERVICE.md), set up for what you built.
3. **What the script will do.** The game lists each step and whether it is
   already done on this machine.
4. **Run it yourself.** Press **Save the script** (to your Downloads folder, or
   a browser download in the web demo). Then **Copy** the command and run it in
   an administrator PowerShell, or with `sudo` on Linux. KubeFactory never runs
   anything with admin rights on its own.
5. **When it is done**, press **Check again**, then **Switch cluster** to
   connect to the new Docker engine or cluster.

## The install script

Windows (administrator PowerShell):

```powershell
Invoke-WebRequest https://github.com/DasCondor/kubefactory/releases/latest/download/install-kubefactory.ps1 -OutFile install-kubefactory.ps1
powershell -ExecutionPolicy Bypass -File .\install-kubefactory.ps1 -Plan -Target kind    # the plan only; no admin needed
powershell -ExecutionPolicy Bypass -File .\install-kubefactory.ps1 -Target kind -HostService
```

`-Target` is `docker` (default), `docker-desktop`, `kind` or `k3s`. For k3s,
`-WslDistro <name>` picks the distribution; without it, the first one is used.
`-ClusterName` names the kind cluster (default `kubefactory`). `-Yes` skips the
question. `-ExecutionPolicy Bypass` applies to that one run only; it does not
change your execution policy.

Linux (`sudo`):

```sh
curl -fsSLO https://github.com/DasCondor/kubefactory/releases/latest/download/install-kubefactory.sh
sh install-kubefactory.sh --plan --target k3s      # the plan only; no sudo needed
sudo sh install-kubefactory.sh --target k3s --host-service
```

`--target` is `docker` (default), `k3s` or `kind`.

How the scripts behave:

- **They show the plan first and ask.** Each step is marked done or to do. Only
  the steps marked to do run, so you can run the script again after a restart
  and it carries on from where it stopped.
- **They never elevate themselves.** On Windows the script asks for an
  administrator PowerShell only when a step left to do needs one (WSL,
  Docker Desktop, winget installs, the host service). Making a kind cluster,
  waiting for Docker and setting up k3s in WSL work in a normal PowerShell.
  It names the steps that need admin and changes nothing. On Linux it needs
  sudo.
- **You accept the terms.** winget and Docker Desktop show you their own
  license terms; the script does not accept them for you.
- **Some steps need you.** The script never changes Docker Desktop's settings
  or a WSL distribution's settings. It shows where the switch is and waits, or
  stops and tells you what to do.
- **Downloads are checked.** On Windows, the script checks the companion
  scripts it downloads against the release's `SHA256SUMS`. On Linux it also
  checks kubectl and kind against their published checksums. Docker's and
  k3s's installers come from get.docker.com and get.k3s.io.
- **Kubeconfigs stay yours.** kind adds its context to your kubeconfig. For
  k3s the script saves `~/.kube/kubefactory-k3s.yaml` (on Windows
  `%USERPROFILE%\.kube\kubefactory-k3s.yaml`), and on Linux kind's as
  `~/.kube/kubefactory-kind.yaml`, readable by you only. No credential is
  printed or logged.
- **They never remove anything.**

## With the host service

`-HostService` / `--host-service` runs the host service installer at the end,
set up for the target:

| Target | Host service source |
|---|---|
| Docker host | this machine's Docker engine |
| Docker Desktop Kubernetes (Windows) | the `docker-desktop` context |
| kind, Windows | kind's internal kubeconfig, on kind's Docker network |
| kind, Linux | kind's kubeconfig, on the host network |
| k3s, Linux | k3s's kubeconfig, on the host network |

With k3s on Windows, install the host service inside the Linux distribution
instead (`install-host.sh --source k3s`, which needs Docker there).

## Files

- `setup/install-kubefactory.ps1` and `setup/install-kubefactory.sh`: the
  scripts. The game includes them, and each release publishes them with
  `SHA256SUMS`.
- `scripts/clean_slate.gd`: the machine check, the plan and the commands.
- Tests: `tests/clean_slate_test.gd` (headless),
  `tests/live/clean_slate_ui_test.gd` (the wizard at desktop and phone sizes)
  and `tests/live/clean_slate_kind_test.gd` (after a real kind install: the
  game finds and connects to it).
