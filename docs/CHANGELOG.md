# Changelog

## 2.0.0-dev (unreleased)

Not a stable release. See `KNOWN_LIMITATIONS.md` for what has not been tested
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
