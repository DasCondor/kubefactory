# Known limitations (2.0.0-dev)

Stated plainly so nobody has to find them the hard way. "Not tested" means
exactly that: the code exists and has not been run against the real thing.

## Not verified against live infrastructure

- **Native Kubernetes connectivity** has been run against a real Kubernetes API
  server, but not against a cluster that runs containers. `tools\live-test.ps1`
  starts the Kubernetes project's own kube-apiserver 1.32 and etcd and drives
  the companion through 40 steps (connect, watches, server-side apply, scale,
  restart, delete, cordon, RBAC refusal, presence): all pass. The game itself
  was then connected to the same server and its action tour succeeded. That
  server has no working nodes, so **logs, drain with pods to evict, exec and
  port-forward are not tested**, and neither is any cloud provider (EKS, AKS,
  GKE), Rancher, k3s or OpenShift, nor a sign-in helper actually signing in.
  Docker Desktop's engine would not start on the build machine, which is why
  no kind cluster was used.
- **Storage inspection** is verified in simulation only. Against the real API
  server, listing a pod's mounts works and the refusals are right (path outside
  the volume, container not running); reading actual files needs a running
  container and is not tested.
- **LiveView** is verified against a local test page (click, typing, blocked
  external link, 20 frames in 2 s). It has not been run against Grafana, or
  against a Kubernetes Service through a port-forward.
- **Port-forward** has no test of its own.
- No clean-Windows-machine installation test was done. No large-cluster
  benchmark (hundreds of nodes, thousands of pods) was done.

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

- Only the 25 machines, Porter and Bob are placed in the world. The other 13
  Krew members and the 101 V2 models (network, storage, structures, props,
  displays, tools) are shipped but not used: they are below the Porter V3
  standard or belong to features that do not exist yet.
- The library is V6. Its own notes say what it is not: no model is approved for
  release, 50 designs are still V2 legacy geometry, and its checks were
  sampled, not exhaustive. Nothing here changes that.
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
- The asset reviewer that came with the library is added to the Pages build at
  `model-viewer/`. It was checked locally (loads, no external requests, no
  console errors); it goes live only when this branch is merged and Pages
  deploys. It adds the whole library (about 72 MB) to the site. Not tested on a
  phone. Reviews stay in the browser that made them unless exported.
- The audit cannot detect two solid parts pushed into each other unless one of
  them is a display.

## Not implemented from the 2.0 handoff

See `FEATURE_PARITY.md` for the full table. In short: the Krew workforce beyond
Porter and Bob, the AI providers and Foreman, the autonomy and policy engine,
self-healing and scheduling, an in-game terminal, a bundled browser engine, a
native Docker Engine client, and Linux or macOS builds.
