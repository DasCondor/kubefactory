#!/usr/bin/env bash
# Builds the Linux or macOS release, the counterpart of tools/package.ps1:
#
#   tools/package.sh linux   dist/KubeFactory-<version>-linux-x86_64.tar.gz
#   tools/package.sh macos   dist/KubeFactory-<version>-macos.zip
#
# plus a .sha256 beside each. Needs Godot 4.3 (GODOT=path, default: godot on
# PATH), its export templates, and Go for the companion. On macOS the
# companion is built for both Intel and Apple Silicon and joined with lipo,
# so the macOS package is built on a Mac (the release workflow uses one).
#
# The layout matches the Windows zip: the game, the companion, the config
# files, docs, the model library and the bundled app setups side by side.
# The game is ad-hoc signed on macOS; nothing here is signed with a
# developer identity or notarized, and nothing should claim it is.
set -euo pipefail

platform="${1:-}"
case "$platform" in linux|macos) ;; *) echo "usage: tools/package.sh linux|macos" >&2; exit 2;; esac
root="$(cd "$(dirname "$0")/.." && pwd)"
godot="${GODOT:-godot}"
version="$(tr -d '\r' < "$root/scripts/main.gd" | sed -n 's/^const VERSION = "\(.*\)"/\1/p')"
if [ "$platform" = linux ]; then name="KubeFactory-$version-linux-x86_64"; else name="KubeFactory-$version-macos"; fi
stage="$root/dist/$name"
rm -rf "$stage" "$root/dist/$name".*
mkdir -p "$stage"

echo "Running tests..."
result="$("$godot" --headless --path "$root" -s tests/normalize_test.gd 2>/dev/null | tail -1 || true)"
echo "$result"
case "$result" in *"ALL CHECKS PASSED"*) ;; *) echo "Tests failed; not packaging." >&2; exit 1;; esac

echo "Building the native companion..."
cd "$root/agent"
export CGO_ENABLED=0
if [ "$platform" = linux ]; then
  GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o "$stage/kf-agent" .
else
  GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "-s -w" -o "$stage/kf-agent-arm64" .
  GOOS=darwin GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o "$stage/kf-agent-amd64" .
  lipo -create -output "$stage/kf-agent" "$stage/kf-agent-arm64" "$stage/kf-agent-amd64"
  rm "$stage/kf-agent-arm64" "$stage/kf-agent-amd64"
fi
chmod +x "$stage/kf-agent"
cd "$root"

echo "Exporting..."
if [ "$platform" = linux ]; then
  "$godot" --headless --path "$root" --export-release "Linux" "$stage/KubeFactory.x86_64" >/dev/null 2>&1 || true
  test -s "$stage/KubeFactory.x86_64" || { echo "Export failed." >&2; exit 1; }
  chmod +x "$stage/KubeFactory.x86_64"
else
  "$godot" --headless --path "$root" --export-release "macOS" "$root/dist/app.zip" >/dev/null 2>&1 || true
  test -s "$root/dist/app.zip" || { echo "Export failed." >&2; exit 1; }
  (cd "$stage" && unzip -q "$root/dist/app.zip") && rm "$root/dist/app.zip"
fi

for f in README.md LICENSE docs/ADMIN.md docs/THIRDPARTY.md docs/SECURITY.md docs/KNOWN_LIMITATIONS.md docs/DOCKER_HOSTS.md docs/PLUGINS.md docs/SERVER.md \
         config/catalogs.json config/portainer.json config/log-providers.json config/policy.json config/bob.json; do
  [ -f "$root/$f" ] && cp "$root/$f" "$stage/"
done
cp -R "$root/tools/dev" "$stage/dev"
for d in apps deploy assets examples; do cp -R "$root/$d" "$stage/$d"; done
find "$stage" -name .gdignore -delete
echo "$version" > "$stage/VERSION"

cd "$root/dist"
if [ "$platform" = linux ]; then
  out="$name.tar.gz"
  tar -czf "$out" "$name"
else
  out="$name.zip"
  # ditto keeps the app bundle's signature and the executable bits intact
  if command -v ditto >/dev/null; then ditto -c -k --keepParent "$name" "$out"; else zip -qry "$out" "$name"; fi
fi
if command -v sha256sum >/dev/null; then sha256sum "$out" > "$out.sha256"; else shasum -a 256 "$out" > "$out.sha256"; fi
echo "Built dist/$out ($(du -h "$out" | cut -f1))"
cat "$out.sha256"
