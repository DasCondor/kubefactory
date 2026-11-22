# KubeFactory host service (high availability)

<sub>[KubeFactory](../README.md) · [Server mode](SERVER.md) · [Known limitations](KNOWN_LIMITATIONS.md#host-service)</sub>

KubeFactory can be deployed four ways:

| Deployment | What runs | Who it is for |
|---|---|---|
| Desktop | the game on your computer, connected to your cluster or Docker | one person |
| Server mode | the game headless next to the cluster; players connect with tokens ([SERVER.md](SERVER.md)) | a team, run by hand |
| **Host service** | a system service that keeps the server running in a container, with an access point that stays online | a team, always on |
| Browser demo | simulated worlds only, connected to nothing | trying it out |

The host service, **kf-host**, is installed on each Docker host or cluster node
as a Windows service or a systemd unit. It does two things.

- **Keeps the server running.** Every 30 seconds it checks that Docker answers,
  that the server's data volume (and network, if set) exist, and that the
  KubeFactory server container is running and accepting connections. It creates
  whatever is missing and starts whatever stopped. If the server refuses
  connections three checks in a row, it restarts it. If you change `host.json`,
  it recreates the container with the new settings.
- **Keeps players connected.** Players connect to kf-host's access point, not to
  the container. When the container, Docker or Kubernetes restarts, the
  connection stays open. The game keeps the last state on screen and its status
  line says *server restarting, last known state*. Actions are refused with "the
  server is restarting; nothing was done". When the server is back, kf-host
  signs the player in again and live data flows.

```
 players ──ws/wss──▶ kf-host access point (:7666, on the host, always up)
                          │  passes messages through; holds players while the server is away
                          ▼
              127.0.0.1:17666 ──▶ KubeFactory server container  (checked every 30 s)
                                       └─ data volume: token hashes, audit log
```

## Install

Windows: run from an **administrator** PowerShell. The script does not elevate
itself. Download it, read it, then run it:

```powershell
Invoke-WebRequest https://github.com/DasCondor/kubefactory/releases/latest/download/install-host.ps1 -OutFile install-host.ps1
.\install-host.ps1                     # demo server
.\install-host.ps1 -Source docker      # this machine's Docker engine
.\install-host.ps1 -Source kube -Kubeconfig C:\kf\viewer.yaml
.\install-host.ps1 -Source kube -Kubeconfig C:\kf\kind-internal.yaml -Network kind
```

Linux (systemd), with sudo:

```sh
curl -fsSLO https://github.com/DasCondor/kubefactory/releases/latest/download/install-host.sh
sudo sh install-host.sh                        # demo server
sudo sh install-host.sh --source docker        # this machine's Docker engine
sudo sh install-host.sh --source k3s           # the k3s cluster on this node
sudo sh install-host.sh --source kube --kubeconfig /root/kf-viewer.yaml
```

No Docker yet? [Clean slate](CLEAN_SLATE.md) installs Docker or a cluster
first and can finish with the host service.

Both download `kf-host` from the same release and check it against the
release's `SHA256SUMS` before installing it. The service needs Docker on the
machine. Releases from 2.2 on carry these files. Before that, build them
yourself (below).

The first start creates two tokens inside the server's data volume. Read them
once, hand each to one person, then delete the file:

```sh
docker exec kubefactory-server cat /data/server-new-tokens.txt
docker exec kubefactory-server rm /data/server-new-tokens.txt
```

In the game: Esc > Switch cluster > **KubeFactory server...**, address
`ws://<host>:7666`, and your token.

## Settings: host.json

Windows: `C:\ProgramData\KubeFactory\Host\host.json`. Linux:
`/etc/kubefactory/host.json`. The installer writes it once and keeps it after
that. Edit it and the next check applies it.

| Key | Default | Meaning |
|---|---|---|
| `container` | `kubefactory-server` | the container kf-host manages |
| `image` | `ghcr.io/dascondor/kubefactory-server:latest` | the server image |
| `pull` | `true` | pull the image when it is missing |
| `source` | `["--demo"]` | KubeFactory source options (`--docker`, `--kubeconfig=...`, `--context=...`) |
| `read_only` | `false` | start the server with `--read-only` |
| `volume` | `kubefactory-server-data` | the server's data: token hashes and audit log |
| `mounts` | `[]` | host paths to share, e.g. the Docker socket or a kubeconfig folder |
| `network` / `host_network` | none / `false` | a Docker network to attach, or (Linux) the host's network to reach an API server on 127.0.0.1 |
| `user` / `group_add` | image default / none | run as another user, or add a group (e.g. the Docker socket's) |
| `env` | `[]` | extra `NAME=value`; names that look like secrets are refused |
| `internal_port` | `17666` | where the server is published, on 127.0.0.1 only |
| `listen` | `127.0.0.1:7666` | the access point |
| `tls_cert` / `tls_key` | none | `wss://` on the access point |
| `interval_seconds` | `30` | how often kf-host checks |
| `docker` | `docker` on PATH | the Docker CLI to use |

kf-host only changes containers, volumes and networks that carry its label
`io.kubefactory.managed=host`. If a container with the configured name exists
without that label, kf-host leaves it alone and reports it.

## Day to day

```
kf-host status       the last check and the last 20 that changed something
kf-host check        one check now
kf-host validate     the settings as the service reads them
```

The log is `host.log` beside the settings on Windows, and
`journalctl -u kubefactory-host` on Linux. kf-host also answers
`http://<access point>/kf-host/status` with the same status as JSON. It has no
token or other secret in it.

Uninstall: `.\install-host.ps1 -Uninstall` or `sudo sh install-host.sh
--uninstall`. Add `-RemoveContainer` / `--remove-container` to remove the
server container too. Its data volume is kept.

## More than one node

Install kf-host on each node you want players to reach. Each node runs its own
server and access point. Players use whichever node they can reach, and if one
node goes down they switch to another. Each server makes its own tokens. To
use the same tokens on every node, copy `server-tokens.json` (hashes only)
into each data volume.

## Security

- No credential is in `host.json`, the log or the status. The Docker socket or a
  kubeconfig reaches the server only as a mount the admin chose. The installer
  copies a kubeconfig into a folder only administrators (Windows) or the
  container's user (Linux) can read.
- A Docker source gives the server container control of Docker. Players still
  act only through their token's role, checked by the server.
- While a player is connected, the access point keeps their sign-in message,
  token included, in memory. That lets it sign them in again after a restart.
  It is never logged or written to disk, and it is dropped when they disconnect.
- The access point listens on 127.0.0.1 by default. To reach it from other
  machines, use `tls_cert`/`tls_key`, an SSH tunnel or a TLS reverse proxy.
  Plain `ws://` on a network address sends tokens unencrypted, and the
  installers warn about it.
- The installers never elevate themselves. kf-host never adds a mount, a user
  or a network on its own.

## Building it yourself

```powershell
tools\build-server-image.ps1                     # kubefactory-server:dev
cd agent; go build -o bin\kf-host.exe .\host     # or GOOS=linux for Linux
.\deploy\host\install-host.ps1 -Binary agent\bin\kf-host.exe -Image kubefactory-server:dev -NoPull
```

Test: `tests/live/host_service_docker_test.gd` runs kf-host against this
machine's Docker, using throw-away names only.
