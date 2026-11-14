# Contributing to KubeFactory

Thanks for wanting to help. KubeFactory is a Godot 4.3 game (GDScript) with a
small Go companion, `kf-agent`, that talks to Kubernetes and holds secrets. You
do not need a cluster to work on it: the built-in simulation (`--demo`) runs
everything, and every test below runs without real infrastructure unless it
says otherwise.

## Getting set up

    git clone https://github.com/DasCondor/kubefactory
    cd kubefactory
    powershell -ExecutionPolicy Bypass -File tools\setup.ps1     # fetches Godot 4.3 into engine\ and checks the rest
    play.bat --demo                                               # the simulated world

The companion is only needed for real clusters, LiveView and the AI
providers. Build it with `tools\build-agent.ps1` (`-Fetch` downloads a private
Go toolchain into `.toolchain\` if you have none).

Today the scripts are PowerShell and the builds are Windows and the browser.
Linux and macOS builds are on the roadmap; GDScript and Go changes are not
platform-specific, so you can work on most things anywhere Godot 4.3 runs
(`godot --path . -- --demo`).

## Where things are

`docs/ARCHITECTURE.md` maps every script and the companion's operations. The
short version:

| You want to change | Look in |
|---|---|
| what a cluster looks like in the world | `scripts/world.gd`, `scripts/machine.gd`, `scripts/platform.gd` |
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

Run these before opening a pull request. They are what CI and the release
script run.

    engine\Godot_v4.3-stable_win64_console.exe --headless --path . -s tests/normalize_test.gd
    powershell -ExecutionPolicy Bypass -File tools\build-agent.ps1 -Test

In-game tests drive the real game on the simulation and are worth running
when you touch what they cover (each prints PASSED or the checks that failed):

    engine\Godot_v4.3-stable_win64_console.exe --path . -s tests/live/krew_ui_test.gd -- --demo
    engine\Godot_v4.3-stable_win64_console.exe --path . --rendering-method gl_compatibility -s tests/live/krew_ui_test.gd -- --demo

The second line is the renderer the browser build uses; check both when you
change anything visible. More in the README under "Run from source".

Tests against real infrastructure (`tests/live/*_live_test.gd`,
`tools\live-test.ps1`) create their own throw-away containers or clusters and
remove them afterwards. Never point a test at infrastructure you care about.

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

- One topic per pull request, with tests for new behaviour.
- Update `docs/CHANGELOG.md`, and `docs/KNOWN_LIMITATIONS.md` when something is
  partial.
- Screenshots for visible changes, taken from the simulation.
- New dependencies (Go modules, assets) need a licence that fits MIT; list them
  in `docs/THIRDPARTY.md`.

By contributing you agree that your contribution is licensed under the
project's MIT licence.

## Reporting bugs and security problems

Bugs and ideas: open an issue (there are templates). Security problems: follow
`docs/SECURITY.md` and do not open a public issue.
