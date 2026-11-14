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
| Scale, restart, delete, deploy, cordon, drain | kubectl path unchanged; native path added | native path: verified on a real API server (40-step companion run, and the game's own action tour: create, scale, restart, cordon, uncordon, delete). Drain: only on an empty node. kubectl path: not re-tested this cycle |
| Logs and events | native path added | events: verified on a real API server. Logs: **not tested** (no running container to produce any) |
| Porter: app setups, Portainer templates | unchanged; applies through server-side apply on the native path | native apply: verified on a real API server (the game deployed and removed the postgres setup and a Portainer template) |
| Bob and Bob 2.0 log reading | unchanged | verified in simulation |
| Multi-user presence and action feed | native path added | verified on a real API server (one player; two players at once not tested) |
| Docker engine edition | unchanged (docker CLI) | not re-tested this cycle: Docker engine down on the build machine |
| Graphics presets and benchmark | unchanged | verified in simulation |
| Audit log, log providers, sound, datapad, codex | unchanged | verified in simulation |

Nothing was removed. `--kubectl-cli` selects the 1.0.1 Kubernetes path.

## 2.0 handoff

| Section | Item | Status |
|---|---|---|
| 00 Native connectivity | Kubeconfig discovery, import by file / drop / paste, context list | verified in simulation (real kubeconfig file, fake API server) |
| | Connect without kubectl (client-go) | verified on a real API server, from the companion and from the game; **not tested** on a cluster with working nodes or on any cloud provider |
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
| | Read-only storage browser | verified in simulation; **not tested live** |
| | Porter V3 as minimum standard | machines, Porter and Bob use V3; V2 models are not placed |
| 02 Docker | Native Docker Engine API | unsupported (docker CLI kept) |
| 02 Kubernetes | Server-side apply, cordon, scale, rollout restart | verified on a real API server |
| | Drain with pods to evict | **not tested** |
| | Exec / terminal, ephemeral debug containers, Helm, CRD browsing | unsupported |
| 03 World and graphics | Non-regression presets | verified in simulation (`BENCHMARK.md`) |
| 04 Assets and operator experience | Control center, accessibility options | unsupported beyond what 1.0.1 had |
| 05 LiveView | Real page on an in-game screen, mouse and keyboard | verified in simulation (local test page) |
| | Endpoint discovery (Docker published ports, Kubernetes Services) | verified in simulation (unit tests) |
| | Port-forward for cluster Services | not tested |
| | Host allowlist, isolated profile, no stand-in pictures | verified in simulation |
| | Bundled browser engine (CEF), display builder, audio | unsupported: uses installed Edge or Chrome |
| 06-08 Krew | Porter and Bob with V3 models | verified in simulation |
| | The other Krew roles, shared framework, operations center, incident coordination | unsupported |
| 09 AI | Providers, action pipeline, tool registry, natural-language workflows | unsupported |
| 09A Foreman | Provider-specific characters | unsupported (models shipped, not placed) |
| 10 Autonomy | Policy engine, self-healing, scheduling | unsupported |
| 11 Security | No credentials in logs, Git or shipped files; browser demo isolated | verified by review and by two tests (`TestInspectListsContextsWithoutSecrets`, `TestBadKubeconfigErrorsDoNotEchoContents`) |
| | Multiplayer beyond 1.0.1 presence | unsupported |
| 12 Verification | Unit tests (GDScript, Go), model audit, screenshot runs | done; see the PR description for results |
| | Live acceptance tests, large-scale benchmarks | not tested |
| 13 Distribution | Windows zips with companion and models | built locally; not published |
| | Linux / macOS builds, signing | unsupported |

## What has to happen before this is called a release

1. Run the native path against a cluster that runs containers (kind is enough
   to start): logs, drain with pods, a pod reaching Running, and at least one
   cloud provider with its sign-in helper.
2. Open a storage door on a real pod with a volume; try a distroless image.
3. Open Grafana through LiveView on Docker and through a port-forward.
4. Install the zip on a Windows machine that has never had kubectl or Go.
