# KubeFactory server

Run KubeFactory once as a **server** next to your cluster or Docker engine;
everyone else connects to it like a game client. Players never hold a
kubeconfig, a Docker socket or any other credential: the server owns the
connection and checks every request.

## Starting it

    KubeFactory --headless -- --server --context=<kube context>
    KubeFactory --headless -- --server --docker --context=<docker context>
    KubeFactory --headless -- --server --demo

Options after `--`:

| Option | Meaning |
|---|---|
| `--server[=port]` | serve on this port (default 7666) |
| `--listen=<address>` | the address to listen on; default `127.0.0.1` (this machine only) |
| `--tls-cert=<pem> --tls-key=<pem>` | speak `wss://` with this certificate |
| `--read-only` | refuse every change for everyone |

Any source option works as usual (`--context`, `--docker`, `--kubeconfig`...).

## Tokens and roles

On first start the server creates two tokens, one **operator** and one
**viewer**, and writes them once to `server-new-tokens.txt` in its data folder
(the user-data folder, or `KF_SERVER_DIR` if set). Hand each to one person and
delete the file: the server keeps only SHA-256 hashes, in `server-tokens.json`.

| Role | Can do |
|---|---|
| viewer | see everything and read (logs, events, storage listings, metrics): MK.1 |
| operator | act up to MK.4 (restart, scale, cordon, remove a pod or image) |

Roles are enforced by the server, not the client. The server's `--read-only`
wins over every role. Every action and every sign-in is written to the
server's audit log with the token's name. To add or change people, edit
`server-tokens.json`: each entry is keyed by the token's SHA-256 and has a
`name`, a `role` and a `tier` (1-5).

## Connecting

In the game: Esc > Switch cluster > **KubeFactory server...**, enter the
address (`ws://...` or `wss://...`) and your token. The token is not saved.

From the command line: `KubeFactory -- --remote=wss://host:7666` with the
token in the environment variable `KF_REMOTE_TOKEN` (never on the command
line, where other programs could read it).

A viewer's game shows **READ-ONLY**; a refused action says why ("your role on
this server allows up to MK.1").

## Exposing it safely

By default the server only listens on 127.0.0.1. To reach it from other
machines, any of:

- an SSH tunnel: `ssh -N -L 7666:127.0.0.1:7666 you@server`
- a TLS reverse proxy (Caddy, nginx, Traefik) in front of it
- `--listen=<address> --tls-cert=... --tls-key=...` for `wss://` directly

Plain `ws://` on a network address sends tokens unencrypted; the server warns
when started that way.

## Protocol (version 1)

WebSocket text messages, one JSON object each.

| From | Message |
|---|---|
| client | `{"op": "hello", "token": "...", "protocol": 1}` (within 10 s of connecting) |
| server | `{"type": "hello", "ok": true, "role": ..., "tier": ..., "read_only": ..., "source": ..., "context": ...}` or `ok: false` with `msg` |
| server | `{"type": "state", "state": {...}}` whenever the state changes |
| client | `{"op": "act", "id": n, "action": {...}}` (the same actions the game uses) |
| server | `{"type": "result", "id": n, "result": {"ok": ..., "msg": ..., "text": ...}}` |
| server | `{"type": "feed", "action": {...}, "ok": ...}` when anyone's action finishes |

Limits: 32 players, 1 MiB per message from a player.
