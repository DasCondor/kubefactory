# Connection map and YAML review

These features are available in the local 2.2 demo. They have not been published.

## Spider map

Open **Esc → Docker media lab → Visual whiteboard**. The map opens framed around
every endpoint. Applications form branches around their connections, with storage
volumes at the ends. Select a card to emphasize its connections. **Find app /
storage** centers a card at a readable scale. **Spider layout** rearranges around
the selected card. Cards remain movable, and **Save whiteboard** preserves the
layout on this device. Older column layouts remain in the settings file until a
new layout is saved.

## Edit files from the spider map

Double-click an app or storage card, or select it and choose **Config / storage files**. App cards
open their mounted volumes. A shared-storage card opens that volume, with a choice
of app access paths when several containers mount it. **Inspect selected** also
provides file access: storage summaries have **Browse / edit files** beside each
mount, and pod inspectors have **Config / storage files**. **Back** returns to
the previous summary or selected board card. The existing **Edit / export YAML** button edits
the setup draft separately.

Open a text file, choose **Edit file**, edit with Standard, Vim or Nano keys,
then **Save → Save file**. Saving changes the actual mounted file on supported
desktop Docker or native Kubernetes/k3s connections. It requires MK.3 permission,
a writable session and mount, and a running container. The editor stays open if
approval is canceled, access is refused or the file changed since it was opened.
Other containers mounting the same volume see the saved contents.

Each save keeps the previous file in a private `.kf-edit.*/previous` backup in
the same directory and preserves its file permissions. Saves replace existing
regular UTF-8 text files of at most 64 KiB. Binary databases, media, symlinks,
secret/projected volumes and read-only mounts cannot be edited. Kubernetes
ConfigMap/downward files must be changed through their source configuration;
single-file bind mounts must be edited at their source. Containers need shell,
base64, SHA-256 and ordinary file tools for live saves. Legacy kubectl-only and
other unsupported backends remain read-only.

Simulated files are clearly labeled and edits last only until that demo closes.
`demo-settings.yaml` is an invented editing sample, not a production app's actual
configuration file. Live apps may overwrite their config while running or require
a reload; use their normal settings UI for app-managed files. Conflict checking
detects changes before replacement, but cannot lock out an external application.
Nothing in this workflow automatically restarts or deploys an application.

The file workflow, canceled/failed saves, backups, permissions and maximum-size
files have been tested in simulation and on a disposable local Docker volume.
Native Kubernetes write validation is covered by companion tests; live writes to
a Kubernetes/k3s cluster remain unverified.

## Porter proposal

Ask Porter about a setup, enter its namespace/project, and choose **Preview this
setup**. Catalogue templates use **Preview build**. The proposal shows the current
cluster and nodes, existing workloads, and green proposed additions or updates.
Services, known storage/configuration references and configured reporting/database
connections are included. Kubernetes placement is a scheduling proposal, rather
than a promise that a workload will fit a particular node.

**Review / edit YAML** opens the proposed Kubernetes/k3s configuration. Exporting
requires a separate **Approve export** step, followed by a save location on the
desktop or a browser download. Canceling does not deploy or alter anything.
**Deploy this setup** remains a separate action with the existing tool permissions.
It deploys the selected bundled setup; the YAML editor does not apply edited YAML.

## YAML editing and export

**Edit / export YAML** is also available from the whiteboard, network view and
cluster flowchart. **Open YAML** loads existing `.yaml`/`.yml` files. Comments,
anchors, custom resource documents and multi-document files remain editable text.
The original file is preserved. **Save draft** saves inside the game's user folder;
**Export YAML** exports the reviewed text after approval.

Connected native Kubernetes and kubectl sources read the specifications of the
visible workloads and Services on demand. Runtime status, identity fields and
assigned Service addresses are removed. This is a map export, not a cluster backup.
Other kinds and configuration files can be opened or pasted into the editor.

Simulation, Docker and new flowcharts generate review drafts. They include workload
and Service definitions, known persistent mounts, and a topology ConfigMap. Routes
and VLAN intent still need CNI/network configuration. Application environment,
credentials, storage drivers and settings need operator review. New flowchart
images are placeholders and their Deployments start at zero replicas.

Docker applications sharing a Gluetun network are grouped into one Pod. The VPN is
a restartable init sidecar, with a startup health probe before app containers start.
That draft needs Kubernetes/k3s 1.29 or newer and a `<gateway>-vpn` Secret. See the
[Kubernetes sidecar documentation](https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/)
and [Gluetun health check documentation](https://github.com/qdm12/gluetun-wiki/blob/main/faq/healthcheck.md).
Shared volumes require compatible placement and storage; the standard k3s
[local-path provisioner](https://docs.k3s.io/add-ons/storage) stores data on a host.

Exports have been parsed offline and exercised in the local demo. They have not
been applied to a live Kubernetes/k3s cluster. Validate the reviewed configuration
against the intended cluster before deploying it.
