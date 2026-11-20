# Single-node Docker media lab

Run Plex, Seerr (the successor to Overseerr), Tautulli, Prometheus and Grafana on one Docker engine. Use the stack in KubeFactory’s Docker view to inspect the containers, ports and mounts. Add playback reporting after signing in to Plex, and add a second media gathering node when ready. [Seerr migration guide](https://docs.seerr.dev/migration-guide/)

## 1. Start the single-node stack

Use Docker Engine or Docker Desktop in Linux container mode with Docker Compose v2 or newer. Run the commands from this directory. Docker pulls the images on first start.

1. Copy `.env.example` to `.env` with `Copy-Item .env.example .env` in PowerShell or `cp .env.example .env` in a shell. Open `.env` in an editor and set a long, unique `GRAFANA_PASSWORD`. The password initializes Grafana on the first run. Change it in Grafana for an existing installation.
2. Create a `library` folder next to `compose.yaml` and put a video you own or are licensed to use in it. The Plex container reads this folder as `/media`.
3. Use the Compose plan to review the stack, then start it.

   ```sh
   docker compose config --quiet
   docker compose up -d
   docker compose ps
   ```

| App | Address with the default settings | First task |
| --- | --- | --- |
| Plex | `http://127.0.0.1:32400/web` | Claim the server and create a library pointing at `/media`. |
| Seerr | `http://127.0.0.1:5055` | Sign in with Plex. Select this Plex server, using address `plex` and port `32400` for the internal connection, and sync the library. |
| Tautulli | `http://127.0.0.1:8181` | Complete the wizard, selecting the same Plex server at `http://plex:32400`. |
| Grafana | `http://127.0.0.1:3000` | Sign in as `admin` with the password from `.env`. Open **KubeFactory → Media server overview**. |
| Prometheus | `http://127.0.0.1:9090/targets` | Confirm the targets appear. Query `probe_success{job="media-http"}` to see the HTTP check for each app. |

If Plex cannot find the new server, sign in at [plex.tv/claim](https://www.plex.tv/claim), set the short-lived `PLEX_CLAIM` in `.env`, and rerun `docker compose up -d plex` promptly. Once claimed, remove the token from `.env` and recreate Plex with the same command. The configuration stays in the named volume. Leave Plex Remote Access off for this lab. Seerr can sync the library by itself. Sending approved requests to a download workflow requires separate Sonarr or Radarr setup. [Plex Docker setup](https://github.com/plexinc/pms-docker) · [Seerr Docker setup](https://docs.seerr.dev/getting-started/docker/)

## 2. Review the stack in KubeFactory

1. Open desktop KubeFactory. Select the local Docker context through **Esc → Switch cluster**. Find the Compose project `kf-media-demo`. One Docker host occupies the node. Each service container has its own machine.
2. Open **Cluster Codex → Network and shared data → Ports and readiness**. The default bindings appear under **Loopback bindings**. Image-declared ports without a host binding appear under **Internal ports**. Match host address, host port and protocol against `docker compose ps`.
3. Inspect Plex for its `/media` mount and Seerr for logs. For a reversible failure exercise, run `docker compose stop seerr`. Check the port row for **Container offline**, then watch the Grafana HTTP series drop and the Prometheus alert become pending. Restart it with `docker compose start seerr`. Run the commands against this project from this directory.
4. Verify Plex and Seerr from another computer only if you choose the LAN or VLAN setup below. Grafana’s HTTP checks run from the Blackbox container and show internal application reachability.

### Optional LAN or VLAN publishing

Set `MEDIA_BIND` to an existing IPv4 address on the Docker host to expose only Plex and Seerr on that interface. For a VLAN, use the host’s address on an already configured VLAN interface and set `MEDIA_VLAN_ID` to the actual VLAN ID. For example, use `192.168.30.12` and `30` if those values already exist on your network. Leave the VLAN ID blank for ordinary LAN publishing. Run `docker compose up -d plex seerr` to apply.

Open Plex and Seerr using that host IP from an allowed client. Compare the HTTP result against a client outside the intended network. Use your host and router firewall rules to control access. The KubeFactory label describes the intended VLAN, and Docker’s published address describes the configured binding. A working route depends on the host, switches, firewall and client. Physical VLAN tests belong on an appropriately configured Docker host. Grafana, Prometheus, and Tautulli stay on IPv4 loopback. [Docker port publishing](https://docs.docker.com/engine/network/port-publishing/) · [Docker macvlan constraints](https://docs.docker.com/engine/network/drivers/macvlan/)

## 3. Add Plex playback reporting

1. Enable the API in Tautulli under **Settings → Web Interface → API**. Save the key alone in a plain-text file named `.tautulli-api-key` next to `compose.yaml`. The exporter reads it as a Compose secret and sends it in a header. Use Tautulli 2.18 or newer for header authentication. The container’s exporter user needs read access to this file.
2. Add the playback overlay.

   ```sh
   docker compose -f compose.yaml -f compose.playback.yaml config --quiet
   docker compose -f compose.yaml -f compose.playback.yaml up -d
   ```

3. Play a video from the library. Check for a session in Tautulli, then query `tautulli_session_count` in Prometheus or watch **Active Plex streams** in Grafana. Allow up to two scrape intervals after the session appears in Tautulli.

Tautulli records the playback sessions and history. The JSON exporter reads two aggregate fields from Tautulli’s activity response, active streams and estimated bandwidth. It has no host port and shares a dedicated internal network with Prometheus and Tautulli. The Prometheus **Alerts** screen lists media endpoint failures after two minutes. [Tautulli API reference](https://github.com/Tautulli/Tautulli/wiki/Tautulli-API-Reference) · [Prometheus JSON exporter](https://github.com/prometheus-community/json_exporter) · [Grafana provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)

## 4. Add an optional gathering node

The gatherer sends files you place in its `outbox` to a separate `incoming` folder on the media host. Plex continues to serve the `library` folder. Copy approved files into the library after checking them.

1. On the media host, create `incoming` and set `SYNC_BIND` in `.env` to the media host’s LAN or VLAN IP that the gatherer can reach. Allow TCP 22000 (or `SYNC_PORT`) from the gatherer only. Start the receiver.

   ```sh
   docker compose -f compose.yaml -f compose.sync.yaml up -d
   ```

   If playback reporting is enabled, include both overlays in that command and those below that manage the media project.
2. On the gatherer host, copy this directory or just `compose.gather.yaml`. Create `outbox` next to it and run `docker compose -f compose.gather.yaml up -d`. On Linux, make the two bind folders writable by the local `SYNC_UID` and `SYNC_GID` on their respective hosts. They default to 1000.
3. On the two hosts, open Syncthing at `http://127.0.0.1:18384` (receiver) and `http://127.0.0.1:18385` (gatherer). Set admin credentials and turn off global discovery, relaying, and NAT traversal in both GUIs. Remove the default folder if present. Copy each device ID from **Actions → Show ID**, then add each host as a remote device on the other. Set the receiver’s address on the gatherer to `tcp://<media-host-ip>:22000` (replace 22000 if you changed `SYNC_PORT`).
4. On the gatherer, add folder ID `media-inbox`, path `/var/syncthing/outbox`, and **Send Only**. Share it with the receiver. Accept the share on the receiver using path `/var/syncthing/incoming` and **Receive Only**. Copy in a small test file and check that it appears on the media host before trying a video. Leave the receiver’s LAN port and both admin GUIs off the public internet.
5. To test both containers on one Docker host, keep the default loopback bind. After starting the gatherer, run `docker network connect kf-media-demo-sync "$(docker compose -f compose.gather.yaml ps -q gather)"`. Use `tcp://media-sync:22000` as the receiver address in the gatherer GUI. Repeat the network connect if you recreate the gather container.

Review the receiver’s listening port in the media host’s KubeFactory view. To inspect a separate gatherer, switch to its Docker context. Syncthing sends deletions within the synchronized folder as well as additions, so copy confirmed files from `incoming` to `library` before clearing the outbox. [Syncthing Docker guide](https://github.com/syncthing/syncthing/blob/main/README-Docker.md) · [Syncthing folder types](https://docs.syncthing.net/users/foldertypes.html)

## Stop the lab

Run `docker compose down` with the same `-f` options used for startup. Stop the gatherer with `docker compose -f compose.gather.yaml down`. These commands keep the Docker volumes and your local files. `docker compose logs --tail 50 <service>` shows recent logs when an app fails to start.
