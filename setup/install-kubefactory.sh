#!/bin/sh
# KubeFactory Clean slate: sets up a Docker host or a Kubernetes cluster on this
# Linux machine, from nothing, ready for KubeFactory. See docs/CLEAN_SLATE.md.
#
# Read it, then run it with sudo. It does not elevate itself.
#
#   sh install-kubefactory.sh --plan                    what it would do here; changes nothing, no sudo needed
#   sudo sh install-kubefactory.sh                      a Docker host: Docker Engine
#   sudo sh install-kubefactory.sh --target k3s         a k3s cluster on this machine
#   sudo sh install-kubefactory.sh --target kind        Docker Engine and a kind cluster named kubefactory
#   add --host-service to also install the KubeFactory host service (docs/HOST_SERVICE.md)
#
# Each step runs only if it is missing. The plan is shown first and you are asked
# before anything changes. What it may change:
#   Docker Engine     Docker's own installer (get.docker.com); you are added to the docker group
#   k3s               k3s's own installer (get.k3s.io), kubeconfig readable by root only
#   kubectl, kind     downloaded to /usr/local/bin and checked against their published checksums
#   a kind cluster    kind create cluster
#   a kubeconfig      ~/.kube/kubefactory-k3s.yaml or ~/.kube/kubefactory-kind.yaml, readable by you only
#   the host service  install-host.sh
#
# It never prints a credential and never removes anything.
set -eu
repo="DasCondor/kubefactory"
target=docker host_service=false cluster=kubefactory version=latest plan=false yes=false
kind_version=v0.27.0

while [ $# -gt 0 ]; do
  case "$1" in
    --target) target="$2"; shift ;;
    --host-service) host_service=true ;;
    --cluster-name) cluster="$2"; shift ;;
    --version) version="$2"; shift ;;
    --plan) plan=true ;;
    --yes) yes=true ;;
    *) echo "unknown option $1 (see the top of this script)" >&2; exit 2 ;;
  esac
  shift
done
case "$target" in docker|k3s|kind) ;; *) echo "--target is docker, k3s or kind" >&2; exit 2 ;; esac
echo "$cluster" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$' || { echo "--cluster-name: lowercase letters, digits and dashes" >&2; exit 2; }
if [ "$version" = latest ]; then base="https://github.com/$repo/releases/latest/download"; else base="https://github.com/$repo/releases/download/$version"; fi

if ! $plan && [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo. It does not elevate itself." >&2
  echo "To see what it would do first: sh install-kubefactory.sh --plan --target $target" >&2
  exit 1
fi
case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) echo "unsupported machine $(uname -m)" >&2; exit 1 ;; esac
$plan || command -v curl >/dev/null 2>&1 || { echo "curl is needed (apt install curl, dnf install curl...)" >&2; exit 1; }

# the person who ran sudo gets the kubeconfig
user="${SUDO_USER:-$(id -un)}"
home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"; [ -n "$home" ] || home="$HOME"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

say() { printf '%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
wait_until() {  # what seconds command...
  what="$1" secs="$2"; shift 2
  printf '  waiting for %s ' "$what"
  end=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$end" ]; do
    if "$@" >/dev/null 2>&1; then say " ready"; return 0; fi
    printf '.'; sleep 5
  done
  say " not yet (gave up after ${secs}s)"; return 1
}
# a companion script: beside this one, else from the release, checked against its SHA256SUMS
companion() {
  here="$(dirname "$0")/$1"
  if [ -f "$here" ]; then printf '%s' "$here"; return; fi
  curl -fsSL -o "$tmp/$1" "$base/$1"
  curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"
  (cd "$tmp" && grep " $1\$" SHA256SUMS | sha256sum -c - >/dev/null) || { echo "checksum mismatch for $1; nothing was run" >&2; exit 1; }
  printf '%s' "$tmp/$1"
}
save_kubeconfig() {  # file-with-config destination
  mkdir -p "$home/.kube"
  install -m 600 -o "$user" "$1" "$2"
  chown "$user" "$home/.kube"
  say "  Saved $2 (readable by $user only). In KubeFactory: Switch cluster > Add or manage kubeconfigs."
}

# ----- what is on this machine (read only)
engine_up() { have docker && docker version --format '{{.Server.Version}}' >/dev/null 2>&1; }
in_docker_group() { id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx docker; }
k3s_ready() { have k3s && k3s kubectl get --raw /readyz 2>/dev/null | grep -qx ok; }
kind_cluster() { have kind && kind get clusters 2>/dev/null | grep -qx "$cluster"; }
host_installed() { [ -f /etc/systemd/system/kubefactory-host.service ]; }
k3s_conf="$home/.kube/kubefactory-k3s.yaml"
kind_conf="$home/.kube/kubefactory-kind.yaml"

# ----- the steps
do_docker() {
  curl -fsSL -o "$tmp/get-docker.sh" https://get.docker.com
  sh "$tmp/get-docker.sh"
  if have systemctl; then systemctl enable --now docker; fi
}
do_docker_group() {
  getent group docker >/dev/null || groupadd docker
  usermod -aG docker "$user"
  say "  Added $user. Sign out and back in once so Docker works without sudo."
}
do_engine() { wait_until "the Docker engine" 120 engine_up; }
do_k3s() {
  curl -fsSL -o "$tmp/get-k3s.sh" https://get.k3s.io
  INSTALL_K3S_EXEC="--write-kubeconfig-mode 600" sh "$tmp/get-k3s.sh"
  wait_until "the k3s cluster" 300 k3s_ready
}
do_k3s_conf() {
  sed 's/: default$/: kubefactory-k3s/' /etc/rancher/k3s/k3s.yaml > "$tmp/k3s.yaml"
  save_kubeconfig "$tmp/k3s.yaml" "$k3s_conf"
}
do_kubectl() {
  v="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSL -o "$tmp/kubectl" "https://dl.k8s.io/release/$v/bin/linux/$arch/kubectl"
  curl -fsSL -o "$tmp/kubectl.sha256" "https://dl.k8s.io/release/$v/bin/linux/$arch/kubectl.sha256"
  echo "$(cat "$tmp/kubectl.sha256")  $tmp/kubectl" | sha256sum -c - >/dev/null || { echo "kubectl checksum mismatch" >&2; return 1; }
  install -m 755 "$tmp/kubectl" /usr/local/bin/kubectl
}
do_kind() {
  curl -fsSL -o "$tmp/kind-linux-$arch" "https://kind.sigs.k8s.io/dl/$kind_version/kind-linux-$arch"
  curl -fsSL -o "$tmp/kind.sha256sum" "https://kind.sigs.k8s.io/dl/$kind_version/kind-linux-$arch.sha256sum"
  (cd "$tmp" && sha256sum -c kind.sha256sum >/dev/null) || { echo "kind checksum mismatch" >&2; return 1; }
  install -m 755 "$tmp/kind-linux-$arch" /usr/local/bin/kind
}
do_kind_cluster() { kind create cluster --name "$cluster" --wait 180s; }
do_kind_conf() {
  kind get kubeconfig --name "$cluster" > "$tmp/kind.yaml"
  save_kubeconfig "$tmp/kind.yaml" "$kind_conf"
}
do_host() {
  installer="$(companion install-host.sh)"
  case "$target" in
    docker) sh "$installer" --version "$version" --source docker ;;
    k3s) sh "$installer" --version "$version" --source k3s ;;
    kind)
      # the host service runs on the host network, so 127.0.0.1 reaches kind's API server
      kind get kubeconfig --name "$cluster" > "$tmp/kind-host.yaml"
      sh "$installer" --version "$version" --source kube --kubeconfig "$tmp/kind-host.yaml"
      rm -f "$tmp/kind-host.yaml" ;;
  esac
}

