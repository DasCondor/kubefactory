# Feature parity

Two questions: does 2.0 still do everything 1.0.1 did, and how much of the 2.0
handoff is in?

Status words, used the same way everywhere:

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
| | Asset reviewer hosted at `model-viewer/` | added to the Pages build; verified locally, not deployed |
| | Opening storage doors, stopped by obstacles | verified in simulation |
| | Read-only storage browser | **verified live** on kind and on a real Docker container; links are never followed |
| | Porter V3 as minimum standard | machines, Porter and Bob use V3; V2 models are not placed |
| 02 Docker | Native Docker Engine API | unsupported (docker CLI kept) |
| | Several Docker hosts (CLI contexts), read-only by default for other machines, read-only proxy recipe | **verified live** through a throw-away read-only proxy: state, `docker inspect`, the image scan, and the host refusing a removal with read-only off. The SSH tunnel and a separate physical host not tested |
| | Komodo Core, read-only: servers and containers | verified against a mock Komodo built from the komodo_client request and entity shapes (agent tests, in-game test on both renderers). **Not tested** against a real Komodo Core |
| 02 Kubernetes | Server-side apply, cordon, scale, rollout restart | verified on a real API server |
| | Drain with pods to evict | **verified live** on the disposable kind cluster |
| | Exec / terminal, ephemeral debug containers, Helm, CRD browsing | unsupported |
| 03 World and graphics | Non-regression presets | verified in simulation (`BENCHMARK.md`) |
| 04 Assets and operator experience | Control center, accessibility options | unsupported beyond what 1.0.1 had |
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
| 12 Verification | Unit tests (GDScript, Go), model audit, screenshot runs | done; see the PR description for results |
| | Live acceptance tests, large-scale benchmarks | kind and Docker tests completed; clean-machine, cloud and large-scale tests not completed |
| 13 Distribution | Windows zips with companion and models | built locally; not published |
| | Linux / macOS builds, signing | unsupported |

## What has to happen before this is called a release

1. Test a cloud provider and its sign-in helper. The native path has been run
   against kind with running containers, including logs and drain with pods.
2. Open a storage door on a real pod with a volume; try a distroless image.
3. Open Grafana through LiveView on Docker and through a port-forward.
4. Install the zip on a Windows machine that has never had kubectl or Go.
