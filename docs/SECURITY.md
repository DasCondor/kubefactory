# Security

## Reporting a problem

Please report security problems privately through GitHub's
"Report a vulnerability" button on the repository's Security tab, not in a
public issue. Include what you did, what happened, and the version (shown in
the Esc menu).

## What KubeFactory can and cannot do

KubeFactory has no server and no credentials of its own. It talks to
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
checksum file. Neither `KubeFactory.exe` nor `kf-agent.exe` is code-signed, so
Windows SmartScreen will warn on first run. The companion's Go dependencies
are pinned by `agent/go.sum`.
