# Model audit (library V6)

Written by `tools/model_audit.gd`. Do not edit by hand: run the tool again.

- Files checked: **423** (141 models at up to three tiers)
- No finding: **393**
- Defect in the file, corrected when the game loads it: **0**
- Defect still present: **30**

## What is checked

| Check | How | Result language |
|---|---|---|
| Loads | GLB parsed by the engine's glTF importer | verified |
| Catalog | triangle count and bounds against `assets/catalog.json` | verified |
| Ground | lowest point against y = 0 | verified |
| Display clear | 35 rays out of each LiveView glass, 45 cm, against every other part's triangles | verified |
| Same parts at every tier | part names compared with the standard tier | verified |
| Solid parts pushed into each other | **not checked**: needs a look at each model | not tested |
| Art standard (Porter V3) | krew and machines are V3; the other categories are V2 and are not placed in the world | by category, not measured |

## Findings

| Model | Tier | Category | State | Finding |
|---|---|---|---|---|
| `crate` | standard | props | defect | reaches 0.015 m below the ground |
| `crate` | enhanced | props | defect | reaches 0.015 m below the ground |
| `crate` | ultra | props | defect | reaches 0.015 m below the ground |
| `forge` | standard | krew | defect | reaches 0.019 m below the ground |
| `forge` | enhanced | krew | defect | reaches 0.019 m below the ground |
| `forge` | ultra | krew | defect | reaches 0.019 m below the ground |
| `hill_marker` | standard | props | defect | reaches 0.029 m below the ground |
| `hill_marker` | enhanced | props | defect | reaches 0.029 m below the ground |
| `hill_marker` | ultra | props | defect | reaches 0.029 m below the ground |
| `pallet` | standard | storage | defect | reaches 0.015 m below the ground |
| `pallet` | enhanced | storage | defect | reaches 0.015 m below the ground |
| `pallet` | ultra | storage | defect | reaches 0.015 m below the ground |
| `rock` | standard | props | defect | reaches 0.029 m below the ground |
| `rock` | enhanced | props | defect | reaches 0.029 m below the ground |
| `rock` | ultra | props | defect | reaches 0.029 m below the ground |
| `scrappy` | standard | krew | defect | reaches 0.019 m below the ground |
| `scrappy` | enhanced | krew | defect | reaches 0.019 m below the ground |
| `scrappy` | ultra | krew | defect | reaches 0.019 m below the ground |
| `shrub` | standard | props | defect | reaches 0.070 m below the ground |
| `shrub` | enhanced | props | defect | reaches 0.070 m below the ground |
| `shrub` | ultra | props | defect | reaches 0.070 m below the ground |
| `supply_box` | standard | props | defect | reaches 0.015 m below the ground |
| `supply_box` | enhanced | props | defect | reaches 0.015 m below the ground |
| `supply_box` | ultra | props | defect | reaches 0.015 m below the ground |
| `toolbox` | standard | props | defect | reaches 0.015 m below the ground |
| `toolbox` | enhanced | props | defect | reaches 0.015 m below the ground |
| `toolbox` | ultra | props | defect | reaches 0.015 m below the ground |
| `wrench` | standard | tools | defect | reaches 0.007 m below the ground |
| `wrench` | enhanced | tools | defect | reaches 0.007 m below the ground |
| `wrench` | ultra | tools | defect | reaches 0.007 m below the ground |

Models that reach below the ground are V2 models or Krew members the game does not place. Porter and Bob are stood on their lowest point, so the game is not affected; the files should still be corrected at the source.

## Corrections applied at load

The library files stay byte-identical to what was supplied; `scripts/models.gd` (`FIXUPS`) moves the named parts when a model is loaded.

None: this version of the library needs no corrections.
