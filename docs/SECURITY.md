# Security

<sub>[KubeFactory](../README.md) · [All docs](../README.md#-docs-by-topic) · [2.0.0-beta.1 pre-release](https://github.com/DasCondor/kubefactory/releases/tag/v2.0.0-beta.1) · [Known limitations](KNOWN_LIMITATIONS.md)</sub>

## Reporting a problem

Please report security problems privately through GitHub's
"Report a vulnerability" button on the repository's Security tab, not in a
public issue. Include what you did, what happened, and the version (shown in
the Esc menu).

## What KubeFactory can and cannot do

KubeFactory needs no server and has no credentials of its own (server mode,
[SERVER.md](SERVER.md), is optional). It talks to
Kubernetes through its companion program (`kf-agent`, started by the game,
using your kubeconfig) and to Docker through the `docker` already on your
machine, as you. It can do exactly what your own account can do, and nothing
more.

- **Your kubeconfig is read, never copied out.** The companion reads it to
  connect. Its contents are not written to any log, not shown in full in the
  game, and not sent anywhere except, as credentials, to the cluster it names.
  Pasted kubeconfig text is stored in your user folder only.
- **Sign-in helpers need your approval.** A kubeconfig can name a program to
  run for credentials. KubeFactory will not run it until you approve that
  exact command for that profile, and never runs anything else an imported
  file names.
- **Storage inspection is read-only and confined.** It lists and reads files
  inside a pod's mounted volumes using fixed commands in the pod's own
  container. It refuses paths that leave the volume, never reads Secret or
  service-account volumes, never creates a pod and never adds a mount. It
  needs the `pods/exec` permission; without it you get "not permitted".
  File previews are shown as text or hex and are never run or rendered as HTML.
- **LiveView is a separate, disposable browser.** It uses the Edge or Chrome
  on your machine, headless, in a profile created for that display and deleted
  when it closes. It can only load the host you opened; everything else is
  refused. It has no access to your own browser's cookies or saved passwords.
  Port-forwards it uses listen on 127.0.0.1 only.

- **Your cluster permissions are the security boundary.** The in-game tool
  tiers, protected namespaces and typed confirmations are guard rails against
  mistakes. Anyone with `kubectl` can bypass the game, so anything that must
  not happen has to be prevented with Kubernetes RBAC. See ADMIN.md.
- **Presence and the shared action feed are self-reported.** A user allowed
  into the `kubefactory` namespace could post under another name. The
  authoritative record of who did what is your API server's audit log.
- **The browser demo connects to nothing.** It only runs the built-in
  simulation.

## What appears on screen

KubeFactory is often shown to other people (screenshots, streams, a shared
screen), so it keeps details of your computer off the screen:

- Any path under your own user folder is shown as `~` (for example
  `~/.kube/config`), in panels, notes and error messages alike.
- On a cluster you are shown by the name the cluster gives you, which everyone
  on that cluster can already see. On the local Docker engine, where there is
  no such identity, you are shown as *local user* rather than by your Windows
  account name. In the simulated worlds you are *DasCondor*.
- Your account name is still written to the audit log on this computer, and
  sent to an audit webhook only if you configure one: that is what they are for.
- `tools\bench.ps1` leaves the graphics card model out of the published
  benchmark table unless you pass `-ShowGpu`.

## Grafana and Tautulli tokens

- A token is typed once, handed to the companion, and sealed with the Windows
  Data Protection API for your Windows account. The game keeps no copy, no
  operation returns it, and it is not in `providers.json` in readable form.
  On systems without that protection a token is refused rather than stored
  in the clear.
- Links the game opens (a dashboard, a panel) carry no credential. The page
  runs in LiveView's disposable browser and asks you to sign in yourself.
- Only the provider's own address is contacted; redirects are not followed.
  Plain http is accepted for this computer, or for another one only after you
  tick the box that says the token would travel unprotected.
- Tautulli: one read-only request (`get_activity`), from which only totals
  are taken. No user names, addresses, titles or history are read out, and
  there is no way to send any other command. The key goes in a header; the
  key-in-address mode for Tautulli older than 2.18 is off unless you turn it
  on, because that server may then log the key.
- Changing a provider's address drops its saved token: a token belongs to the
  address it was entered for.

## Foreman's AI providers

- Off by default: Foreman works from rules alone, and the browser build has no
  way to reach a provider.
- API keys are handled like provider tokens: typed once, sealed by the
  companion for your Windows account, never returned, logged or shown. An error
  a provider sends back has the key removed before the game sees it.
- A provider whose address is not this computer is a cloud provider. Nothing is
  sent to it until you set **Cloud: ALLOWED** for that provider. Switching
  providers never resends a question, and an outage never falls over to
  another provider.
- What is sent: the question and a summary the game builds (names, states,
  counts and the Krew's findings), with passwords, tokens, keys, URL
  credentials, private keys, long encoded strings and your home folder
  removed. **Show what is sent** displays it. No logs, files, kubeconfig,
  socket or credential is given to the model.
- The model's reply is untrusted. It is told that the context is data, not
  instructions, but the protection does not depend on that: a proposed action
  must name a tool from a fixed list and a resource that exists, becomes the
  game's own typed operation, and runs only when you press its button, through
  the tiers, read-only mode and confirmation. There is no shell tool.
- Bounded: 48 KiB per question, 8192 answer tokens, 120 s, 2 MiB reply, one
  question at a time per provider, no retries, redirects not followed.

## How secrets are handled

- Authentication is whatever your kubeconfig and Docker setup already use.
  KubeFactory keeps a list of the kubeconfig files you added (their paths) in
  `connections.json` in your user folder. If you paste kubeconfig text instead
  of pointing at a file, that text is saved in the same folder, as plain text
  like any kubeconfig: protect it the same way. Removing the profile in the
  wizard deletes it.
- Generated database passwords go straight into a Kubernetes Secret (via a
  short-lived temporary file, never the command line). On a plain Docker engine
  they are written to a per-project `.env` file in your user folder.
- API keys, basic-auth users and webhook URLs you put in `portainer.json`,
  `log-providers.json` or `policy.json` are passed to `curl` through a
  short-lived config file rather than command-line arguments. Those files are
  plain text: protect them like any other file holding a key, and do not commit
  filled-in copies.
- An API key is only ever sent over https, and TLS certificates are verified
  unless you set `"insecure_tls": true` in `portainer.json`.
- The audit log records actions, not secrets.

## App lists are untrusted input

App lists come from the internet. Before anything from a list is built:

- every template is validated (image name, paths, setting names, restart
  policy, port protocols) and refused if anything is malformed;
- nothing is ever passed through a shell, so template text cannot run commands
  on your machine;
- host-path mounts (for example the Docker socket) are left out unless you
  tick an explicit box for that template.

A template still decides which container image runs. Only build from lists and
images you trust, as you would with `docker run`.

## Downloads

The setup script and the build workflows verify the Godot engine and export
templates against pinned SHA-512 checksums. Releases ship with a SHA-256
checksum per package and one `SHA256SUMS`, and each package has a build
provenance attestation signed through Sigstore by the release workflow
(`gh attestation verify <package> -R DasCondor/kubefactory` checks it came from
this repository's workflow at a given commit). No package is signed with a
Windows or Apple developer identity: Windows SmartScreen warns on first run,
and the macOS app is only ad-hoc signed (not notarized), so Gatekeeper blocks
it until the quarantine flag is cleared. The companion's Go dependencies
are pinned by `agent/go.sum`.
