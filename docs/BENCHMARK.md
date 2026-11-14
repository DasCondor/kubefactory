# Graphics benchmark

Baseline: release `de600e8`. 1920x1080, vsync off, the `kubernetes` demo world (23 machines), a fixed 18-second camera route.
GPU: NVIDIA GeForce RTX 5070 Ti Laptop GPU. Median of 3 runs each. Reproduce with `tools\bench.ps1`.

| Build | Avg fps | vs release | Frame ms | 1% low fps | Draw calls | Objects | Primitives | Video mem MB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Release (de600e8) | 425.4 | - | 2.35 | 325.3 | 2055 | 4343 | 965098 | 529.4 |
| Standard | 584.6 | +37% | 1.71 | 488.3 | 2385 | 2878 | 1123906 | 464.4 |
| Enhanced | 394.4 | -7% | 2.54 | 325.8 | 2619 | 3187 | 1420687 | 625.7 |
| Ultra | 168.8 | -60% | 5.92 | 116.5 | 2846 | 3463 | 1726802 | 1533.9 |

## Reading the table

- **Standard draws the same picture as the release for less work.** Each machine's fixed parts are one mesh shared by every machine, so the renderer draws them as instances (see *Objects*).
- **Enhanced and Ultra add to that picture**; their cost is the extra detail, lights, shadow resolution and, on Ultra, global illumination and reflections.
- **Numbers move between sessions** (thermals, background load), the release's most of all. Compare rows within one run of this script, not across runs.
- **Occlusion culling is built in but off by default** (`--occlusion` turns it on). The yard is open, so on this route it hid almost nothing and its CPU cost made Standard about a third slower.
- These are frame rates with vsync off on one machine; they rank the presets, they do not promise a frame rate on yours.
