# 2.0 go-live checklist

What stands between the published beta and a stable 2.0.0. Status words as in
[FEATURE_PARITY.md](FEATURE_PARITY.md): **verified live**, **verified in
simulation**, **not tested**, **unsupported**.

**Where things stand (2026-11-14):** `2.0.0-beta.1` is published as a
pre-release with Windows, Linux and macOS packages, checksums and
build-provenance attestations. `main` has fixes the beta does not have (see
the Unreleased section of [CHANGELOG.md](CHANGELOG.md)), among them a crash
when switching away from a KubeFactory server.

Each item says what "done" looks like and what it needs. "Here" means it can
be done on the development machine with throw-away infrastructure; anything
else needs hardware, an account or a person.

## 1. Release blockers

Do not tag 2.0.0 until each of these is done or explicitly moved to section 2.

| # | Item | Done when | Needs |
|---|---|---|---|
| 1.1 | **Ship the fixes on `main`** | A `v2.0.0-beta.2` tag is built and published (or the fixes go straight into 2.0.0). The server-switch crash fix is the important one | Here |
| 1.2 | **Clean Windows install** | The Windows zip, installed with `install.ps1` on a Windows machine that has never had kubectl, Go or Godot, opens the demo, connects to a kubeconfig and to Docker | A clean Windows VM or PC |
| 1.3 | **One real AI provider behind Foreman** | Foreman answers a question about a real or simulated cluster through at least one real provider (Ollama is the cheapest), a proposal is checked and refused or approved, and the key is absent from logs and disk. Today every provider is tested against a mock only | Here with Ollama; an API key for OpenAI or Claude |
| 1.4 | **Komodo in the game against a real Core** | The game connects to a real Komodo Core 2.3+, shows its servers and containers, and the record shows `ListAllContainers` answered (or the fallback used). The supporter who asked for Komodo uses it | A Komodo Core with a read-only key |
| 1.5 | **Credentials on Linux and macOS: decide** | Either the companion seals keys with the system keyring (Secret Service on Linux, Keychain on macOS), or the release notes say plainly that Grafana, Tautulli, AI provider and Komodo keys work on Windows only. Today they are refused on Linux and macOS, never stored in the clear | A decision; implementing it is a code change |
| 1.6 | **Version and release** | `scripts/main.gd` and `agent/main.go` say `2.0.0`; CHANGELOG has a dated 2.0.0 section; KNOWN_LIMITATIONS is current; tag `v2.0.0` (no hyphen, so the workflow publishes it as a full release); `gh attestation verify` passes on every package | Here |
| 1.7 | **Old pull request refs** | GitHub Support has removed the cached `refs/pull/1-4/head` that still reach the stripped images (ticket filed, awaiting reply) | GitHub Support |

## 2. Verification that can ship as a known limitation

Worth doing before 2.0.0; if not done, each stays listed in
[KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) and the release still goes out.

| Item | Status now | To verify | Needs |
|---|---|---|---|
| Cloud Kubernetes (EKS, AKS, GKE) and a sign-in helper signing in | not tested | Connect through the wizard, approve the helper, list and act on a pod | A cloud account |
| Metrics API figures (Gauge, Metrics view) | only "no metrics API" seen live | Install metrics-server on the kind test cluster, read real CPU and memory | Here |
| Storage inspection on a distroless image | not tested | Open the door on a distroless pod; expect a plain "unsupported" | Here |
| Grafana through LiveView on Docker and through a port-forward | not tested | Put a Grafana page on a machine both ways | Here |
| Scrappy's approved removals on live infrastructure | verified in simulation | Approve removing a finished pod and an unused image on throw-away infrastructure | Here |
| Physical controller | simulated input only | Play with a real pad; tune dead zone and stick speeds | A controller |
| Server mode over `wss://` from another machine | `ws://127.0.0.1` only | A TLS certificate, a second machine, a viewer and an operator | A second machine |
| Linux desktop | headless in a container | Play on a Linux desktop with a GPU against a real cluster | A Linux PC |
| macOS | Apple Silicon startup smoke test | Play a session on Apple Silicon; start on an Intel Mac | Macs |
| Browser High preset and touch controls | local web build; phone sizes simulated | The deployed site on a real iPhone and Android phone: frame rate, rotation, notch margins | Phones |
| Tautulli stream counts | stand-in server | Tautulli with a Plex server playing something | A Plex server |
| Large cluster | not tested | Hundreds of nodes, thousands of pods: frame rate and memory | A large cluster (or a simulated one) |

Reported by users, not verified here: k3s works; the Komodo read requests
match a real Core 2.3.4 (old request name).

## 3. Out of reach for 2.0

Stated in the release notes, not worked on for 2.0.0:

- **Code signing.** No Windows publisher certificate and no Apple developer
  identity: SmartScreen warns, and macOS needs the quarantine flag cleared.
  Packages are checked by SHA-256 and signed build-provenance attestations
  instead.
- **Unsupported 2.0 handoff items** (see [FEATURE_PARITY.md](FEATURE_PARITY.md)):
  the autonomy and policy engine, self-healing and scheduling, an in-game
  terminal (exec), ephemeral debug containers, Helm and CRD browsing, a
  bundled browser engine, a native Docker Engine client, Krew display surfaces
  and animation, Foreman streaming and multi-step plans.

## 4. Housekeeping

- Write the 2.0.0 release notes: the Unreleased and beta.1 sections of the
  changelog, the verification summary above, and section 3.
- Remove leftover local worktrees from other tools that still hold the
  history from before the images were stripped.
