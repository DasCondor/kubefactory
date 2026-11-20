# Feature parity and release gap matrix

<sub>[KubeFactory](../README.md) · [2.0.0-beta.3 pre-release](https://github.com/DasCondor/kubefactory/releases/tag/v2.0.0-beta.3) · [2.1 to 2.2 handoff](HANDOFF_2.1_TO_2.2.md) · [Known limitations](KNOWN_LIMITATIONS.md)</sub>

The released baseline is **2.0.0-beta.3**. The **2.1** column describes local
work and review items. **2.2** is the planned block-builder release. The
historical 1.0.1 and 2.0 feature tables below record the underlying capabilities.

The [required 2.2 scope](HANDOFF_2.1_TO_2.2.md#required-22-scope) includes the complete Docker media, reporting, network and storage work.

- [2.1 and 2.2 feature matrix](#21-and-22-feature-matrix)
- [Platform and live verification gaps](#platform-and-live-verification-gaps)
- [Unscheduled capabilities](#unscheduled-capabilities)
- [1.0.1 features in 2.0](#101-features-in-20)
- [2.0 handoff](#20-handoff)

## 2.1 and 2.2 feature matrix

**Built locally** means the code is in the working copy. **Config validated**
means Docker Compose parsed the files and the publishing rules were checked.
**Planned** means implementation is open. **Carry forward** means preserve the
existing behavior and rerun its checks when the affected code changes.

### Workloads, networks and the factory

| Feature | Released in beta.3 | Local 2.1 and remaining review | Planned for 2.2 | Acceptance check |
|---|---|---|---|---|
| Workload appearance | Factory machines with names, container pillars, application icons and optional dashboard surfaces | Carry forward; inspect mixed deployments, failed pods and Docker containers | Role-specific voxel blocks for app, worker, storage, gateway, reporting and generic workloads. Allow an appearance override | Identify each role by shape and label in a color-blind palette. Changing a shape preserves the workload ID and dashboard |
| Block placement | Existing build gun and factory tools | Carry forward replica and blueprint actions | Grid snapping, placement ghost, rotation, collision rejection, removal and undo | Place, rotate and undo with pointer, keyboard and touch. An occupied cell rejects the placement |
| Application connections | Simulated links for media calls, metrics and file imports. Existing Service pipes | Carry forward links, pipe alignment and endpoint highlighting | Select source and destination sockets, preview a route, persist directed edges, and trace the selected pipe in both views | A path starts and ends at its named sockets. Incompatible sockets, duplicate edges and missing endpoints are rejected |
| Pipe and fixture geometry | Roof-aligned pod ports, aisle routing, common collars, Service pillars and their explainers | Visually review dense intersections, remaining solid-on-solid overlap, and held NPC items | Use the same fittings on block sockets, clear neighboring blocks, and show port direction at each end | Walk a dense build in both renderers and trace a crossing without confusing it with a junction |
| Published port inventory | Service, host and container port rows with backend readiness | **Built locally.** Group host-facing, loopback and internal rows. Read Docker’s configured IP and port, including stopped mappings. Unit and live local Docker checks passed | **Built:** scope, host and network filters; each row names its host and networks. Docker network drivers are read, macvlan and ipvlan ports are shown at the container's own address (listener unverified), and host or shared networking is named. **Verified live** on Docker 29.9 (`tests/live/ports_network_docker_test.gd`, throw-away macvlan network): driver, address, row, host mode and the network filter. Not tested: ipvlan and a client actually reaching the macvlan address | Compare per-binding rows with Docker inspect for loopback, wildcard, dual stack, protocols and stopped containers |
| Reachability and broken ports | Backend readiness and simulated status | **Config validated.** Media lab includes internal HTTP checks. A physical client check is open | **Built:** Check from here on one binding: origin, time, TCP result and a separate HTTP result; UDP stays unknown; audited. **Verified live** against a throw-away Docker web server (`tests/live/port_check_docker_test.gd`). A check from a second client on a real LAN or VLAN is still open | Stop Seerr and distinguish its saved binding, offline state and failed probe. An inconclusive UDP check shows unknown |
| LAN and VLAN | Simulated VLAN IDs and display of Kubernetes annotations or Multus attachments | **Built locally.** Show declared VLAN on a specific Docker bind IP. **Config validated** that only Plex and Seerr can switch from loopback to the selected media IP | Add host and segment filters. Show client ingress and separate management routes for private app requests, metrics and file sync. Label configured bindings, observed attachments and measured access | Test from allowed and disallowed clients on real interfaces. Trace the three private routes to separate endpoints |
| VPN image registry and routes | Recognized images, exit IP status and **Check now**, shared and dedicated routes, and a WWW outlet. The simulation traces searchers and downloaders through intended gateways | Carry forward direct paths, sidecars as units and shared gateway tracing. Test real provider traffic and failure behavior | Show Sonarr/Radarr, Jackett or Prowlarr, and the downloader behind Gluetun. Give the gateway distinct ingress and WWW sockets. Trace Plex and Seerr HTTPS separately | Trace each gathering app to Gluetun and the WWW output. Test the VPN-down state and verify which routes stop |
| Shared disks and mounts | Backing-volume grouping, consumer mount paths and separate simulated downloads and library space | Review the Plex read-only library and the optional gatherer inbox as separate paths. Full transfer is open | Connect storage read and write sockets. Show used, free and total space in disk and pod views. Warn on the main HUD only above the configured threshold, which defaults to 87% used | Compare figures with the backend, verify no duplicate capacity, and test 86%, 87%, 88%, and a changed threshold |
| File movement and controls | Animated simulated download and library import paths | **Config validated.** Optional Syncthing gatherer and receive-only inbox. Operator copies approved files into the library | Show transfer activity and add a permission-checked pause/resume lever for each configured sync. Show library imports as separate events | Check viewer and operator access. Pause and resume one folder, then transfer and import a file. Verify sync and import counts independently |
| Flowchart and saved plans | Editable local flowchart with Media Suite and online-shop presets | Carry forward existing saved layouts and VLAN IDs | Share a versioned layout with 3D placement. Store block IDs, coordinates, rotation and socket edges. Migrate old saves and add plan import/export | Open an old save. Edit in the graph, reopen the factory and confirm positions, roles and links survive reload |
| Compose preview | Bundled app stacks and existing deployment tools | Standalone Compose media files available for review | Generate a reviewable Compose preview from a supported plan. Future live application requires an operator review and approval | Export a demo plan, validate the preview and confirm intended services, mounts and bindings match the plan |

### Demos and operator experience

**Local playable 2.2 demo.** The demo picker includes a seven-container Docker starter and a fifteen-container full media stack. Set `host_count` in `media-lab.json` to place the full stack on one or two hosts. Both use the game’s machines, dashboards and pipe renderer. The local implementation includes route tracing, reporting and data cabinets, LAN/VLAN port checks, VPN-only gathering routes, sync controls and simulated Discord alerts. The [play walkthrough](HANDOFF_2.1_TO_2.2.md#play-the-docker-media-lab) describes the controls. The gathering preset uses Jackett or Prowlarr (`indexer` in `media-lab.json`, or switched in game). The voxel builder remains in the 2.2 scope.

| Feature | Released in beta.3 | Local 2.1 and remaining review | Planned for 2.2 | Acceptance check |
|---|---|---|---|---|
| Single-node Docker management | Live desktop Docker contexts and Compose grouping. Browser offers simulated worlds | **Config validated.** Plex, Seerr, Tautulli, Blackbox Exporter, Prometheus and Grafana files. Full startup and app sign-in are open | Add a guided simulated Docker media preset for browser and desktop. Default to every container and defined connection in the in-game overview | One node and one machine per container, including idle containers. Trace each overview connection to its two endpoints |
| Seerr Discord alerts | Application notifications are configured in Seerr | Discord notification agent available in Seerr | Display the optional outbound Seerr-to-Discord alert connection with event and last delivery result. Show a simulated notification in the browser | Enable the simulated route and confirm event, destination and delivery status. Inspect labels and logs for a redacted destination |
| Reporting | Simulated dashboards, Grafana and Tautulli integrations with documented live test limits | **Config validated.** Built-in Grafana dashboard, endpoint probes and alerts. Playback overlay reads Tautulli activity over an internal network. Playback metrics are open | Show direct caller-to-target pipes for playback, HTTP probes, and gatherer metrics. Show the shared Prometheus data source with its own TSDB data container and Grafana's direct query path | Play a clip and observe metrics in Grafana. Stop an app and observe the alert. Trace the calls and verify only Prometheus mounts the metrics data volume |
| Optional second node | k3s Media Suite includes multiple simulated nodes | **Config validated.** Standalone gatherer and receiver overlays. Pairing and transfer across two physical engines are open | Add a switchable second gathering station with private connections, VPN-protected egress and a shared outbox | Verify the single-host preset and the two-host variant. Enable the gatherer and trace requests, metrics, VPN egress and the separate sync and import paths |
| Per-app dashboards and repair | Simulated pod screens, Heimdall recent failures, Bob diagnosis, and an image-update exercise | Carry forward the k3s example. Review Seerr logs and correlate a stopped service with the port panel | Open dashboards and port details from any corresponding block, then return focus to it | Follow a failure to the app, inspect evidence, and return to the selected workload |
| Startup, browser resolution and touch | Branded launcher, graphics picker, viewport rotation, reachable Back and Close, searchable dashboard list | Narrow-screen Godot menu checks passed locally. Real iOS and Android review is open | Responsive block picking, socket selection, plan saving and inspection | On a physical phone, rotate with the placement or port panel open. Tap controls, text and focus remain usable |
| Text editor and console tools | Themes, line numbers, Standard, Vim and Nano subsets, and JSON validation | Carry forward; keyboard-layout review is open | Carry forward while introducing plan editing | Open the editor after using the builder. Check shortcuts, scroll, input focus and saving on the supported desktops |
| Tests and handoff materials | Release notes, automated checks and visual wiki guides | Compose files, walkthrough, review ZIP and port tests are local | Add builder, socket, migration, mobile, port and media-flow checks. Record walkthrough screenshots, GIFs or video after implementation | A reviewer can follow the setup from the ZIP, inspect the demo, and reproduce the media, network and failure cases |

## Platform and live verification gaps

Packaging, end-to-end use and physical hardware have separate evidence. The
2.1 and 2.2 release checks below build on the [stable 2.0 checklist](GO_LIVE_2.0.md).

| Area | Best available evidence | Open verification or dependency |
|---|---|---|
| Windows | beta.3 x64 package built and published. Local Godot and Docker checks passed | Install on a clean system and connect to Docker and kubeconfig. SignPath signing requires setup and approval |
| Linux | beta.3 x86-64 archive built and published. Earlier exported build ran headless | Run on a Linux desktop with a GPU and connect to a real cluster |
| macOS | beta.3 archive built and published. Earlier GUI startup smoke test on Apple Silicon | Test the packaged player, play a full session and check Intel startup. Publisher signing and notarization remain open |
| Browser and phones | Published web build and emulated touch tests. Local checks exercised rotation | Retest deployed startup and performance on real iOS and Android, with browser bars and the keyboard visible |
| Platform credential storage | Windows per-user protection for provider, AI and Komodo keys | Provide protected Linux and macOS storage or keep the platform limits documented |
| Kubernetes | Real kind cluster and real API server coverage. k3s reported by a user | Verify k3s, EKS, AKS, GKE, Rancher, OpenShift and actual exec sign-in helpers. Exercise the packaged client |
| Gauge and container storage | Docker usage and mounted-file inspection verified on real workloads. Kubernetes returned the missing-Metrics-API status | Check real metrics-server values and the distroless storage response |
| Docker ports and networking | Running and stopped local Docker binding rows checked. Compose publishing rules validated | Run the full media stack. Check IPv4 and IPv6 bindings, a real VLAN, and host and attached network modes |
| Remote Docker hosts | Local read-only proxy and host enforcement tested | Verify an SSH tunnel and a separate physical Docker host |
| Komodo | Contributor verified container logs on Core 2.3.4. Updated list request and its fallback checked against stand-ins | Run the full current connection flow against a real Core, including list request, fallback and Logs permission |
| LiveView and Grafana | Local page and Service port-forward tested separately. Grafana OSS provider reads tested | View an authenticated Grafana dashboard through Docker and a Kubernetes Service port-forward. Check Enterprise and Cloud only if support is claimed |
| Plex, Seerr and Tautulli | Config validated. Earlier Tautulli provider check reached a real Tautulli server. Activity values were checked with a stand-in | Claim Plex, complete Seerr and Tautulli setup, play a clip, and observe the live exporter, dashboard and alert. Test the second-node file transfer |
| Real VPN routes | Simulation and throw-away stand-ins exercised gateway discovery, reported IPs and shared paths | Use a real account, check actual exits and tunnel-down behavior, and verify additional recognized images |
| Foreman | Mock-provider and rules-only workflows tested | Run with a real provider and verify redacted context, proposal refusal or approval, and secret handling |
| Server mode and plugins | Server and clients tested on one machine. Example backend plugin tested | Verify two machines over TLS and exercise another plugin. Check preserved role boundaries and event visibility |
| Controller and scale | Simulated controller and local presets checked | Test a physical controller, asset overlap in dense routes, and hundreds of nodes or thousands of pods |
| Release artifacts | beta.3 desktop packages have checksums and build-provenance records | Package 2.1 and 2.2 when approved, run platform acceptance, verify attestations and write release notes for the actual feature set |

## Unscheduled capabilities

These items remain outside the current 2.1 and 2.2 assignments. The 2.0
handoff below records the existing pieces and test evidence for each area.

| Area | Capability still missing |
|---|---|
| Docker and Kubernetes management | Native Docker Engine client, in-game exec or terminal, ephemeral debugging, Helm and CRD browsing |
| LiveView and Grafana | Bundled browser engine, audio, persistent sessions and display builder. Newer Grafana dashboard APIs, layouts and native data-source charts |
| Tautulli and editor | Native Tautulli history, libraries, control-room wall and Datapad pins. Full Vim or Nano behavior, editor tabs and YAML validation |
| Krew operations and assets | Krew rigging, animated tools and Krew display surfaces. Gauge forecasting and right-sizing, Archie backups and restores, Forge analysis and publishing, general Blueprint import and Terraform plans, and incident coordination |
| Storage writes | Upload, deletion and editing large/binary files. Local 2.2 now has guarded edits of existing mounted text files from the spider map; simulation and live Docker verified, live Kubernetes/k3s writes still need verification |
| Server mode and plugins | Cross-server player avatars, shared presence and action feed, per-namespace roles, custom plugin models and screens, and browser plugins |
| Foreman and automation | On-demand AI tools, streaming, multi-step plans, expanded cost controls, automated policy decisions, scheduling and self-healing |

See [known limitations](KNOWN_LIMITATIONS.md) for runtime restrictions and
[the 2.2 handoff](HANDOFF_2.1_TO_2.2.md) for the block and connection design.

Status words used in the historical tables:

- **verified live** — run against real infrastructure
- **verified on a real API server** — run against the Kubernetes project's own
  kube-apiserver 1.32 and etcd, started for the test (`tools\live-test.ps1`).
  It is a real control plane with nothing behind it: no nodes that run
  containers, no controllers. API behaviour is real; nothing that needs a
  running container is covered
- **verified in simulation** — run against the built-in simulation, a fake API
  server or a local test page
- **not tested** — implemented, never run against the real thing
- **unsupported** — not implemented

## 1.0.1 features in 2.0

| Feature | 2.0 | Status |
|---|---|---|
| Simulated clusters, four demo worlds, browser demo | unchanged | verified in simulation |
| Tools 1-6, tiers, typed confirmations, protected namespaces | unchanged; same code path on every backend | verified in simulation |
| Scale, restart, delete, deploy, cordon, drain | kubectl path unchanged; native path added | native path: verified on a real API server; scale, restart, delete and drain with pods also verified on a kind cluster with running containers (29/29). kubectl path: not re-tested this cycle |
| Logs and events | native path added | events: verified on a real API server. Logs: verified on a kind cluster with running containers |
| Porter: app setups, Portainer templates | unchanged; applies through server-side apply on the native path | native apply: verified on a real API server (the game deployed and removed the postgres setup and a Portainer template) |
| Bob and Bob 2.0 log reading | unchanged | verified in simulation |
| Multi-user presence and action feed | native path added | verified on a real API server (one player; two players at once not tested) |
| Docker engine edition | unchanged (docker CLI), plus usage figures | backend **verified live** on a real container (logs, storage, usage); the edition's full tour not re-run |
| Graphics presets and benchmark | unchanged | verified in simulation |
| Audit log, log providers, sound, datapad, codex | unchanged | verified in simulation |

Nothing was removed. `--kubectl-cli` selects the 1.0.1 Kubernetes path.

## 2.0 handoff

| Section | Item | Status |
|---|---|---|
| 00 Native connectivity | Kubeconfig discovery, import by file / drop / paste, context list | verified in simulation (real kubeconfig file, fake API server) |
| | Live on a real cluster with running containers (kind 1.37): logs, storage, port-forward, scale, restart, drain with pods | **verified live** (`tools\live-test.ps1 -Kind`, 29/29; the game also run on it) |
| | Connect without kubectl (client-go) | verified on a real API server and on kind with working nodes; **not tested** on any cloud provider |
| | Plain failure screens (unreachable, TLS, auth, RBAC, timeout) | RBAC and unreachable: verified on a real API server; TLS, auth: verified in simulation |
| | Explicit trust for exec auth helpers | verified in simulation |
| | Watches instead of polling | verified on a real API server |
| | Clean Windows machine acceptance test | not tested |
| 00A Assets | Model library integrated at three tiers | verified in simulation |
| | Clipping: V6 library, every display ray-tested clear | verified in simulation; audit in `MODEL_AUDIT.md`. Solid-on-solid overlap: not tested |
| | Type plate, real resource name and container list on the model's own surfaces | verified in simulation |
| | V6 handheld tools in first person, display facing the operator with real target data | verified in simulation |
| | Krew display surfaces; rigging and animation of tools and Krew | unsupported |
| | Asset reviewer hosted at `model-viewer/` | deployed to GitHub Pages; verified locally |
| | Opening storage doors, stopped by obstacles | verified in simulation |
| | Read-only storage browser | **verified live** on kind and on a real Docker container; links are never followed |
| | Porter V3 as minimum standard | machines, Porter and Bob use V3. One exception by the operator's choice: the Service pipelines use the V2 pipe kit (`pipe_straight`, `conduit_elbow`, `pipe_valve`); no other V2 model is placed |
| 02 Docker | Native Docker Engine API | unsupported (docker CLI kept) |
| | Several Docker hosts (CLI contexts), read-only by default for other machines, read-only proxy recipe | **verified live** through a throw-away read-only proxy: state, `docker inspect`, the image scan, and the host refusing a removal with read-only off. The SSH tunnel and a separate physical host not tested |
| | Komodo Core, read-only: servers and containers (2.3 request name, with a fallback for older Cores), container logs (needs Komodo's Logs permission) | verified against a mock Komodo built from the komodo_client request and entity shapes (agent tests, in-game test on both renderers). The read requests were checked against a real Core 2.3.4 by a contributor, with the old request name; the game has **not been played** against a real Core |
| 02 Kubernetes | Server-side apply, cordon, scale, rollout restart | verified on a real API server |
| | Drain with pods to evict | **verified live** on the disposable kind cluster |
| | Exec / terminal, ephemeral debug containers, Helm, CRD browsing | unsupported |
| 03 World and graphics | Non-regression presets | verified in simulation (`BENCHMARK.md`) |
| 04 Assets and operator experience | In-game settings: every key and mouse button rebindable, controller support, field of view, interface size, colour-blind palettes, minimap | verified in simulation with simulated controller input (`tests/live/settings_test.gd`, `minimap_test.gd`, both renderers); **not tested** with a physical controller. Controller buttons cannot be rebound |
| 05 LiveView | Real page on an in-game screen, mouse and keyboard | verified in simulation (local test page) |
| | Endpoint discovery (Docker published ports, Kubernetes Services) | verified in simulation (unit tests) |
| | Port-forward for cluster Services | **verified live** (HTTP through a loopback port); LiveView through it not run |
| | Host allowlist, isolated profile | verified in simulation |
| | Machine screens step through dashboard, metrics, logs and storage; click to open full size; application icons | verified in simulation (desktop and Compatibility renderers) |
| | Metrics view: CPU and memory from the metrics API, all four from `docker stats`, unavailable shown as such | Docker: **verified live**. Metrics API: only its "no metrics API" answer seen live; real figures **not tested** |
| | Sort by column and CONTAINS filter on tables (under 10,000 rows) | verified in simulation (unit tests and screenshots) |
| | Touch controls for the browser demo (landscape and portrait) | verified in simulation with touch events at phone sizes; **not tested** on a physical iPhone or Android device |
| | Explicit desktop simulation starts without kubeconfig or Docker discovery; simulated actions skip webhooks and online catalogs | verified with an instrumented Docker stub and the cluster switcher on both desktop renderers (`tools\test-simulation.ps1`) |
| | Demo worlds: simulated Grafana dashboard and stream activity on machine screens, marked SIMULATED; nothing of the kind on a real cluster | verified in simulation (desktop and Compatibility renderers) |
| | Bundled browser engine (CEF), display builder, audio | unsupported: uses installed Edge or Chrome |
| V8 providers | Provider registry (Grafana, Tautulli), protected token storage, test connection | **verified live**: Grafana OSS 10.4.10, 11.2.0, 12.3.0, 13.0.0 (`tools\live-test.ps1 -Grafana`) and Tautulli 2.19.1 (`-Tautulli`) |
| | Grafana: dashboard search, panel list, time range, variables, credential-free links, sub-path | **verified live** on Grafana OSS 10.4.10, 11.2.0, 12.3.0 and 13.0.0; not Enterprise or Cloud |
| | Grafana: newer dashboard API and layouts, native charts from a data source | unsupported |
| | Tautulli: key handling, failures, missing values shown as unavailable | **verified live** on Tautulli 2.19.1 (no Plex behind it) |
| | Tautulli: real stream counts and bandwidth; the panel pinned to a machine | verified in simulation (stand-in server); needs a Plex server to test live |
| | Tautulli: history, home stats, libraries; control-room wall; Datapad pin | unsupported |
| 06-08 Krew | Porter and Bob with V3 models | verified in simulation |
| | Gauge: optional world model, read-only node request and capacity table, on-demand workload usage | UI verified in simulation; Docker usage verified live on a disposable container. Kubernetes metrics API figures not tested live |
| | Krew framework and operations center: shared findings with evidence, proposal and risk; resolved history; Markdown and JSON export; approval through the guard rails | verified in simulation (both renderers); verified live on Docker and a disposable kind cluster |
| | Sentinel (security), Scout (network), Scrappy (cleanup) with stations | verified live: Docker (disposable privileged container with the socket mounted) and kind (privileged host-root pod, a Service selecting nothing); approved removals verified in simulation only |
| | Archie (storage), Forge (build), Blueprint (architect) with stations | verified live on Docker with throw-away containers (database image without a volume, unnamed volume, Compose service with a stopped container); Forge's local-build check verified in simulation only, because Docker Desktop's containerd image store does not record image origin. Kubernetes in simulation and unit tests |
| | Gauge forecasts and right-sizing; backups and restores (Archie); build analysis and publishing (Forge); Compose/YAML import and Terraform plans (Blueprint); incident coordination | unsupported |
| 11 Multiplayer | Server mode: players connect to one KubeFactory server with tokens; roles and read-only enforced by the server | verified in simulation: a headless server and client games on both renderers (sign-in, wrong token, viewer refused, operator restart). TLS (`wss://`) and a second machine not tested |
| 08 Extensibility | Backend plugin API 1 (out-of-process, trusted by hash, read-only unless allowed) with an example | verified in simulation with the example plugin; input checking unit-tested |
| 09 AI | Providers (Ollama, LM Studio, OpenAI, Claude, OpenAI-compatible), redacted bounded context, typed proposals checked against a tool registry and the state, approval through the guard rails | verified with a mock provider (agent unit tests for both API shapes; in-game test on both renderers). **Not tested** against any real provider |
| | Read tools on demand, multi-step plans, streaming, cost limits beyond the per-request bounds, scheduled or autonomous actions | unsupported |
| 09A Foreman | Six identities (rules, Ollama, LM Studio, OpenAI, Claude, custom) mapped to their models, drawn fallback in the browser build; rules-only incidents and brief | verified in simulation (both renderers) |
| 10 Autonomy | Policy engine, self-healing, scheduling | unsupported |
| 11 Security | No credentials in logs, Git or shipped files; browser demo isolated | verified by review and by two tests (`TestInspectListsContextsWithoutSecrets`, `TestBadKubeconfigErrorsDoNotEchoContents`) |
| | Multiplayer beyond 1.0.1 presence | unsupported |
| 12 Verification | Unit tests (GDScript, Go), model audit, screenshot runs | done; the tests are in `tests/` and `agent/*_test.go` |
| | Live acceptance tests, large-scale benchmarks | kind and Docker tests completed; clean-machine, cloud and large-scale tests not completed |
| 13 Distribution | Windows, Linux and macOS packages with companion and models | published through [2.0.0-beta.3](https://github.com/DasCondor/kubefactory/releases/tag/v2.0.0-beta.3); packages have SHA-256 checksums and build-provenance attestations |
| | Platform code signing | macOS is ad-hoc signed; publisher signing and macOS notarization are unavailable |

## Remaining verification before a stable release

Tracked, with what blocks 2.0.0 and what can ship as a known limitation, in
[GO_LIVE_2.0.md](GO_LIVE_2.0.md).
