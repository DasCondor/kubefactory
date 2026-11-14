# Backend plugins

A backend plugin adds a new kind of source to KubeFactory: a hypervisor, a
NAS, a home-automation hub, a cloud API, anything that has "machines". The
game draws whatever the plugin reports as platforms (nodes), machines (pods),
workloads and belts (services), and the Krew reads it like any other source.

A plugin is a separate program, in any language, that talks to the game over
its standard input and output. It never runs inside the game, and it never
runs until you have trusted it.

## Installing one

Put the plugin's folder in `plugins/` beside KubeFactory (or in the game's
user-data folder under `plugins/`). Then Esc > Switch cluster > **Plugins...**:

- **Trust** runs it. Trust is tied to a SHA-256 over `plugin.json` and every
  file it lists: if any of them changes, the plugin is untrusted again until
  you approve the new version.
- **Allow changes** lets it act (restart, scale...) if it says it can. Without
  it, a plugin is read-only: the game offers none of its actions. Even with
  it, every action goes through the usual tool tiers, read-only mode and typed
  confirmation.

`examples/plugins/static-world` is a complete example (Python, read-only):
copy it into `plugins/` to try it.

## The folder

    plugins/my-plugin/
        plugin.json
        plugin.py        (or any program)

`plugin.json`:

```json
{
  "api": 1,
  "name": "My plugin",
  "version": "1.0.0",
  "description": "What it shows",
  "command": ["python3", "-I", "{dir}/plugin.py"],
  "files": ["plugin.py"]
}
```

- `command` is the program and its arguments. `{dir}` is replaced by the
  plugin's folder. A program named relative to the folder is found there.
  (`python3` is run as `python` on Windows.)
- `files` lists every file the plugin is made of. They are part of the trust
  hash; list everything the program loads.

## The protocol (API 1)

One JSON object per line in each direction. The game sends requests on the
plugin's stdin; the plugin answers each on stdout with the same `id`.
Anything else the plugin writes to stdout is ignored; logs go to stderr.

| Request | Answer `data` |
|---|---|
| `{"id": 1, "op": "hello", "args": {"api": 1}}` | `{"name": "...", "api": 1, "caps": {"logs": true, "restart": true, ...}}` |
| `{"id": 2, "op": "state", "args": {}}` | `{"nodes": [...], "pods": [...], "workloads": [...], "services": [...]}` |
| `{"id": 3, "op": "logs", "args": {"ns": "...", "name": "..."}}` | `{"text": "..."}` |
| `{"id": 4, "op": "action", "args": {"op": "restart", "ns": "...", "kind": "...", "name": "..."}}` | `{}` |

An answer is `{"id": <same>, "ok": true, "data": {...}}`, or
`{"id": <same>, "ok": false, "error": "what went wrong, in plain words"}`.

`state` is asked every few seconds. Its lists:

- **nodes**: `name`, `ready`, `cordoned`, `roles`, `zone`, `cpu` (cores),
  `mem` (bytes), `cpu_req`, `mem_req`
- **pods**: `name`, `ns`, `node` (a node's name), `status` (`Running`,
  `Pending`, `Completed`, `Error`, `CrashLoopBackOff`...), `ready`, `restarts`,
  `wkind`, `wname`, `labels`, `image` or `containers` (`name`, `image`,
  `restarts`, `reason`)
- **workloads**: `kind`, `name`, `ns`, `replicas`, `ready`
- **services**: `name`, `ns`, `type`, `ports`, `selector`

Everything is optional except names; missing numbers are treated as unknown.
The game checks, trims and caps every field (5000 machines, 500 nodes) and
treats the plugin's text as untrusted data.

Actions (`caps`): `restart`, `delete_pod`, `scale`, `scale_by`, `cordon`, with
the same arguments the built-in sources get. `logs` is the only capability
used without **Allow changes**, because it only reads.

Time limits: 10 s for `hello`, 20 s for `state` and `logs`, 60 s for an action.
A plugin that stops answering is shown as an error; the game never retries an
action.

## Versioning

`api` is the protocol version. A plugin written for another version is listed
with that reason and not run. Additions that do not break plugins (new
optional fields, new requests a plugin may answer with `ok: false`) keep the
version.
