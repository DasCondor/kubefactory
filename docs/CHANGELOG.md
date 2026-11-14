# Changelog

## 2.0.0-dev (unreleased, branch `feature/kubefactory-2.0`)

Not a stable release. See `KNOWN_LIMITATIONS.md` for what has not been tested
against live infrastructure.

### Added
- **Native Kubernetes connectivity.** A small companion program (`kf-agent`)
  reads your kubeconfig and talks to the cluster directly. `kubectl` is no
  longer needed. A connection wizard lists kubeconfig files and contexts,
  takes a dropped file or pasted text, and explains failures in plain words.
- **Model library (V6).** 25 machine models, Porter and Bob from the supplied
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
- `tools/model_audit.gd` and `docs/MODEL_AUDIT.md`.
- `tools/live-test.ps1`: runs the companion against a real, disposable
  kube-apiserver without Docker.
- `KUBECONFIG` is honoured the way kubectl does.
- `docs/ARCHITECTURE.md`, `FEATURE_PARITY.md`, `KNOWN_LIMITATIONS.md`.

### Changed
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
