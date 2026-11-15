# Known limitations (2.0)

<sub>[KubeFactory](../README.md) · [All docs](../README.md#-docs-by-topic) · [2.0.0-beta.2 pre-release](https://github.com/DasCondor/kubefactory/releases/tag/v2.0.0-beta.2) · [Known limitations](KNOWN_LIMITATIONS.md)</sub>

Stated plainly so nobody has to find them the hard way. "Not tested" means
exactly that: the code exists and has not been run against the real thing.
What still has to happen before 2.0.0 is in [GO_LIVE_2.0.md](GO_LIVE_2.0.md).

## Not verified against live infrastructure

- **Native Kubernetes connectivity is verified live on a real cluster with
  running containers** (kind 1.37 in Docker, three nodes):
  `tools\live-test.ps1 -Kind` passes 29 of 29. It covers connecting without
  kubectl, pods reaching Running, real log lines, storage inspection on a real
  volume, a port-forward that carries HTTP, scale, rolling restart with every
  pod replaced, draining a worker that has pods on it, and deleting a pod.
  The game itself was then run on that cluster. The control-plane-only test
  (`tools\live-test.ps1`, 40 of 40) still covers apply, RBAC refusal and
  presence. **Not tested:** any cloud provider (EKS, AKS, GKE), Rancher or
  OpenShift, and a sign-in helper actually signing in. k3s has been reported
  working by a user; it was not tested here.
- **Storage inspection is verified live** on that cluster and on a real Docker
  container (`tests/live/docker_backend_test.gd`, 19 of 19): real folder
  listings and file contents, `..` refused, the service-account token never
  read, and links never followed. The live tests found a real gap, now closed:
  a link *inside* a volume (to a file, or on Docker to a folder) used to be
  read through to wherever it pointed. Images without `ls` and `head`
  (distroless) are still untested.
- **Usage figures:** verified live on Docker (`docker stats`: CPU, memory,
  network and disk, with a stopped container giving no figures rather than
  zeros). On Kubernetes only the "this cluster has no metrics API" answer has
  been seen for real: installing metrics-server on the test cluster was not
  permitted in the session that wrote this, so **reading real figures from the
  metrics API is not tested**.
- **LiveView** is verified against a local test page (click, typing, blocked
  external link, 20 frames in 2 s). Grafana's provider and the game's panels
  have also been tested; a Grafana page on a machine through a Kubernetes
  Service port-forward has not been tested.
- **Port-forward** is verified live (nginx answering through a loopback port on the kind cluster). LiveView through it onto a machine screen has not been run.
- No clean-Windows-machine installation test was done. No large-cluster
  benchmark (hundreds of nodes, thousands of pods) was done.

## Settings and controller

- **The controller was tested with simulated controller input**, not with a
  physical pad: the bindings, the menu pointer and the B / Start behaviour are
  checked by `tests/live/settings_test.gd`. Stick feel (dead zone, speeds) has
  not been tuned on real hardware, and controller buttons cannot be rebound
  yet (keys and mouse buttons can).
- Menus are mouse-first: with a controller you steer a pointer rather than
  move focus between buttons. Text fields still need a keyboard.
- Key hints are translated where they are written in the usual form ("[E]",
  "(K)"); a hint written another way keeps the default key's name.
- Interface size applies when you press **Apply interface size**, so the menu
  does not jump under the pointer while dragging.

## Docker hosts

- Docker contexts are listed without being contacted; one that does not answer
  says so when chosen. The read-only proxy was tested on this machine's engine
  through `tcp://127.0.0.1`; the SSH tunnel and a separate physical host were
  not tested.
- Through the read-only proxy, opening a machine's storage door is not
  available (it needs `exec`), and neither are logs' follow mode or any action.
- Read-only for another host is switched on when you connect; turning it off
  from the Esc menu is your choice, and only the proxy makes it binding.

## Komodo

- **A contributor checked the read requests against a real Komodo Core
  2.3.4** (four servers, 119 containers): the answers match what the game
  reads. That was with the old container request name. The game now asks with
  the 2.3 name, `ListAllContainers`, and falls back to
  `ListAllDockerContainers` when a Core rejects it (HTTP 400, 404 or 422); the
  new name and the fallback were tested only against stand-ins built from the
  published `komodo_client` source. The game itself has not been played
  against a real Core. Komodo versions with a different API may not connect.
- Read-only by design: no restart, deploy or removal through KubeFactory.
- Shown per server, not per Compose stack (container labels are not in
  Komodo's list); logs, capacity figures and storage doors are not available
  over a Komodo connection.

## Linux and macOS

- **Linux:** the exported game was run headless on Ubuntu 24.04 in a container
  (the simulation loads, no script errors), the unit tests pass on the Linux
  engine, and the companion answers there. Not played on a Linux desktop with
  a GPU, and not tested against a real cluster from Linux.
- **macOS:** the `2.0.0-dev` player from commit `b0316f4` completed a
  300-frame GUI startup smoke test on Apple Silicon running macOS 15.6.1
  with no errors. The package checksum matched, and the bundled companion
  responded to `ping` and `shutdown`. Both binaries include Apple Silicon
  and Intel slices. The published beta's companion was also verified, but
  its player has not been run in a desktop session. Intel startup and
  gameplay remain unverified. The app is ad-hoc signed and is not notarized.
- On both, the companion cannot keep tokens and keys yet: it seals them with
  Windows' per-user protection only, so Grafana, Tautulli, AI provider and
  Komodo credentials are refused rather than stored in the clear. Kubeconfig
  connections, Docker and the simulation do not need it.
- The helper scripts (install, dev cluster, packaging) are PowerShell on
  Windows; Linux and macOS have `tools/package.sh` only.

## VPN gateways

- **Recognised by image name.** The registry (`VPN_REGISTRY` in
  `scripts/kutil.gd`) knows Gluetun, transmission-openvpn, binhex `*vpn` and
  hotio images (when their VPN is on), the OpenVPN, WireGuard, NordVPN,
  ExpressVPN, Surfshark, PIA and Proton VPN clients and Cloudflare WARP. An
  image under another name is not recognised. Only Gluetun and a binhex-style
  stand-in were tested (on throw-away containers); the settings names for the
  other clients come from their documentation, not from running them.
- **Check now** asks `ipinfo.io` from inside the VPN container: it needs `wget`
  or `curl` in the image, it is the one call to the internet KubeFactory makes
  for this, and only when pressed. Not tested against a real VPN (it would
  contact ipinfo.io from the test machine).
- **The outside address** is what Gluetun recorded in `/tmp/gluetun/ip`, read
  at most once a minute: verified live on a throw-away stand-in container
  (`tests/live/vpn_docker_test.gd`), not against a real VPN provider. Through
  the read-only Docker proxy (no `exec`) and on Kubernetes it is shown as not
  read. Country and city of the exit are not shown: Gluetun does not write
  them to that file.
- **Inside** shows the addresses Docker or Kubernetes reports. Whether the
  tunnel is really up is Gluetun's to say; KubeFactory does not test for leaks.
- On Kubernetes a Gluetun sidecar carries its whole pod (that is how pods
  work); separate pods cannot share one gateway.
- The Porter setup was checked with `docker compose config` and a YAML parse;
  it has not been run with a real VPN account.

## Text editor

- A plain editor, not an IDE: no tabs of several files at once, no plugins,
  no project search. Syntax colours are simple (strings, numbers, `#`
  comments).
- Vim and Nano are the everyday subsets listed in the README: no counts
  (`3dd`), no visual mode, no registers beyond one, no macros, no `.vimrc`.
  Nano's ^G toggles its help line rather than opening help.
- The System theme follows the operating system where Godot can read it
  (Windows, macOS); elsewhere it falls back to dark.
- JSON is checked before saving; YAML and other files are saved as typed,
  unchecked.
- In the browser demo there are no settings files to edit; a container's file
  still opens read-only.
- Tested with real key events in the game (`tests/live/editor_test.gd`), not
  by hand on every keyboard layout: ^_ (go to line in Nano) is Ctrl+Shift+minus
  on a US layout.

## Server mode and plugins

- **Server mode** was tested with a headless server and client games on this
  machine over `ws://127.0.0.1`. `wss://` with a certificate, a reverse proxy
  and players on other machines were not tested. Players' avatars, the shared
  feed and per-namespace limits of the Kubernetes multi-user mode are not
  carried over a server connection yet; roles are per token, not per
  namespace. Tokens are managed by editing `server-tokens.json`.
- **Plugins** were tested with the example plugin only. A trusted plugin is a
  program running with your rights: trust only plugins you have read. Plugins
  cannot draw their own models or screens; their machines use the standard
  ones. Plugins are not available in the browser build.

## By design, for now

- **Docker still uses the `docker` command.** Only Kubernetes is native.
- **Cloud logins still need their own tools.** An EKS, AKS or GKE kubeconfig
  names a helper program (`aws`, `kubelogin`, `gke-gcloud-auth-plugin`); it has
  to be installed, and you have to approve it in the wizard.
- **Log providers** (CloudWatch, Azure Monitor, Cloud Logging, Loki) still call
  their CLIs or `curl`.
- **`--kubectl-cli`** keeps the old kubectl path. Without the companion the
  game falls back to it by itself and says so.
- **LiveView needs Microsoft Edge or Google Chrome installed.** No browser
  engine is bundled. It shows up to four pages at once, has no sound, does not
  download files, and refuses addresses that are not http or https. A page
  that needs a login gets a fresh profile every time: nothing is remembered.
- **Storage inspection needs `ls`, `head` and `dd` in the container.** Images
  without a shell toolset (distroless, scratch) report "unsupported". It is
  read-only; there is no upload, edit or delete.
- **Opening doors** exist on the machine models that were built with a door or
  a rear service panel. Others have no door and say so.
- **The companion is not code-signed**, like the game. SmartScreen will warn.

## Model library

- Placed in the world: the 25 machines, Porter, Bob, Gauge, Foreman (one
  model per provider) and the six workers at their stations (Sentinel, Scout,
  Scrappy, Archie, Forge, Blueprint), and the Service pipelines (below). The
  Krew HQ model and the other 98 V2 models
  (network, storage, structures, props, displays, tools) are shipped but not
  used: they are below the Porter V3 standard or belong to features that do
  not exist yet.
- The library is V8 (the V7 readability patch: repaired lettering and neutral
  display planes on 249 files; V8 changed no models). Its own notes say what it
  is not: no model is approved for release, 50 designs are still V2 legacy
  geometry, and its checks were sampled, not exhaustive. Nothing here changes
  that.
- **The Service pipelines use V2 models, by choice.** Every belt from a
  Service's depot to its pods is built from the library's `pipe_straight`
  (the tube takes the Service's colour), the junction block of
  `conduit_elbow` at each corner, and `pipe_valve` on the drop into each
  machine. The library marks these "legacy geometry, visual rebuild pending":
  they are below the V3 standard the other placed models meet, and were
  placed because the operator asked for them. Checked on Standard, Enhanced
  and Ultra in the `kubernetes` and `media` worlds (screenshots, no gaps
  found at corners or drops); not reviewed piece by piece for clipping. The
  browser's Standard preset and the Compatibility renderer keep the
  code-drawn belts.
- **A machine is a pod, and its plate says so.** Pods read POD and Docker
  containers CONTAINER; a pod gets a role model (DATABASE SERVER, CACHE
  SERVER, NETWORK APPLIANCE...) only when the image it runs is that software.
  The Deployment, StatefulSet, DaemonSet, ReplicaSet, Job and Compose models
  are therefore not placed: the world has no object for the workload itself
  yet. Fewer distinct silhouettes is the cost of the plates being true.
- **Grafana is verified against real Grafana OSS 10.4.10, 11.2.0, 12.3.0 and
  13.0.0.** `tools\live-test.ps1 -Grafana [-GrafanaVersion x.y.z]` starts a
  disposable Grafana on this computer under a `/grafana` sub-path with a
  Viewer service account, and every step passes on all four: test connection,
  dashboard search, panel list (collapsed rows included), variables,
  credential-free panel links that Grafana serves to a signed-in user and
  redirects to its sign-in page otherwise, wrong and missing tokens refused as
  authentication failures, and the token absent from disk and from every
  companion answer. The game's own panels were run against 11.2.0 only. Not
  tested: Grafana Enterprise, Grafana Cloud, or a dashboard saved in the newer
  layout.
- **Tautulli is verified against a real Tautulli 2.19.1 with no Plex server
  behind it** (`tools\live-test.ps1 -Tautulli`, 10 of 10): the key is accepted
  in the header and in legacy mode, a wrong or missing key is an
  authentication failure, the wrong address is told apart from a key problem,
  the key is not on disk, in any companion answer or in Tautulli's own log,
  and with no Plex every figure shows as unavailable rather than 0. **Real
  stream counts are not tested**: that needs a Plex server with something
  playing. Those figures are covered by the stand-in server only. Tautulli
  older than 2.18 (the reason legacy mode exists) was not tested.
- Grafana served from a sub-path also answers at its root address; KubeFactory
  then works there too (verified). Either address is fine.
- Provider gaps against the V8 note: the newer Grafana dashboard API and
  layouts are not read (such a dashboard opens whole; its panels are not
  listed, and none are invented); no native charts from Prometheus; nothing
  on a control-room wall or the Datapad; a Grafana page put on a machine is
  not remembered between runs (a pinned Tautulli summary is); only
  `get_activity` is used; a provider needs an address that stays put, so a
  cluster Service reached only by port-forward has to be exposed or typed in;
  tokens can be stored on Windows only; private CAs are trusted only if
  Windows already trusts them. Grafana sign-in is asked every time, because
  LiveView's browser keeps nothing.
- From the V7 notes, not done: new silhouettes per kind, sliding or split
  doors for narrow aisles, removing the floating name labels, and distinct
  LiveView states (no endpoint, loading, sign-in needed) on the machine glass:
  it shows the pod's status as one small line until a page is opened.
- 22 of the 25 machines have a storage door. `cooling_unit`, `load_balancer`
  and `network_appliance` have none.
- The six V6 handheld tools are used in first person on the desktop renderer:
  they aim where you look and their display faces you, showing the tool, what
  it is pointed at and what the trigger would do. The display is text, not a
  LiveView page. Their colours are the library's; the browser build keeps the
  hand-built tools. Only one hand pose per tool exists: no finger rig, and the
  old spinning and moving parts of the hand-built tools have no equivalent.
- The Krew display surfaces (chest, hand, laptop) are not bound to anything,
  and nothing is rigged or animated beyond the door.
- The model's own drive modules are left out of the bay; the game shows one
  module per real volume instead.
- 10 models reach 7-70 mm below the ground (`MODEL_AUDIT.md`); none of them is
  placed in the world.
- **Demo screens are simulated, and say so.** In the simulated worlds (and so
  in the browser demo) a Grafana machine shows a hand-drawn dashboard of the
  simulated cluster's own figures and a Plex or Tautulli machine shows
  invented stream activity, each under a SIMULATED banner. They are not
  Grafana or Tautulli pages: clicking one opens it full size with two views to
  switch between, not a web page. On a real cluster or Docker engine these
  screens stay neutral until a real page or provider is put on them.
- **Browser High graphics** were checked in the exported web build served
  locally (all 40 models fetched and checked, the library in use) and rendered
  on the desktop Compatibility renderer the browser uses. Not tested on the
  deployed site, on a phone, or for frame rate in a browser; on a phone the
  13 MB download and the extra detail may be slow, which is why it is opt-in.
  Global illumination and reflections are not available in the browser.
- **The exported browser build was run**: it loads, the world chooser works,
  the media world loads, and the browser console shows no errors. The tool
  used to drive it could not send keys or capture the mouse, so walking up to
  a screen and pressing `R` / `V` was checked on the Compatibility renderer
  the browser build uses, not inside the browser itself.
- **Touch controls are untested on real phones.** They were driven with real
  touch events at phone sizes (844 x 390 and 390 x 844) on the Compatibility
  renderer the browser build uses: two thumbs independently, dead zone, release
  on lift, tool choice doing nothing by itself, ACTION opening a screen with
  the Demolisher in hand and nothing destroyed, the menu, switching them off.
  The exported browser build was also opened at phone size with the controls
  on: the dialogs filled the screen and the on-screen ACTION button worked.
  Touch controls switch on when the browser reports a touch screen (a coarse
  pointer that cannot hover); `?touch=0` keeps them off. Dialogs fill the
  screen's width and scroll; on a phone held upright they are drawn sideways,
  so you turn the phone to read them. They are still desktop layouts, made
  larger, not phone layouts: text is about 9-10 points on a phone. The menus
  were checked in the engine at 390 x 844, 844 x 390 and 768 x 1024, including
  a tap through a sideways dialog; the page in a phone-sized desktop browser
  showed the same layout, but that browser's simulated taps landed in the
  wrong place, so taps were checked in the engine only.
  **A screenshot from a real iPhone showed the problem; the fix has not been
  tried on one yet.** Notch and home-indicator margins, browser toolbars,
  rotation while playing, frame rate and memory on a phone are unmeasured.
  There is no native mobile build.
- **Usage figures (Metrics view):** Kubernetes reports CPU and memory only;
  network and disk show as unavailable there. The kubectl mode has no usage
  figures.
- **Gauge** is a read-only observer, not the full performance worker from the
  handoff. Node request sums cover visible regular containers and may omit init
  containers, overhead or resources outside the visible namespace. They are
  not runtime usage or a scheduling guarantee. Gauge does not forecast, perform
  right-sizing or make changes; actual Kubernetes metrics remain untested.
- **Foreman's AI providers** were tested only against a mock provider
  (OpenAI-compatible and Claude request shapes), not against a real Ollama,
  LM Studio, OpenAI or Claude. One question at a time; no streaming, so a long
  answer shows only when complete (120 s limit). The model sees a summary
  chosen by the game (up to 60 workloads and unhealthy pods, 40 findings); it
  cannot ask for logs or more detail. Redaction is pattern-based and can miss a
  secret written in an unusual form. Incidents are grouped by resource only;
  they are not kept after the game closes, apart from an export.
- **Archie, Forge and Blueprint** report only; none of them changes anything.
  Archie judges software by its image name (a database, broker, cache...) and
  sees volumes only as the pod spec or `docker inspect` states them; it knows
  nothing about backups made by other tools. Forge's "exists only on this
  machine" needs the classic Docker image store: with the containerd store
  (Docker Desktop's default) every image has a digest, so Forge reports that it
  cannot tell. Blueprint compares replica counts only; it does not read
  Compose files, manifests or Terraform plans.
- **The Krew** (Sentinel, Scout, Scrappy) reads only what the cluster state
  already holds: pod specs, Services and, for Docker, `docker inspect`. It does
  not read NetworkPolicies, RBAC, admission policies or image vulnerabilities.
  Scout does not probe connectivity. Scrappy's image and volume scan works on
  Docker only; the Kubernetes API does not say which images a node no longer
  uses. Approved removals (finished pod, unused image) were exercised in the
  simulation, not on live infrastructure. Findings are kept only while the game
  runs, apart from an export.
- **Screen views:** at most 8 machines show metrics, logs or storage at once
  (the oldest goes back to its dashboard). Logs show the last 13 lines of the
  first container. Logs and storage on a machine's screen were seen working on
  the real kind cluster (etcd's own log lines, its real mounts). Putting a live page or a provider on a machine while it
  shows another view does not switch it back to the dashboard by itself.
- **Tables:** the workload list, cluster list, storage file list and the
  Grafana dashboard and panel lists sort by a clicked column and filter with a
  CONTAINS box. Bob's fix list and Porter's lists are cards, not tables, and do
  not. A table of 10,000 rows or more is shown unsorted and unfiltered; 9,999
  rows sort in about a tenth of a second.
- **Bob and Porter portraits** use their current models on the desktop; the
  browser build keeps the drawn portraits, as it keeps the drawn figures.
- **Application icons** are generic symbols by kind (database, cache, media
  server...), drawn in code from the container image name. They are not the
  applications' own logos, and an image it does not recognise gets a plain
  block.
- The asset reviewer that came with the library is added to the Pages build at
  `model-viewer/` and is live at
  https://dascondor.github.io/kubefactory/model-viewer/. It was checked
  locally (loads, no external requests, no console errors). It adds the whole
  library (about 72 MB) to the site. Not tested on a
  phone. Reviews stay in the browser that made them unless exported.
- The audit cannot detect two solid parts pushed into each other unless one of
  them is a display.

## Not implemented from the 2.0 handoff

See `FEATURE_PARITY.md` for the full table. In short: the autonomy and policy engine,
self-healing and scheduling, an in-game terminal, a bundled browser engine, a
native Docker Engine client.