# name|done-check|step|note
plan_lines=""
add() { plan_lines="$plan_lines$1|$2|$3|$4
"; }
need_docker=false
if [ "$target" != k3s ] || $host_service; then need_docker=true; fi
if $need_docker; then
  add "Docker Engine" "have docker" do_docker "Docker's installer from get.docker.com"
  add "$user in the docker group" in_docker_group do_docker_group "so Docker works without sudo"
  add "Docker engine answering" engine_up do_engine ""
fi
case "$target" in
  k3s)
    add "k3s" k3s_ready do_k3s "k3s's installer from get.k3s.io"
    add "kubeconfig for $user" "test -f $k3s_conf" do_k3s_conf "$k3s_conf" ;;
  kind)
    add "kubectl" "have kubectl" do_kubectl "from dl.k8s.io, checksum checked"
    add "kind $kind_version" "have kind" do_kind "from kind.sigs.k8s.io, checksum checked"
    add "kind cluster $cluster" kind_cluster do_kind_cluster ""
    add "kubeconfig for $user" "test -f $kind_conf" do_kind_conf "$kind_conf" ;;
esac
if $host_service; then add "KubeFactory host service" host_installed do_host "install-host.sh"; fi

say ""
say "KubeFactory Clean slate  ·  target: $target$($host_service && echo ' + host service' || true)"
todo=0
todo_steps=""
IFS_old="$IFS"
IFS='
'
for line in $plan_lines; do
  name="$(echo "$line" | cut -d'|' -f1)"; check="$(echo "$line" | cut -d'|' -f2)"
  step="$(echo "$line" | cut -d'|' -f3)"; note="$(echo "$line" | cut -d'|' -f4)"
  IFS="$IFS_old"
  if eval "$check" >/dev/null 2>&1; then
    say "  [done]  $name"
  else
    say "  [todo]  $name${note:+   ($note)}"
    todo=$((todo + 1))
    todo_steps="$todo_steps$name|$step
"
  fi
  IFS='
'
done
IFS="$IFS_old"

if [ "$todo" -eq 0 ]; then
  say "Everything is already in place."
elif $plan; then
  say "Plan only: nothing was changed. Run it without --plan, with sudo, to do the steps marked todo."
  exit 0
else
  if ! $yes; then
    printf 'Do the %d step(s) marked todo? (y/N) ' "$todo"
    read -r answer || answer=""
    case "$answer" in y|Y|yes|YES) ;; *) say "Nothing was changed."; exit 0 ;; esac
  fi
  IFS='
'
  for line in $todo_steps; do
    IFS="$IFS_old"
    name="${line%%|*}"; step="${line#*|}"
    say ""; say "==> $name"
    # a subshell with errexit on: any failing command inside the step stops it
    set +e
    ( set -e; "$step" )
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      say "Stopped at: $name. Steps before it are kept. Fix the cause and run this script again; it carries on from here." >&2
      exit 1
    fi
    IFS='
'
  done
  IFS="$IFS_old"
fi
say ""
say "Next, in KubeFactory: Esc > Switch cluster > Discover local connections."
case "$target" in
  docker) say "  Pick the Docker engine." ;;
  k3s) say "  Add $k3s_conf with Add or manage kubeconfigs, then pick kubefactory-k3s." ;;
  kind) say "  Add $kind_conf with Add or manage kubeconfigs, then pick kind-$cluster." ;;
esac
