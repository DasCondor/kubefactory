# Architecture

<sub>[KubeFactory](../README.md) · [All docs](../README.md#-docs-by-topic) · [2.0.0-beta.2 pre-release](https://github.com/DasCondor/kubefactory/releases/tag/v2.0.0-beta.2) · [Known limitations](KNOWN_LIMITATIONS.md)</sub>

KubeFactory is two programs: the game (Godot 4.3, GDScript) and a small native
companion (`kf-agent`, Go) that the game starts and talks to over a pipe. It
needs no server, no account and sends no telemetry; a KubeFactory server
([SERVER.md](SERVER.md)) is optional.

```
 KubeFactory.exe (Godot)                         kf-agent.exe (Go)
 ┌───────────────────────────────┐   JSON lines  ┌─────────────────────────────┐
 │ main.gd     input, tools      │  stdin/stdout │ kubeconfig  discover/inspect│
 │ world.gd    state -> 3D world │◄────────────►│ kube        client-go        │──► Kubernetes API (TLS)
 │ hud.gd      panels, wizard    │               │ files       pods/exec, r/o   │
 │ cluster.gd  polling, actions  │               │ forward     loopback forward │
 │ liveview.gd page -> texture   │               │ browser     Edge/Chrome, CDP │──► the app's own web page
 └──────┬────────────────────────┘               └─────────────────────────────┘
        │ backends (one is active)
        ├─ backend_native.gd   Kubernetes through kf-agent      (default)
        ├─ backend_kubectl.gd  Kubernetes through kubectl       (--kubectl-cli, or no companion)
        ├─ backend_docker.gd   local Docker engine through the docker CLI
        └─ backend_demo.gd     built-in simulation, no network  (the only backend in the browser build)
```

## The game

| File | Role |
|---|---|
| `scripts/main.gd` | game loop, input, tools, command-line switches, automated screenshot runs |
| `scripts/cluster.gd` | owns the active backend; polls on a worker thread; runs actions; audit log; signals `data_ready`, `connect_failed`, `agent_event` |
| `scripts/world.gd` | turns cluster state into platforms (nodes), machines (pods), Service lines, Porter, Bob and Gauge |
| `scripts/pipes.gd` | the Service lines as pipelines from the library's pipe kit (pipe runs, corner junctions, a valve into each machine); without the library, `world.gd` draws them as conveyor belts |
| `scripts/machine.gd` | one pod: library model or code-drawn model, door, interior, screen |
| `scripts/models.gd` | the model library: catalog, tier choice, door, display surfaces and type plate taken from the catalog's anchors |
| `scripts/hud.gd` | HUD, connection wizard, storage browser, LiveView window, Porter and Bob |
| `scripts/liveview.gd` | LiveView sessions: frames in, input out, frame rate by distance |
| `scripts/machine_screens.gd` | what each machine's screen shows: dashboard, metrics (usage graphs), logs, storage |
| `scripts/foreman.gd` | Foreman: incidents from the Krew's findings; the AI pipeline (context, redaction, reply parsing, tool registry checks); provider choice and identity |
| `scripts/server.gd` | server mode: WebSocket server, token sign-in (hashes only), roles and read-only enforced per request, state pushed to players |
| `scripts/backend_remote.gd` | a KubeFactory server as a source (the client side of server mode) |
| `scripts/plugins.gd`, `scripts/backend_plugin.gd` | backend plugins: discovery, trust by hash, the JSON-lines protocol, checking what a plugin sends |
| `scripts/krew.gd` | the Krew (Bob, Gauge, Sentinel, Scout, Scrappy, Archie, Forge, Blueprint): rules over the normalized state (and Scrappy's scan) produce findings; keeps first-seen times and the resolved history; actions only go through `hud.guarded_act` |
| `scripts/gauge.gd` | read-only resource observations and formatting; workload usage comes through the existing `pod_metrics` backend operation |
| `scripts/demo_screens.gd` | the simulated Grafana and stream screens of the demo worlds |
| `scripts/providers.gd` | Grafana and Tautulli providers: requests to the companion, pinned summaries |
| `scripts/icons.gd` | application icons, drawn in code |
| `scripts/mobile_controls.gd` | touch controls, browser build only |
| `scripts/connections.gd` | saved kubeconfig profiles and which exec helpers you have trusted |
| `scripts/agent.gd` | starts `kf-agent`, sends requests, collects events and frames |
| `scripts/gfx.gd`, `scenery.gd`, `bench.gd` | Standard / Enhanced / Ultra presets, surroundings, benchmark |

State flows one way: backend → `cluster.gd` (normalised dictionary) → `world.gd`
→ scene. Every backend produces the same dictionary, so tools, tiers, the audit
log, Porter and Bob do not know which backend is active.

## The companion

`agent/` is one Go module. `main.go` reads one JSON object per line from stdin
and answers on stdout; each request carries an `id`, an `op` and arguments.
Unsolicited lines carry `event` (`watch`, `frame`, `nav`, `blocked`,
`forward_closed`). Errors carry a `kind` the game turns into a plain sentence:
`config`, `exec_untrusted`, `needs_base_dir`, `auth`, `rbac`, `tls`, `timeout`,
`unreachable`, `notfound`, `conflict`, `invalid`, `unsupported`, `other`.
On exit the game stops its workers, requests companion shutdown and joins the
pipe reader. The companion finishes outstanding requests and closes browser
sessions, temporary profiles, forwards and Kubernetes sessions before exiting.
If it does not exit within 15 seconds, the game terminates its child process.

| File | Ops |
|---|---|
| `kubeconfig.go` | `kubeconfig.discover`, `kubeconfig.inspect` (never returns secret material) |
| `kube.go` | `kube.connect`, `can`, `watch`, `list`, `scale`, `restart`, `delete`, `create_deployment`, `cordon`, `drain`, `logs`, `events`, `apply` (server-side), `presence`, … |
| `files.go` | `files.mounts`, `files.list`, `files.read` |
| `forward.go` | `kube.forward`, `kube.forward_stop` |
| `browser.go` | `browser.find`, `open`, `close`, `rate`, `navigate`, `input` |
| `komodo.go` | `komodo.list`, `save`, `remove`, `test`, `state`: Komodo Core, read requests only (a fixed list), key and secret sealed |
| `ai.go` | `ai.list`, `save`, `remove`, `test`, `ask`: Foreman's AI providers (OpenAI-compatible and Claude APIs). Keys sealed like provider tokens; cloud consent; bounded, no redirects, no retries |
| `providers.go` | `provider.list`, `save`, `remove`, `test`, `link`; `grafana.dashboards`, `panels`, `link`; `tautulli.activity`. Tokens sealed in `provider_seal_windows.go` |

Dependencies are client-go (the Kubernetes project's own client) and chromedp
(a Chrome DevTools Protocol client). Nothing else is linked in.

## Trust boundaries

1. **Kubeconfig** stays on disk where it is, or in the user folder if pasted.
   The companion reads it; its contents are never logged, sent to the game's
   UI in full, or sent anywhere else. `kubeconfig.inspect` reports names, the
   server address and the *kind* of authentication only.
2. **Exec credential helpers** (`aws`, `gke-gcloud-auth-plugin`, `kubelogin`…)
   are programs named by the kubeconfig. The companion refuses to run one until
   you have approved that exact command for that profile in the wizard.
3. **Storage inspection** runs fixed commands (`ls`, `head`, `dd`) inside the
   pod's own container through the Kubernetes exec API. Paths are confined to
   a mounted volume, symlinked directories are refused, Secret and projected
   volumes are never read, pages are 64 KiB and at most 256 per file. It never
   creates a helper pod and never mounts anything.
4. **LiveView** runs the installed Edge or Chrome headless with a throw-away
   profile that is deleted on close. Requests to any host other than the one
   you opened are refused. The page is pixels in the game: it cannot reach the
   game, your files or your kubeconfig.
5. **The browser demo** uses only the simulation backend. Desktop adapter
   scripts may be included in the export, but the browser build has no
   companion or local infrastructure access.
   An explicitly selected desktop simulation also skips kubeconfig discovery,
   Docker probing and restoration of real provider screens. The cluster
   switcher's discovery button initiates local discovery when requested.
   Simulated actions do not send audit webhooks or fetch online app lists.

## Models

`assets/catalog.json` lists 141 models, each at three tiers (Standard,
Enhanced, Ultra). The desktop renderer loads the GLB for the active preset at
run time and merges it into one shared mesh per model, plus separate door,
accent and lamp parts. The browser build and any copy without `assets/` draw
the earlier code-built models, so the library is never required to run.
`tools/model_audit.gd` checks every file; see `MODEL_AUDIT.md`.

## Builds

`tools/package.ps1` runs the tests, builds the companion, exports the game and
zips both with the model library. `.github/workflows/release.yml` does the same
on a tag; `pages.yml` publishes the browser demo.
