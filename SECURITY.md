# Security

## Reporting a problem

Please report security problems privately through GitHub's
"Report a vulnerability" button on the repository's Security tab, not in a
public issue. Include what you did, what happened, and the version (shown in
the Esc menu).

## What KubeFactory can and cannot do

KubeFactory has no server and no credentials of its own. It runs the `kubectl`
and `docker` already on your machine, as you. It can do exactly what your own
account can do, and nothing more.

- **Your cluster permissions are the security boundary.** The in-game tool
  tiers, protected namespaces and typed confirmations are guard rails against
  mistakes. Anyone with `kubectl` can bypass the game, so anything that must
  not happen has to be prevented with Kubernetes RBAC. See ADMIN.md.
- **Presence and the shared action feed are self-reported.** A user allowed
  into the `kubefactory` namespace could post under another name. The
  authoritative record of who did what is your API server's audit log.
- **The browser demo connects to nothing.** It only runs the built-in
  simulation.

## How secrets are handled

- KubeFactory stores no cluster credentials. Authentication is whatever your
  kubeconfig and Docker setup already use.
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
checksum file. The Windows executable is not code-signed, so Windows
SmartScreen will warn on first run.
