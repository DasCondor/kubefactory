# Docker hosts without giving KubeFactory root

Access to a Docker engine is root on that machine: whoever can talk to the
socket can start a privileged container. Adding a user to the `docker` group
is the same thing. If you only want to *look* at your Docker hosts from
KubeFactory, give it a read-only door instead.

## How KubeFactory finds hosts

Every Docker CLI context is a connection on the cluster switcher (Esc >
Switch cluster). Four hosts are four contexts:

    docker context ls

A context on another machine (a `tcp://` or `ssh://` address) **opens in
read-only mode**: KubeFactory shows everything and blocks every action. You
can turn that off from the Esc menu, which is why the next part matters:
read-only in the game is a promise from the client; a read-only proxy on the
host is enforced by the host.

## A read-only proxy on each host

`deploy/docker-readonly/compose.yaml` runs
[docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy)
(pinned version) with `POST=0`: it passes reads to the engine and rejects
every change. It listens on `127.0.0.1:2375` of that host only.

On each Docker host:

    docker compose -f compose.yaml up -d

(that one step needs whoever already manages Docker there).

## Reaching it without root

On the machine running KubeFactory, tunnel to each host over SSH as an
ordinary user, one local port per host:

    ssh -N -L 23751:127.0.0.1:2375 you@host1
    ssh -N -L 23752:127.0.0.1:2375 you@host2

and make a context for each:

    docker context create host1 --docker host=tcp://127.0.0.1:23751
    docker context create host2 --docker host=tcp://127.0.0.1:23752

The SSH user needs no docker group membership and no sudo: the tunnel only
reaches the proxy's port. The traffic is encrypted by SSH.

Then in KubeFactory: Esc > Switch cluster, pick `host1`.

## What works read-only

Everything that looks: containers, Compose projects and services, logs,
`docker inspect` facts for the Krew (Sentinel, Scout, Archie), resource
figures, Scrappy's and Forge's image and volume scan. Everything that changes
anything is refused by the proxy: restart, remove, deploy, exec. Opening a
machine's storage door needs `exec`, so it is not available through the proxy.

## Things to know

- **Read-only is still readable.** `docker inspect` includes each container's
  environment variables, and those often hold passwords. Keep the proxy's port
  bound to 127.0.0.1 and use the tunnel; do not publish it on the network.
- The proxy has no TLS and no login of its own. Its protection is that only
  someone who can already SSH to the host can reach it.
