# Changelog

<sub>[KubeFactory](../README.md) · [All docs](../README.md#-docs-by-topic) · [2.0.0-beta.3 pre-release](https://github.com/DasCondor/kubefactory/releases/tag/v2.0.0-beta.3) · [Known limitations](KNOWN_LIMITATIONS.md)</sub>

## Unreleased

### Added

- The Connection Whiteboard is in every demo world, not only the Docker media
  lab: the Kubernetes cluster, Home Assistant, Dev containers and Media suite
  demos open it from the pause menu (Connection whiteboard; Whiteboard on
  phones) and from Network and shared data. Home Assistant and Dev containers
  gained their simulated routes (MQTT, Z-Wave, Matter, Frigate, voice and
  recorder; Git, CI, BuildKit, registry, caches and artifacts), so they also
  show pipes in the factory. Replicas get their own card positions, so cards no
  longer stack on top of each other.

- The Docker media lab's gathering node can use Prowlarr instead of Jackett:
  set `indexer` in `media-lab.json`, or press **Use Prowlarr instead** in the
  Docker media lab menu (the demo world restarts). Sonarr and Radarr search
  through Prowlarr, Prowlarr pushes its indexers into them, it has its own
  config volume, and it reaches the internet only through Gluetun.

### Fixed

- The Krew hold their tools properly. Gauge's, Blueprint's and every Foreman's
  tablet floated 18 cm in front of the hand on a small bracket; it now sits in
  the fist, fingers over its lower edge, at all three detail levels. The LM
  Studio Foreman's laptop rests on the fingers instead of hovering above them.
  In the browser's Standard preset, Foreman holds his tablet at the hand, Bob's
  wrench hangs from his fist and his cane's handle is in his hand, and Blueprint
  holds its board with both hands. `tools/fix_held_items.py --check` reports any
  prop that floats again.

## 2.0.0-beta.3 (2026-11-17)

### Added

- Every demo machine has a simulated dashboard. The media world's Heimdall
  directory opens those dashboards and keeps a recent failure list with links
  to Bob's diagnosis. An image-updater pod offers sample updates with approval.
- Cluster Codex includes a network and shared-data view and an editable,
  locally saved flowchart with media and online-shop presets.
- Ports and Readiness shows configured Service ports and host bindings beside
  backend readiness. Each demo dashboard has a Ports tab, and app overviews
  show container state and the app's VPN route.
- Shared Disk Space lists the containers mounting the same backing volume and
  reports used and free space once per demo volume. The shared-disk view also
  appears on demo dashboards.
- Media demo pipes show app calls, metrics, file imports and VPN egress.
  In the Jellyfin demo, Sonarr, Radarr, and Prowlarr use a shared Gluetun
  gateway. The other downloaders and search apps use their own sidecars.
  Downloads and library data occupy separate simulated claims. Prometheus
  scrapes a simulated exporter beside Tautulli, which reads playback from Plex.
- Simulated segments and flowchart nodes support VLAN IDs. Live views display
  declared VLAN IDs from the `kubefactory.io/vlan-id` annotation and show
  reported Multus attachments. Live enforcement uses the cluster's own CNI,
  network policies and VPN configuration. The flowchart saves a local plan.
- Pipe trunks follow aisles to clear neighboring risers, with slimmer
  fittings and flow collars. Network filters preserve pipe positions. Pod
  ports align to machine roofs. Service depots have
  one pillar for internal Services and two for external Services. The crosshair
  explains each. The Escape menu scrolls within the viewport.
- Pod-side pillars sit flush on the platform and identify their container and
  status when aimed at. Up to four containers per pod have pillars. VPN units
  are mounted directly to their pod roofs.
- The bundled media setup includes a Heimdall service. The in-game failure
  directory and image-update exercise are available in the simulation.
- **Container logs over a Komodo connection.** A machine's panel, the
  logging station and Bob read a container's log through Komodo
  (`GetContainerLog`, still a read request; up to Komodo's 5000 lines).
  Komodo wants the key's user to have the **Logs** permission on the server
  on top of Read; without it the panel says so instead of showing nothing.
  Komodo keeps no events for a container, so that choice says that too.
  Tests: `agent/komodo_test.go`, `tests/live/komodo_test.gd`.

### Fixed

- Startup shows the KubeFactory menu. The browser lets players pick a graphics
  preset and shows loading progress before the demo opens.
- Phone menus keep Back and Close within reach, with shortcuts to demos,
  settings, dashboards and network views. The dashboard picker starts with the
  complete list and accepts input from the phone keyboard on the web.
- The browser fits the canvas, HUD, held tools and touch controls to the phone
  viewport, including after rotation. Large scenes use single-threaded culling
  in the Godot 4.3 web build.
- VPN pipes enter labeled ports on the factory side of the Internet Output
  station. One WWW outlet leaves from the public side. The VPN panel lists each
  gateway's apps and can trace one, several, or all gateways in the factory.
- Turning a phone cancels held touches and refits the open menu or dashboard.
  The browser demo uses the browser's default safe area around screen notches.

- Opening a demo leaves the native companion stopped until the operator
  requests a local feature such as connection discovery or Foreman.

## 2.0.0-beta.2 (2026-11-15)

A beta: not a stable release. Everything since beta.1 is below: phone menus,
the browser's High preset fixed on the site, Service pipelines, the Jellyfin +
VPN stack with VPN tunnels, the text editor, free Windows signing (wired, not
active yet), and fixes.

### Not fully supported or tested

Status words as everywhere: **verified live** (real infrastructure),
**verified in simulation**, **not tested**.

| Feature | Status | What is missing |
|---|---|---|
| Windows code signing (SignPath Foundation) | wired, **not active** | needs SignPath's approval and two settings ([CODE_SIGNING](CODE_SIGNING.md)); these packages are unsigned |
| macOS packages | startup smoke test on Apple Silicon only | not played on a Mac; Intel untested; not notarized |
| Linux packages | headless in a container | not played on a Linux desktop with a GPU |
| Provider, AI and Komodo keys on Linux and macOS | **unsupported** | refused there (Windows' protection only); never stored in the clear |
| Foreman with an AI provider | verified in simulation (mock) | no real Ollama, LM Studio, OpenAI or Claude |
| Komodo | requests checked against a real Core 2.3.4 by a contributor | not played against a real Core; the 2.3 name and its fallback tested on stand-ins only |
| Cloud Kubernetes (EKS, AKS, GKE), Rancher, OpenShift | **not tested** | k3s reported working by a user, not tested here |
| Metrics API figures (Gauge, Metrics view) | **not tested** | only "no metrics API" seen live |
| Server mode | verified in simulation (one machine, `ws://`) | `wss://` and a second machine |
| Physical controller | simulated input only | dead zone and speeds not tuned on a real pad |
| Phone and tablet menus | verified in simulation at phone and tablet sizes | not yet tried on a real iPhone or Android phone |
| Browser High preset | verified on the deployed site (desktop browser) | not measured on phones |
| Service pipelines | verified in simulation, all presets | built from **V2** library models ("legacy geometry"); not reviewed piece by piece for clipping |
| VPN tunnels: inside and outside addresses | verified live on throw-away stand-in containers | not with a real VPN account; outside address **not read on Kubernetes** or through the read-only Docker proxy |
| VPN "Check now" | **not tested** against a real VPN | asks ipinfo.io from inside the container, on request |
| VPN images other than Gluetun | recognised by name and settings from their docs | only Gluetun and a binhex-style stand-in were run |
| Porter's Jellyfin + VPN stack | Compose checked with `docker compose config`, Kubernetes file parsed | never run with a real VPN account |
| Text editor | verified in simulation with real key events | Vim and Nano are everyday subsets (no counts, visual mode, macros); YAML is saved unchecked; the System theme falls back to dark where Godot cannot read it |
| Storage inspection on distroless images | **not tested** | |
| LiveView through a Kubernetes port-forward | **not tested** | port-forward itself verified live |
| Tautulli stream counts | verified in simulation | needs a Plex server playing something |
| Backend plugins | verified with the example plugin only | |

The full list, with details, is in [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md).

### Fixed
- **Menus on phones are readable.** The browser demo now switches to touch
  controls as soon as it opens on a phone or tablet: an iPhone's taps reached
  the game as mouse clicks, so the desktop layout stayed up. Dialogs on a
  touch screen fill the screen's width with sharp, enlarged text (the
  interface scale, not a scaled picture) and scroll when taller; on a phone
  held upright they are drawn sideways, at the size they have in landscape.
  Before, a desktop dialog was shrunk to fit and its text was 4-6 pixels.
  Foreman and the Krew board have a narrow touch layout (each incident or
  finding on two lines), so their text is about 12 px on a phone instead of 8.
  Test: `tests/live/touch_dialogs_test.gd`.
- **Browser High graphics load on the published site.** GitHub Pages sends
  the model library gzipped; the browser unpacked it and Godot tried to unpack
  it again, so High stopped with "the model library's catalog could not be
  read (HTTP 200)" and the world was drawn in code. Checked with a local
  server that gzips like Pages.
- **Komodo: every container, not the first page.** Komodo Core 2.3 pages
  `ListAllDockerContainers`; without a limit only the first page (30 by
  default) came back and the rest of the containers were missing without an
  error. KubeFactory now asks for all of them (`limit: 0`).
- **Switching away from a KubeFactory server no longer crashes the game.**
  The server connection was closed from a worker thread; Godot 4.3 corrupted
  its heap (Windows: `0xc0000374` in ntdll; Linux: SIGSEGV) on the first
  switch to any other source. It now closes on the main thread, and every use
  of the connection is locked. Test: `tests/live/remote_switch_test.gd`.

### Changed
- **VPN pipes are direct:** a container using a VPN's network is piped
  straight across to it, and a Kubernetes VPN sidecar is drawn as its own unit
  on the pod's roof, piped into the machine it carries.
- **Services are pipelines.** Where the model library is in use (desktop, and
  the browser's High preset), the belts from a Service's depot to its pods are
  built from the library's pipe kit: tinted pipe runs with steel flanges, a
  junction at every corner, and a valve on the drop into each machine, with
  glowing collars for the flow. The kit is V2 geometry, placed by choice
  (see Known limitations). The browser's Standard preset keeps the conveyor
  belts. `B` still shows and hides them. Test: `tests/live/pipes_test.gd`.
- **Komodo asks for containers by their 2.3 name, ListAllContainers,** and falls back to ListAllDockerContainers when an older Core does not know it.
- **Rebinding a key that is already in use asks first.** Settings now says
  "E is already bound to Inspect / talk. Move it to Move right?" with
  **Move it here** (the other action loses the key), **Keep both** (the old
  behaviour) and **Cancel**. Nothing changes until you choose.

### Added
- **A text editor** (Esc > Text editor): KubeFactory's settings files and
  Porter's app setups, and a container's file read-only from the storage
  browser. Light, dark or System theme (the default), line numbers, wrap,
  font size, find / replace, go to line, line tools, and Standard, Vim or
  Nano keys. JSON is checked before saving, the old file is kept as .bak,
  unsaved changes are asked about, and files that hold credentials are not
  offered. Test: `tests/live/editor_test.gd`.
- **More VPN images** are recognised: transmission-openvpn, binhex `*vpn` and
  hotio images with their VPN on, the OpenVPN and WireGuard clients, NordVPN,
  ExpressVPN, Surfshark, PIA and Proton VPN clients and Cloudflare WARP, next to
  Gluetun. **Check now** asks the outside address from inside a VPN's tunnel,
  on request.
- **Esc > VPN tunnels:** every VPN with both sides, Check now, Go there, and
  the downloaders that are not behind a VPN.
- **Porter's "Media server: Jellyfin + VPN".** Seerr → Radarr / Sonarr →
  Prowlarr → Deluge behind Gluetun → Jellyfin, as Compose and Kubernetes
  files (`apps/media-vpn.*`). The VPN account stays in `apps/vpn.env` or a
  Secret; KubeFactory never reads it. The media demo world runs it too.
- **VPN gateways show both sides of the tunnel.** A Gluetun container gets a
  tunnel with an INSIDE sign (its addresses on your network, what it carries)
  and an OUTSIDE sign (the address the internet sees, provider, type,
  countries); containers that use its network are piped into it, and the
  machine's panel says the same. Only Gluetun's provider, type and countries
  are read, never its keys. Tests: `tests/live/vpn_docker_test.gd` (throw-away
  containers), `tests/live/vpn_world_test.gd`, unit tests.
- **`docs/GO_LIVE_2.0.md`:** what is left before 2.0.0, split into release
  blockers, verification that can ship as a known limitation, and what is out
  of reach.
- **Unbind** (×) beside every action in Settings, and a line naming any action
  left without a key. An unbound action stays unbound after a restart.

## 2.0.0-beta.1 (2026-11-14)

A beta: not a stable release. See `KNOWN_LIMITATIONS.md` for what has not been tested
against live infrastructure.

### Added
- **Server mode.** `--server` runs KubeFactory as a server for a cluster or
  Docker engine; players connect over WebSocket with a token (`--remote=`, or
  Esc > Switch cluster > KubeFactory server...). Roles (viewer, operator up to
  MK.4) and read-only mode are enforced by the server; only token hashes are
  stored; every action is audited. `docs/SERVER.md`.
- **Backend plugin API (1).** Plugins are separate programs speaking JSON lines
  (`docs/PLUGINS.md`); they run only when trusted (by a hash of their files),
  are read-only unless allowed to change things, and everything they send is
  checked and capped. Example: `examples/plugins/static-world`.
- **High graphics in the browser demo.** Esc → Graphics → High (or `?gfx=high`)
  fetches the model library's machines, Krew and tools from the same site
  (about 13 MB, each file checked against the catalog's SHA-256) and adds 4x
  anti-aliasing and softer shadows. Standard stays the default and opens at
  once. Anything that fails to load is drawn in code as before.
- **Settings menu** (Esc → Settings): rebind every key and mouse button,
  controller support (move, look, tools, menus with a stick pointer), field of
  view, interface size, inverted look, and status palettes for red-green and
  blue-yellow colour blindness plus high contrast. Saved as you change them;
  key hints and the help line follow your bindings.
- **Minimap** (`N`): a top-down view that turns with you, with node platforms,
  machines in their health colours (failing ones pulse), the HUB, gates and
  the Krew. Saved on or off; it steps aside for touch controls.
- **Docker hosts as connections.** Every Docker CLI context is listed on the
  cluster switcher and can be chosen (`--docker --context=<name>`); one on
  another machine opens read-only. `deploy/docker-readonly/` runs a pinned
  read-only socket proxy (`POST=0`) for each host, reachable over an SSH tunnel
  without docker group or root (`docs/DOCKER_HOSTS.md`). A change refused by
  the host is reported in plain words.
- **Komodo connections (read-only).** Esc > Switch cluster > Komodo...: every
  server a Komodo Core manages is a platform, every container a machine; Bob,
  Sentinel and Scout read them. Only three read requests are ever sent; the
  API key and secret are sealed by the companion (`agent/komodo.go`).
- **Linux and macOS builds.** Releases now include
  `KubeFactory-<version>-linux-x86_64.tar.gz` and a universal
  `KubeFactory-<version>-macos.zip` (Apple Silicon and Intel; the companion is
  a universal binary), built by `tools/package.sh`.
- **Verifiable releases.** Every package gets a `.sha256`, the release one
  `SHA256SUMS`, and each package a Sigstore-signed build provenance
  attestation (`gh attestation verify`).
- **Foreman** (key `H`): correlates the Krew's findings into incidents and a
  shift brief with no AI. Optional AI providers (Ollama, LM Studio, OpenAI,
  Claude, any OpenAI-compatible endpoint) answer plain-language questions from
  a redacted, bounded summary. Proposed actions are checked against a tool
  registry and the current state and run only on approval. Keys are sealed by
  the companion; a provider on another computer receives nothing until allowed.
  Foreman's figure follows the chosen provider.
- **Archie, Forge and Blueprint** join the Krew. Archie (storage): stateful
  software with no lasting storage, unnamed Docker volumes. Forge (build):
  images that exist only on this machine, idle build cache. Blueprint
  (architect): desired versus running replicas and Compose containers, after
  a two-minute hold. All three only report. Pods now carry storage facts from
  the pod spec or `docker inspect`; the board's roster wraps to two rows.
- **The Krew and its operations center** (key `K`). Bob, Gauge and three new
  workers report findings on one board, each with evidence, a proposal and its
  risk: **Sentinel** (security: privileged, engine socket, host paths and
  namespaces, root, capabilities, floating tags), **Scout** (Services with no
  or no ready pods, outside exposure, host ports) and **Scrappy** (old finished
  pods, unused images, unattached volumes). Nothing runs without individual
  approval; unattached volumes are never offered for removal. Stations past
  Gauge's desk, a resolved history, Markdown and JSON export.
  The browser build and the Compatibility renderer draw each worker in its
  own shape (guard robot, drone, tracked sweeper) instead of one block figure.
- **Gauge's resource desk**: inspect node capacity and visible requests, or
  read a selected workload's usage. Its sortable, filterable node table is
  read-only and distinguishes missing data from zero. Gauge can be hidden.
- **Native Kubernetes connectivity.** A small companion program (`kf-agent`)
  reads your kubeconfig and talks to the cluster directly. `kubectl` is no
  longer needed. A connection wizard lists kubeconfig files and contexts,
  takes a dropped file or pasted text, and explains failures in plain words.
- **Model library (V8).** 25 machine models, Porter and Bob from the supplied
  library, at Standard, Enhanced and Ultra detail. Machines show their type on
  a plate, the real pod name and container list on their own displays, and
  have sealed housings with a hinged storage door.
- **Opening doors and storage inspection** (key `F`). Machines with a door open
  it; inside are the pod's volumes. Browse them read-only: folders, text and
  hex previews, 64 KiB at a time.
- **LiveView** (key `V`). An application's real web page on a screen in the
  world or in a window, with working mouse and keyboard.
- **V6 handheld tools** in first person: each tool's own display faces you and
  shows the tool, its target and what the trigger would do.
- **Asset reviewer** at `model-viewer/` on the Pages site (after merge).
- **Grafana and Tautulli providers** for LiveView: pick a dashboard or panel;
  see Plex activity as totals and pin it to a machine. Tokens are sealed by
  Windows and never reach the game.
- **Machine screens with four views**: dashboard, metrics, logs and storage.
  `R` steps through them; clicking a screen (or `V` on the machine) opens it
  full size.
- **Application icons** beside each machine's name.
- **Sortable tables**: click a column heading to sort, type in CONTAINS to
  filter (workloads, clusters, storage files, Grafana dashboards and panels).
- **Bob's and Porter's portraits** show their current models.
- **Usage graphs** in the Metrics view: CPU, memory, network and disk I/O,
  from the cluster's metrics API or `docker stats`; unavailable figures say so.
- **Touch controls for the browser demo**: joystick, drag to look, a context
  ACTION button, jump, aim, a tool bar and a menu, in landscape and portrait.
- **Demo screens:** in the simulated worlds, Grafana machines show a dashboard
  of the simulated cluster's figures and Plex / Tautulli machines show
  simulated streams, each marked SIMULATED. Works in the browser demo.
- `tools/model_audit.gd` and `docs/MODEL_AUDIT.md`.
- `tools/live-test.ps1`: runs the companion against a real, disposable
  kube-apiserver without Docker.
- `KUBECONFIG` is honoured the way kubectl does.
- `KubeFactory.exe --kubeconfig <file>`: one step from download to a cluster.
- `docs/ARCHITECTURE.md`, `FEATURE_PARITY.md`, `KNOWN_LIMITATIONS.md`.

### Fixed
- The game no longer shows your Windows account name: paths under your user
  folder are shown as `~` (also inside error messages and notes), and on the
  local Docker engine you are shown as *local user*. The benchmark table no
  longer names the graphics card.
- An explicitly selected desktop simulation no longer probes Docker, discovers
  kubeconfigs or restores real provider screens on startup. Local connection
  discovery is available from the cluster switcher. Simulated actions no longer
  send audit webhooks or fetch online app lists.
- The companion and its pipe reader now shut down cleanly when the game exits,
  including while a LiveView browser is open.
- Clicking a machine's display now aims at the display itself instead of the
  larger invisible machine collision box, so the screen opens with any tool.
- Storage inspection followed a link that sat inside a volume: a linked file
  (and, on Docker, a linked folder) was read through to wherever it pointed.
  Links are now never followed. Found by the new live tests.
- A stopped Docker container no longer shows usage figures of zero.

### Changed
- A machine's model is chosen truthfully: pods are PODs, containers are
  CONTAINERs, and a role model is used only when the image is that software
  (a CoreDNS pod pulled from registry.k8s.io is no longer a "registry").
- Machine screens are neutral with a small status line; health colours the
  beacon only. The selection highlight is thin corner brackets.
- The text under the crosshair sits below the screen being read; floating
  names show only from a distance.
- Code-drawn machines (the browser build): the oversized fan is replaced by a
  small fan and vent, and the screen is twice as wide.
- Kubernetes uses the companion by default; `--kubectl-cli` keeps the old path.
- The StatefulSet and database-server display fault of the first library is
  gone in V6; the load-time correction for it was removed.
- Release builds need Go (for the companion); the workflow installs it.

### Unchanged
- Docker engine support, the simulated worlds, the browser demo, tools, tiers,
  Porter's setups, Bob's diagnoses and the graphics presets.

## 1.0.1
- Graphics presets (Standard, Enhanced, Ultra) and the benchmark.
- Four demo worlds, per-service belt tracks, Bob 2.0.
