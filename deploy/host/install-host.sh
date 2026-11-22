#!/bin/sh
# Installs the KubeFactory host service (kf-host) on this Linux machine as a
# systemd unit: the high-availability deployment, see docs/HOST_SERVICE.md.
#
# Run it with sudo. It does not elevate itself.
#
#   sudo sh install-host.sh                                  demo server, access point on 127.0.0.1:7666
#   sudo sh install-host.sh --source docker                  this machine's Docker engine
#   sudo sh install-host.sh --source kube --kubeconfig /root/kf-viewer.yaml [--context prod]
#   sudo sh install-host.sh --source k3s                     the k3s cluster on this node (its own kubeconfig)
#   sudo sh install-host.sh --listen 0.0.0.0:7666 --tls-cert /etc/kf/cert.pem --tls-key /etc/kf/key.pem
#   sudo sh install-host.sh --binary ./kf-host --image kubefactory-server:dev --no-pull
#   sudo sh install-host.sh --uninstall [--remove-container]
#
# What it changes, and nothing else:
#   /usr/local/bin/kf-host                          the service program
#   /etc/kubefactory/host.json                      its settings (kept if present, unless --force)
#   /etc/systemd/system/kubefactory-host.service    enabled and started
#   Docker: the container, volume and image named in host.json, created by the service
#
# It never prints or stores a token.
set -eu
repo="DasCondor/kubefactory"
exe=/usr/local/bin/kf-host
dir=/etc/kubefactory
config="$dir/host.json"
source=demo kubeconfig="" context="" listen="127.0.0.1:7666" cert="" key="" image="" pull=true
readonly_=false binary="" version=latest force=false uninstall=false remove=false

while [ $# -gt 0 ]; do
  case "$1" in
    --source) source="$2"; shift ;;
    --kubeconfig) kubeconfig="$2"; shift ;;
    --context) context="$2"; shift ;;
    --listen) listen="$2"; shift ;;
    --tls-cert) cert="$2"; shift ;;
    --tls-key) key="$2"; shift ;;
    --image) image="$2"; shift ;;
    --no-pull) pull=false ;;
    --read-only) readonly_=true ;;
    --binary) binary="$2"; shift ;;
    --version) version="$2"; shift ;;
    --force) force=true ;;
    --uninstall) uninstall=true ;;
    --remove-container) remove=true ;;
    *) echo "unknown option $1 (see the top of this script)" >&2; exit 2 ;;
  esac
  shift
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo. It does not elevate itself." >&2; exit 1
fi

if $uninstall; then
  [ -x "$exe" ] || { echo "kf-host is not installed here."; exit 0; }
  if $remove; then "$exe" uninstall --config "$config" --remove-container; else "$exe" uninstall --config "$config"; fi
  rm -f "$exe"
  echo "Removed the program. Settings stay in $dir and status in /var/lib/kubefactory-host; delete them to remove everything."
  exit 0
fi

command -v docker >/dev/null 2>&1 || { echo "Docker was not found. Install Docker Engine first (or use KubeFactory's Clean slate setup)." >&2; exit 1; }
engine="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
[ -n "$engine" ] || { echo "Docker is installed but its engine is not answering (systemctl start docker)." >&2; exit 1; }
echo "Docker engine $engine"

mkdir -p "$dir"
if [ -n "$binary" ]; then
  install -m 755 "$binary" "$exe"
else
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "no kf-host build for $(uname -m)" >&2; exit 1 ;;
  esac
  if [ "$version" = latest ]; then base="https://github.com/$repo/releases/latest/download"; else base="https://github.com/$repo/releases/download/$version"; fi
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/kf-host-linux-$arch" "$base/kf-host-linux-$arch"
  curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"
  (cd "$tmp" && grep " kf-host-linux-$arch\$" SHA256SUMS | sha256sum -c -) || { echo "checksum mismatch; nothing was installed" >&2; exit 1; }
  install -m 755 "$tmp/kf-host-linux-$arch" "$exe"
fi
echo "Installed $exe ($("$exe" version))"

json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

if [ -f "$config" ] && ! $force; then
  echo "Keeping the existing settings in $config (use --force to replace them)."
else
  if [ -z "$image" ]; then
    if [ "$version" = latest ]; then image="ghcr.io/dascondor/kubefactory-server:latest"; else image="ghcr.io/dascondor/kubefactory-server:${version#v}"; fi
  fi
  src='["--demo"]' mounts='[]' extra=''
  case "$source" in
    demo) ;;
    docker)
      echo "A Docker source gives the server container this machine's Docker socket: it can do anything Docker can. Players still act only through their token's role."
      gid="$(stat -c %g /var/run/docker.sock)"
      src='["--docker"]'
      mounts='[{"host": "/var/run/docker.sock", "container": "/var/run/docker.sock", "read_only": false}]'
      extra=", \"group_add\": [\"$gid\"]"
      ;;
    kube|k3s)
      if [ "$source" = k3s ]; then kubeconfig=/etc/rancher/k3s/k3s.yaml; fi
      [ -n "$kubeconfig" ] && [ -f "$kubeconfig" ] || { echo "--source kube needs --kubeconfig <file>" >&2; exit 1; }
      mkdir -p "$dir/kube"
      # a copy only the container's user (uid 10001) and root can read
      install -m 600 -o 10001 "$kubeconfig" "$dir/kube/config"
      chmod 700 "$dir/kube"; chown 10001 "$dir/kube"
      mounts="[{\"host\": \"$dir/kube\", \"container\": \"/kube\", \"read_only\": true}]"
      if [ -n "$context" ]; then src="[\"--kubeconfig=/kube/config\", $(json_str "--context=$context")]"; else src='["--kubeconfig=/kube/config"]'; fi
      # the host network lets the server reach an API server on 127.0.0.1 (k3s, kind)
      extra=', "host_network": true'
      echo "Copied the kubeconfig to $dir/kube/config (readable by the container's user only). Exec auth helpers are not available inside the container."
      ;;
    *) echo "--source is demo, docker, kube or k3s" >&2; exit 2 ;;
  esac
  cat > "$config" <<EOF
{
  "container": "kubefactory-server",
  "image": $(json_str "$image"),
  "pull": $pull,
  "source": $src,
  "read_only": $readonly_,
  "volume": "kubefactory-server-data",
  "mounts": $mounts,
  "internal_port": 17666,
  "listen": $(json_str "$listen"),
  "tls_cert": $(json_str "$cert"),
  "tls_key": $(json_str "$key"),
  "interval_seconds": 30$extra
}
EOF
  chmod 644 "$config"
  echo "Wrote $config"
fi

case "$listen" in 127.0.0.1:*) ;; *) [ -n "$cert" ] || echo "The access point listens on $listen without TLS: tokens would cross the network unencrypted. Prefer --tls-cert/--tls-key, an SSH tunnel or a TLS reverse proxy." ;; esac
"$exe" install --config "$config"
echo
echo "KubeFactory host service is running. It checks every 30 seconds that the server container is up."
echo "  status:   kf-host status        log: journalctl -u kubefactory-host"
echo "  connect:  in the game, Esc > Switch cluster > KubeFactory server..., address ws://$listen"
echo
echo "The server's first tokens are written once, inside its data volume. When the container is up, read them, hand each to one person, then delete the file:"
echo "  docker exec kubefactory-server cat /data/server-new-tokens.txt"
echo "  docker exec kubefactory-server rm /data/server-new-tokens.txt"
