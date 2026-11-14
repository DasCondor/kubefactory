# Graphics benchmark

Baseline: release `de600e8`. 1920x1080, vsync off, the `kubernetes` demo world (23 machines), a fixed 18-second camera route.
GPU: NVIDIA GeForce RTX 5070 Ti Laptop GPU. Median of 3 runs each. Reproduce with `tools\bench.ps1`.

| Build | Avg fps | vs release | Frame ms | 1% low fps | Draw calls | Objects | Primitives | Video mem MB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Release (de600e8) | 427.4 | - | 2.34 | 333.7 | 2060 | 4347 | 964979 | 529.4 |
| Standard | 597 | +40% | 1.68 | 494.8 | 1918 | 2775 | 974927 | 462.7 |
| Enhanced | 402.4 | -6% | 2.49 | 341.6 | 2122 | 3119 | 1068548 | 623.5 |
| Ultra | 172.2 | -60% | 5.81 | 119.8 | 2325 | 3430 | 1170211 | 1531.2 |

## Reading the table

- **Standard draws the same picture as the release for less work.** Each machine's fixed parts are one mesh shared by every machine, so the renderer draws them as instances (see *Objects*).
- **Enhanced and Ultra add to that picture**; their cost is the extra detail, lights, shadow resolution and, on Ultra, global illumination and reflections.
- **Numbers move between sessions** (thermals, background load), the release's most of all. Compare rows within one run of this script, not across runs.
- **Occlusion culling is built in but off by default** (`--occlusion` turns it on). The yard is open, so on this route it hid almost nothing and its CPU cost made Standard about a third slower.
- These are frame rates with vsync off on one machine; they rank the presets, they do not promise a frame rate on yours.
