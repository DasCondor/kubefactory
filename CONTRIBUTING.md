# Contributing to KubeFactory

<sub>[KubeFactory](README.md) · [All docs](README.md#-docs-by-topic) · [2.0.0-beta.2 pre-release](https://github.com/DasCondor/kubefactory/releases/tag/v2.0.0-beta.2) · [Known limitations](docs/KNOWN_LIMITATIONS.md)</sub>

Thanks for wanting to help. KubeFactory is a Godot 4.3 game (GDScript) with a
Go companion, `kf-agent`. You do not need a cluster for most changes: the
built-in simulation (`--demo`) does not connect to real infrastructure.

## Getting set up

Install Git and Godot 4.3. Go 1.25 or newer is needed to build or test the
companion; its version requirement is in `agent/go.mod`. Clone the repository,
or fork it on GitHub and clone your fork if you cannot push to this repository:

```sh
git clone https://github.com/DasCondor/kubefactory.git
cd kubefactory
git switch -c my-change
```

On Windows, the setup script can download Godot and install missing tools via
winget. Use `-CheckOnly` first to see what it would check without installing:

```powershell
powershell -ExecutionPolicy Bypass -File tools\setup.ps1 -CheckOnly
powershell -ExecutionPolicy Bypass -File tools\setup.ps1
.\play.bat --demo
```

Docker, kind and kubectl are not needed for the simulation. The setup script
also installs them if missing; install Godot separately if you do not want
those tools. On Linux or macOS, install Godot 4.3 for your platform and run this
from the repository root, replacing `godot` with the executable path if needed:

```sh
godot --path . -- --demo
```

The companion is needed for native Kubernetes connections, LiveView and
providers. On Windows, run `powershell -ExecutionPolicy Bypass -File tools\build-agent.ps1`;
add `-Fetch` if Go is missing and you want the script to download its pinned
private toolchain. On Linux or macOS, build it with
`(cd agent && go build -o bin/kf-agent .)`. Tokens and keys cannot be stored
on Linux or macOS; see [known limitations](docs/KNOWN_LIMITATIONS.md).

## Where things are

[Architecture](docs/ARCHITECTURE.md) maps the scripts and companion operations. The
short version:

| You want to change | Look in |
|---|---|
| what a cluster looks like in the world | `scripts/world.gd`, `scripts/machine.gd`, `scripts/platform.gd`, `scripts/pipes.gd` |
| panels, menus, the HUD | `scripts/hud.gd` |
| keys, tools, the game loop | `scripts/main.gd` |
| where data comes from | `scripts/backend_*.gd` (native, kubectl, docker, demo); `scripts/cluster.gd` runs them |
| the Krew's rules | `scripts/krew.gd`; Foreman in `scripts/foreman.gd` |
| graphics presets | `scripts/gfx.gd`, `scripts/scenery.gd` |
| Kubernetes access, secrets, LiveView | `agent/*.go` |

Every backend returns the same normalized state (nodes, pods, workloads,
services) and answers the same actions, so the world, the HUD and the Krew do
not know where data came from. A new source is a new `backend_*.gd`.

## Tests

Run the relevant checks before opening a pull request. The release packaging
scripts run the normalization test; the release workflow also tests the Go
companion. On Windows, from the repository root:

```powershell
engine\Godot_v4.3-stable_win64_console.exe --headless --path . -s tests/normalize_test.gd
powershell -ExecutionPolicy Bypass -File tools\build-agent.ps1 -Test
```

On Linux or macOS, with Godot and Go on `PATH`:

```sh
godot --headless --path . -s tests/normalize_test.gd
(cd agent && go vet ./... && go test ./...)
```

Go tests that require Windows protected storage cannot exercise that path on
Linux or macOS; run the Windows tests too when changing credential handling.

In-game tests drive the real game on the simulation and are worth running
when you touch what they cover. For example, on Windows:

```powershell
engine\Godot_v4.3-stable_win64_console.exe --path . -s tests/live/krew_ui_test.gd -- --demo
engine\Godot_v4.3-stable_win64_console.exe --path . --rendering-method gl_compatibility -s tests/live/krew_ui_test.gd -- --demo
```

The second line is the renderer the browser build uses; check both when you
change anything visible. These tests need a graphical desktop. More test
commands are in the [README](README.md#-run-from-source).

Some tests in `tests/live/` and `tools\live-test.ps1` use real infrastructure.
Read the specific test and its prerequisites before running it; use disposable
resources, never infrastructure you care about.

For packaging, Windows uses `tools\package.ps1`; Linux and macOS use
`tools/package.sh linux` and `tools/package.sh macos`. These need Godot 4.3
export templates and Go; the macOS universal package must be built on a Mac.
Packaging writes to `dist/` and replaces its staging output.

## Ground rules

These are what keep KubeFactory safe to point at a real cluster, so pull
requests are checked against them:

- **Nothing changes infrastructure without the operator's approval.** Every
  action goes through `hud.guarded_act` (tool tiers, read-only mode, typed
  confirmation). Rules and AI may propose; only a button press acts.
- **No secrets in the game.** Tokens and keys go to the companion, are sealed
  there and are never returned, logged, shown or written to the repository.
- **Simulated data says so.** Anything invented is marked SIMULATED.
- **Say what was tested.** In pull requests and in `docs/FEATURE_PARITY.md`,
  use "verified live", "verified in simulation", "not tested" or
  "unsupported", and mean it.
- **No personal data on screen or in screenshots.** Demo users appear as
  DasCondor; check screenshots before committing them.

## Pull requests

1. Keep each branch focused on one change. Add or update tests for changed
   behaviour and run the relevant checks above.
2. Update [the changelog](docs/CHANGELOG.md) for user-visible changes and
   [known limitations](docs/KNOWN_LIMITATIONS.md) when a feature is partial.
   Update [feature parity](docs/FEATURE_PARITY.md) if verification changes.
3. Push your branch to your fork or this repository and open a pull request
   against `main`. Follow the pull request template: explain what and why,
   report the exact tests and platforms used, and clearly say what was not
   tested. Include simulation screenshots for visible changes.
4. Respond to review feedback and push follow-up commits to the same branch.
   Do not publish release tags as part of a contribution.

New dependencies (Go modules and assets) need a licence compatible with MIT;
list them in [third-party notices](docs/THIRDPARTY.md).

By contributing you agree that your contribution is licensed under the
project's MIT licence.

## Reporting bugs and security problems

For bugs and ideas, use the repository's issue templates; include the version,
platform, reproduction steps and relevant redacted logs for bugs. Report
security problems privately as described in [security](docs/SECURITY.md), not
in a public issue.
