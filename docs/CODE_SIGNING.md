# Code signing

<sub>[KubeFactory](../README.md) · [All docs](../README.md#-docs-by-topic) · [2.0.0-beta.1 pre-release](https://github.com/DasCondor/kubefactory/releases/tag/v2.0.0-beta.1) · [Known limitations](KNOWN_LIMITATIONS.md)</sub>

## Where things stand

| Platform | Signed by | Status |
|---|---|---|
| Windows (`KubeFactory.exe`, `KubeFactory.console.exe`, `kf-agent.exe`) | SignPath Foundation, through [SignPath](https://signpath.org) | **Wired up, not active yet.** The release workflow signs once the project is approved by SignPath Foundation and the settings below exist. Until then the Windows package is unsigned and SmartScreen warns on first run |
| macOS | ad-hoc only | Not notarized: there is no Apple developer identity |
| Every package | GitHub artifact attestation (Sigstore) | Active: `gh attestation verify <package> -R DasCondor/kubefactory` |

## Code signing policy

> Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org).

This applies once SignPath Foundation has approved the project.

- **What is signed:** the Windows executables built by `.github/workflows/release.yml`
  from a tagged commit of this repository: `KubeFactory.exe`,
  `KubeFactory.console.exe` and `kf-agent.exe`. Nothing built anywhere else,
  and no third-party binary, is signed.
- **Roles:** committer, reviewer and approver: [DasCondor](https://github.com/DasCondor).
  Every release signing request is approved by hand on SignPath.
- **Privacy:** KubeFactory does not send information to other networked
  systems unless you ask it to: it talks to the clusters, Docker engines,
  Komodo Core, KubeFactory server, Grafana, Tautulli or AI provider you
  configure, and to the app lists you choose. There is no telemetry. See
  [SECURITY.md](SECURITY.md).

## Turning it on (owner only)

1. Apply at [signpath.org](https://signpath.org) for the free open-source
   certificate. The project qualifies on its face (MIT, public repository,
   releases built by GitHub Actions); SignPath Foundation decides. Everyone
   with access must use multi-factor authentication on GitHub and SignPath.
2. On SignPath: add the predefined **GitHub.com** trusted build system and
   link it to the project; create the project (slug `kubefactory`) and a
   signing policy (slug `release-signing`) that needs manual approval; paste
   [`.signpath/artifact-configuration.xml`](../.signpath/artifact-configuration.xml)
   as the project's artifact configuration; install the SignPath GitHub App on
   the repository.
3. On GitHub (Settings > Secrets and variables > Actions):
   - variable `SIGNPATH_ORGANIZATION_ID`: the organisation id from SignPath
   - secret `SIGNPATH_API_TOKEN`: an API token of a SignPath user who may
     submit to that project and policy
   - optional variables `SIGNPATH_PROJECT_SLUG` and `SIGNPATH_POLICY_SLUG`
     if the slugs differ from the ones above
4. Tag a release. The Windows job uploads the package, waits (up to an hour)
   for the signing request to be approved, puts the signed package in its
   place, checks that every `.exe` in it carries a valid Authenticode
   signature (the job fails otherwise), writes its checksum and attests it.

Only free signing is used. SignPath Foundation's certificate costs nothing for
open-source projects; the trade-off is that Windows shows **SignPath
Foundation** as the publisher, not the project's author. Paid certificates are
deliberately not wired up.

**Not tested:** none of this has run yet. The workflow skips the signing
steps until the variable exists, so releases keep working unsigned. The
artifact configuration should be checked in SignPath's editor the first time.
