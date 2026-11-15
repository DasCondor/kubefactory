# Bob 2.0: reading the logs

<sub>[KubeFactory](../README.md) · [All docs](../README.md#-docs-by-topic) · [2.0.0-beta.2 pre-release](https://github.com/DasCondor/kubefactory/releases/tag/v2.0.0-beta.2) · [Known limitations](KNOWN_LIMITATIONS.md)</sub>

Status: **built.** This is the design the feature was built from; the README's
"Bob 2.0" section describes what shipped. Where the two differ, the code wins:
the button reads "Read the log with me, Bob", findings are shown as cards (one
per kind of line, with its line number) rather than as an annotated excerpt,
and the rules and settings live in `scripts/bob.gd` and `bob.json`.

## Where Bob is today

Bob 1.0 diagnoses from the pod's **status word** alone. `diagnose()` in
`scripts/kutil.gd` maps `CrashLoopBackOff`, `ImagePullBackOff`, `OOMKilled` and
so on to one fixed explanation and one fixed remedy. Every CrashLoopBackOff gets
the same advice ("read its logs for the crash reason"), and reading the logs is
left to you.

## What Bob 2.0 does

Bob reads the failed pod's logs and events himself and tells you **which lines
matter and what they mean**.

For each job on the fix list, a new **"What do the logs say, Bob?"** button
opens a log reading:

1. **The verdict.** One sentence naming the actual cause, e.g. "It cannot reach
   its database: connection refused on `postgres:5432`."
2. **The evidence.** The log excerpt with the lines he based that on
   highlighted, each with a short note beside it:

   ```
   12:04:01  starting checkout v3.2.1
   12:04:01  connecting to postgres:5432
   12:04:06  dial tcp 10.96.4.12:5432: connect: connection refused   <- Bob: nobody is listening there. Is the database up?
   12:04:06  fatal: could not connect to database, exiting           <- Bob: and so it quits. This is the line that kills it.
   ```

3. **The remedy,** now specific to the cause, with the fix button when there is
   one (and "Go there" for the *other* workload when the fault is elsewhere,
   such as the database it cannot reach).
4. **How sure he is.** "Certain", "likely" or "a guess". When nothing matches he
   says so and shows the last lines unannotated rather than inventing a cause.

## How it works

### 1. Gather

Reuse what the game already fetches; add nothing new to the backends except one
flag:

| Source | Today | Needed |
|---|---|---|
| Current container log | `{"op": "logs"}` | as is |
| **Previous** container log | not fetched | add `previous: true` (`kubectl logs --previous`). A crash-looping container's current log is often empty; the reason is in the last run. |
| Pod events | `{"op": "events"}` | as is |
| Container state | already in the pod (`reason`, restarts) | also keep the exit code and the terminated message |

Bob asks for the last ~200 lines of each. Results come back through the
existing `hud.on_logs(key, text)` path with a `bob/` key.

### 2. Match

A rule table in a new `scripts/bob_rules.gd`. Each rule is data, so adding one
needs no code:

```gdscript
{"id": "conn-refused",
 "where": "logs",                       # logs | previous | events
 "match": "connection refused|ECONNREFUSED",
 "capture": "([\\w.-]+:\\d+)",           # pulls the host:port out of the line
 "verdict": "It cannot reach %s: nothing is listening there.",
 "note": "nobody is listening there. Is that service up?",
 "remedy": "Check the workload behind that address and its Service.",
 "action": "",                           # "", restart, delete_pod, uncordon
 "sure": "certain"}
```

The matcher scans each source, records every hit with its line number, and
picks the verdict from the **highest-priority rule that hit closest to the end
of the log**: the last error before the exit is usually the cause, earlier ones
are usually symptoms.

First set of rules (about 30), grouped by what goes wrong:

- **Cannot reach something:** connection refused, no such host / DNS failure,
  i/o timeout, TLS / certificate errors
- **Refused by something:** 401 / 403, authentication failed, permission denied,
  RBAC `forbidden`
- **Missing configuration:** env var not set, file not found, ConfigMap / Secret
  key missing, bad flag or config parse error
- **Out of resources:** OOM (exit 137), disk full / no space left, too many open
  files, address already in use
- **The program's own crash:** panic / stack trace (Go, Python traceback, Java
  exception, Node unhandled rejection), segfault, non-zero exit with no message
- **Start-up and probes:** readiness / liveness probe failed, exec format error
  (wrong CPU architecture), command not found, entrypoint permission denied
- **Image and scheduling (from events):** manifest unknown, pull access denied,
  insufficient CPU / memory, taints not tolerated, volume mount failed

### 3. Present

- A **log reading** screen in Bob's panel: verdict, annotated excerpt (matched
  lines in the alert colour, his note right-aligned, a few lines of context
  around each), remedy and buttons.
- The fix-list card shows the verdict in place of the generic status line once
  the reading is done, so the list itself gets smarter as he works through it.
- A second quip pool keyed by rule ("Connection refused. Story of my life.").
- The job board on his stand shows the cause, not just the status:
  `checkout  ->  db refused`.

### 4. Simulation

The demo clusters need logs worth reading. Give each failing simulated pod a
scripted log with a real cause (database down, missing env var, bad image tag,
OOM) so the feature can be tried, and tested, with nothing connected.

## Build order

| Step | What | Done when |
|---|---|---|
| 1 | Rule table, matcher, and unit tests in `tests/` with sample logs | each rule has a passing sample; a log with no known error returns "no verdict" |
| 2 | `previous: true` on the kubectl and Docker log actions | a crash-looping pod's previous log shows in the datapad |
| 3 | Scripted failure logs in `backend_demo.gd` | every failing demo pod has a distinct, matchable cause |
| 4 | Log reading screen in Bob's panel | verdict, highlighted lines and notes show for a demo pod |
| 5 | Verdict on the fix-list card and the stand's board | the list updates after a reading |
| 6 | Quips per rule, README section, screenshot | documented |

## Deliberately left out

- **No AI model and no network calls.** Bob stays a rule table: it works
  offline, in the browser demo, and nothing from your logs leaves the machine.
  An optional model-backed reading could come later behind an explicit setting.
- **No automatic fixes.** He still only points; every action stays a tiered
  button you press.
- **No log history.** He reads what the cluster returns now, not a stored
  archive. Clusters with a log provider configured (Loki, CloudWatch and so on)
  can be added as a source later.

## Open questions

- Should a reading run automatically for every job when the panel opens, or
  only on request? Automatic is nicer but costs one or two `kubectl` calls per
  failing pod.
- Multi-container pods: read every container, or only the one that is failing?
- Should secrets that show up in log lines (tokens, passwords in connection
  strings) be masked in the excerpt?
