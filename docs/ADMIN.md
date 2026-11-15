# KubeFactory for teams: admin guide

<sub>[KubeFactory](../README.md) · [All docs](../README.md#-docs-by-topic) · [2.0.0-beta.1 pre-release](https://github.com/DasCondor/kubefactory/releases/tag/v2.0.0-beta.1) · [Known limitations](KNOWN_LIMITATIONS.md)</sub>

This guide is for teams where every player runs the game with their own
cluster login, and the cluster is the shared channel between them. The other
way, one KubeFactory server that everyone connects to with a token, is in
[SERVER.md](SERVER.md).

## The model in one minute

| Layer | What it does | Who controls it |
|---|---|---|
| Kubernetes RBAC | What a person can really do. KubeFactory only ever runs `kubectl` as that person. | Cluster admin, as usual |
| Tool-tier policy | Guard rail in the game: the highest tool tier (Mk.1-Mk.5) each person may use, protected namespaces, typed confirmation. | Cluster admin (ConfigMap) and each player's local `policy.json` |
| Presence | Players see each other as avatars with name and tool. One Lease per player in the `kubefactory` namespace, refreshed every 4 seconds. | Automatic |
| Action feed | Every change made through the game is posted as an Event in the `kubefactory` namespace and shown to other players. | Automatic |
| Audit | Each player's local audit file, the action feed, an optional webhook, and (authoritative) your API server audit log. | You |

The tool-tier policy is a safety rail, not a security boundary: a person with
`kubectl` can bypass the game entirely. Use RBAC for what must not happen.

## Set up a cluster (once)

```bash
kubectl apply -f deploy/kubefactory.yaml
```

This creates the `kubefactory` namespace, the policy ConfigMap, a role that lets
every signed-in user announce presence and post to the feed, and three
ready-made ClusterRoles to bind to people.

Clusters without this setup still work; players just do not see each other, and
only local policy applies.

## Give people access

```bash
# read-only across the cluster (Mk.1)
kubectl create clusterrolebinding bob-view --clusterrole=kubefactory-viewer --user=bob

# build / scale / restart in one namespace only (Mk.2-Mk.3)
kubectl create rolebinding alice-ops -n shop --clusterrole=kubefactory-operator --user=alice

# everything, for a group (Mk.4-Mk.5)
kubectl create clusterrolebinding sre-admin --clusterrole=kubefactory-admin --group=sre
```

Namespace-limited people should have that namespace set in their kubeconfig
context; the game shows them that namespace only.

## Set tool tiers

```bash
kubectl edit configmap kubefactory-policy -n kubefactory
```

```text
{
  "max_tier": 3,                              default for everyone
  "users":  { "alice": 3, "bob": 1 },         per person (wins over groups)
  "groups": { "sre": 5 },                     best matching group
  "protected_namespaces": ["kube-system"],
  "protected_max_tier": 1,                    limit inside protected namespaces
  "confirm_tier": 5,                          this tier and above: type the target's name
  "presence": true
}
```

Players pick up policy changes within a few seconds. Your own admin user or
group must be listed with tier 5, or you are held to the default as well.

| Tier | Actions |
|---|---|
| Mk.1 Safe | inspect, logs, events |
| Mk.2 Constructive | create, scale up, deploy app setups, uncordon |
| Mk.3 Disruptive | rolling restart, scale down, cordon |
| Mk.4 Destructive | delete a pod |
| Mk.5 Critical | delete a workload, drain a node, remove an installed app |

## Per-player rules and central audit (`policy.json`)

```json
{
  "contexts": [ { "match": "prod", "max_tier": 3, "confirm_tier": 4 } ],
  "audit_webhook": "https://hooks.example.com/..."
}
```

- `contexts`: stricter limits for any kubeconfig context whose name contains
  `match`. The shipped file limits contexts containing "prod" to Mk.3.
- `audit_webhook`: every change is also POSTed there as JSON (`text`, `user`,
  `context`, `action`, `ok`, `result`, `tier`, `time`). The `text` field makes it
  work directly with Slack-style incoming webhooks.

Ship your own `policy.json`, `catalogs.json` and `log-providers.json` in the zip
you hand out (`tools\package.ps1` builds it; in the source tree the files are in `config\`).

## What to know before rolling it out

- Presence and the action feed are self-reported: anyone allowed into the
  `kubefactory` namespace could post under another name. Treat them as
  convenience; the API server audit log is the record of who did what.
- Each player adds about three small API requests every 4 seconds for presence,
  plus one cluster-wide list every 3 seconds for the view.
- Two people scaling the same workload at once is safe: scaling is relative and
  retried if the count changed underneath.
- Read-only mode (`play.bat --read-only`, or the Esc menu) blocks every change
  regardless of policy.
- From 2.0 players do not need `kubectl`: the game's companion uses their
  kubeconfig directly. The commands in this guide are for you, the admin.
- **Storage inspection and LiveView need permissions the bundled roles do not
  grant.** Opening a machine to browse its volumes uses `pods/exec`; LiveView
  on a cluster Service uses `pods/portforward`. Both are powerful: `pods/exec`
  lets a person run anything in a container. `deploy/kubefactory.yaml` leaves
  them out on purpose. Grant them only where you would grant `kubectl exec`
  and `kubectl port-forward`, for example:

```bash
  kubectl create role kf-inspect -n shop --verb=create --resource=pods/exec,pods/portforward
  kubectl create rolebinding alice-inspect -n shop --role=kf-inspect --user=alice
```

  Without them those two features answer "not permitted"; everything else works.

## Try it on one machine

```powershell
tools\dev-cluster.ps1    local 3-node cluster
tools\dev-users.ps1      applies the setup and creates two test logins
play.bat --context=kind-kubefactory     admin
play.bat --context=kf-alice             operator, namespace shop only
play.bat --context=kf-bob               viewer
```
