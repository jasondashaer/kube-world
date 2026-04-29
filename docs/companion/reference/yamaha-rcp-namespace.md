# Yamaha TF RCP Namespace Reference

Canonical reference for the Yamaha TF Remote Control Protocol (RCP) parameter namespace. Documents what is addressable on a TF1 (Saitama) or TF5 (YIBC) console **beyond** what the `bitfocus/companion-module-yamaha-rcp` module surfaces. Use this when writing `apps/companion/scripts/mixer-state-deploy.py` (raw RCP push) so the address tree, value scaling, and command verbs are correct first time.

For action IDs as exposed by the Companion module (a curated subset of this namespace), see [action-ids.md](action-ids.md). For the raw module dump see [integrations/module-action-reference.md](../integrations/module-action-reference.md). Project-wide conventions live in [apps/companion/CLAUDE.md](../../../apps/companion/CLAUDE.md).

---

## 1. Protocol basics

| Property | Value |
|---|---|
| Transport | TCP |
| Port | `49280` |
| Encoding | ASCII, line-oriented (`\n` terminator, no length prefix) |
| Auth | None — TCP reachability is the gate. Restrict at network layer. |
| Concurrent clients | Multiple OK; mixer broadcasts NOTIFY to every connected session |
| Idle timeout | None enforced by mixer; keepalive recommended every 30s |

### Command verbs

| Verb | Purpose | Form |
|---|---|---|
| `set` | Write a value | `set <Address> <X> <Y> <Val>` |
| `get` | Read a value | `get <Address> <X> <Y>` |
| `ssrecall_ex` | Recall a scene with bank | `ssrecall_ex MIXER:Lib/Bank/Scene <Bank> <Scene>` |
| `sssstore_ex` | Store current state to scene with bank | `ssstore_ex MIXER:Lib/Bank/Scene <Bank> <Scene>` |
| `devstatus` | Query device status | `devstatus runmode` |

`X` is the source/channel (1-based, 0-based on wire — see scaling), `Y` is the destination/bus index when applicable, `Val` is the value to write. Strings are quoted (`"Vocals"`).

### Response forms

| Form | Meaning |
|---|---|
| `OK <Address> <X> <Y> <Val>` | Successful set/get response |
| `NOTIFY <Address> <X> <Y> <Val>` | Async broadcast on any state change (from any client, including front panel) |
| `ERROR <Address> <reason>` | Address invalid, value out of range, or write attempted on RO param |
| `ERRMSG <text>` | Human-readable error message |

### Value scaling

| Param family | Wire value | Meaning |
|---|---|---|
| Fader level | `-32768` | -infinity dB |
| Fader level | `-2000` | -20 dB |
| Fader level | `-600` | -6 dB |
| Fader level | `0` | 0 dB (unity) |
| Fader level | `1000` | +10 dB (max) |
| Fader On (mute) | `0` | Muted (channel OFF) |
| Fader On (mute) | `1` | Unmuted (channel ON) |
| Pan | `-63` to `+63` | Left to right, `0` = center |
| EQ gain | `-1500` to `1500` | -15.00 to +15.00 dB (1 unit = 0.01 dB) |
| EQ frequency | `0` to `120` | Indexed step (logarithmic over 20 Hz - 20 kHz) |
| Dynamics threshold | `-6000` to `0` | -60.0 to 0.0 dB (1 unit = 0.01 dB) |
| Headamp gain | `-600` to `6600` | -6.0 to +66.0 dB (1 unit = 0.1 dB) |
| Color | `0` to `8` | Off, Blue, Orange, Yellow, Purple, Cyan, Magenta, Red, Green |
| Label name | string | UTF-8, up to 64 chars |

100 wire units = 1 dB in the working fader range (-2000 to 0). Outside that range the curve is non-linear; do not interpolate naively below -2000.

---

## 2. Address tree

All addresses are rooted at `MIXER:`. Two top-level branches:

| Root | Meaning |
|---|---|
| `MIXER:Current/...` | Live state (what is happening right now on the console) |
| `MIXER:Lib/...` | Library entries (stored scenes, channel libraries, effect libraries) |
| `MIXER:Setup/...` | Global setup (Recall Safe, network, user-defined keys) |

### Top-level branches under `MIXER:Current/`

| Branch | TF1 X-range | TF5 X-range | Purpose |
|---|---|---|---|
| `InCh` | 1-16 | 1-32 | Mono input channels |
| `StInCh` | 1-2 | 1-2 | Stereo input pairs |
| `FxRtnCh` | 1-4 | 1-4 | FX return channels |
| `Mix` | 1-16 | 1-20 | Aux/mix buses |
| `Mtrx` | 1-4 | 1-4 | Matrix buses |
| `St` | 1 | 1 | Stereo master |
| `Mono` | 1 | 1 | Mono master (TF5 only on some firmware) |
| `DCA` | 1-8 | 1-8 | DCA groups |
| `HA` | 1-32 | 1-32 | Headamp gain (input ports, may differ from channel index) |
| `UserDef` | 1-12 | 1-16 | User-defined keys |

### Top-level branches under `MIXER:Lib/`

| Branch | Y-range | Purpose |
|---|---|---|
| `Bank/Scene` | bank A=1, B=2; scene 0-100 | Scene library (TF uses bank+scene; CL/QL uses flat) |
| `InCh/Lib` | 0-99 | Channel library (per channel-type) |
| `Effect` | 0-99 | Effect library |
| `Mtrx/Lib` | 0-99 | Matrix bus library |

---

## 3. Per-branch detail

### 3.1 `MIXER:Current/InCh/`

| Address | Type | Range | RW | Notes |
|---|---|---|---|---|
| `Fader/Level` | int | -32768..1000 | rw | Channel fader |
| `Fader/On` | bool | 0/1 | rw | 1 = unmuted |
| `Cue/On` | bool | 0/1 | rw | PFL/AFL solo |
| `Channel/On` | bool | 0/1 | rw | Hard channel on (separate from Fader/On in some firmware) |
| `Label/Name` | string | 0-64 | rw | Display name |
| `Label/Color` | int | 0-8 | rw | See color table above |
| `Label/Icon` | int | 0-127 | rw | Channel icon index |
| `EQ/On` | bool | 0/1 | rw | EQ section enable |
| `EQ/Band1/Q` | int | 10..120 | rw | Q factor (1 unit = 0.1) |
| `EQ/Band1/F` | int | 0..120 | rw | Frequency step |
| `EQ/Band1/G` | int | -1500..1500 | rw | Gain (1 unit = 0.01 dB) |
| `EQ/Band[1-4]/...` | -- | -- | rw | Repeats for bands 2,3,4 |
| `Dyna1/On` | bool | 0/1 | rw | Gate enable |
| `Dyna1/Threshold` | int | -6000..0 | rw | Gate threshold |
| `Dyna2/On` | bool | 0/1 | rw | Compressor enable |
| `Dyna2/Threshold` | int | -6000..0 | rw | Compressor threshold |
| `Dyna2/Ratio` | int | 10..1000 | rw | Compressor ratio (1 unit = 0.1) |
| `Insert/On` | bool | 0/1 | rw | Insert enable |
| `ToMix/Level` | int | -32768..1000 | rw | Y = mix bus number |
| `ToMix/On` | bool | 0/1 | rw | Y = mix bus number |
| `ToMix/Pan` | int | -63..63 | rw | When bus is stereo |
| `ToMix/PrePost` | int | 0/1 | rw | 0 = post-fader, 1 = pre-fader |
| `ToMono/Level` | int | -32768..1000 | rw | -- |
| `ToMono/On` | bool | 0/1 | rw | -- |
| `ToFx/Level` | int | -32768..1000 | rw | Y = FX slot |
| `ToFx/On` | bool | 0/1 | rw | -- |
| `ToFx/PrePost` | int | 0/1 | rw | -- |
| `ToStereo/Level` | int | -32768..1000 | rw | Send to stereo master |
| `ToStereo/On` | bool | 0/1 | rw | -- |
| `ToStereo/Pan` | int | -63..63 | rw | -- |

### 3.2 `MIXER:Current/StInCh/` and `MIXER:Current/FxRtnCh/`

Same leaf set as `InCh/` minus the dynamics section (StInCh has no Dyna1/Dyna2 on TF). Pan replaces the per-channel pan with a balance control (`Out/Balance`).

### 3.3 `MIXER:Current/Mix/`

| Address | Type | Range | RW | Notes |
|---|---|---|---|---|
| `Fader/Level` | int | -32768..1000 | rw | Mix bus master |
| `Fader/On` | bool | 0/1 | rw | -- |
| `Cue/On` | bool | 0/1 | rw | -- |
| `Label/Name` | string | 0-64 | rw | -- |
| `Label/Color` | int | 0-8 | rw | -- |
| `EQ/...` | -- | -- | rw | Output GEQ on master section |
| `Insert/On` | bool | 0/1 | rw | -- |
| `ToMtrx/Level` | int | -32768..1000 | rw | Y = matrix index |
| `ToMtrx/On` | bool | 0/1 | rw | -- |
| `ToStereo/Level` | int | -32768..1000 | rw | Mix bus to main, when configured |

### 3.4 `MIXER:Current/Mtrx/`

Same shape as `Mix/` but with no further send tree.

### 3.5 `MIXER:Current/St/` and `MIXER:Current/Mono/`

| Address | Type | Range | RW |
|---|---|---|---|
| `Fader/Level` | int | -32768..1000 | rw |
| `Fader/On` | bool | 0/1 | rw |
| `Out/Balance` | int | -63..63 | rw |
| `EQ/...` | -- | -- | rw |
| `Insert/On` | bool | 0/1 | rw |
| `ToMtrx/Level` | int | -32768..1000 | rw |
| `ToMtrx/On` | bool | 0/1 | rw |

### 3.6 `MIXER:Current/DCA/`

| Address | Type | Range | RW |
|---|---|---|---|
| `Fader/Level` | int | -32768..1000 | rw |
| `Fader/On` | bool | 0/1 | rw |
| `Cue/On` | bool | 0/1 | rw |
| `Label/Name` | string | 0-64 | rw |
| `Label/Color` | int | 0-8 | rw |
| `Assign` | bool | 0/1 | rw | X = channel, Y = DCA index. **TF: assignment is set via Channel Library, not directly via this leaf** — write at your own risk; CL/QL accepts directly. |

### 3.7 `MIXER:Current/HA/`

| Address | Type | Range | RW | Notes |
|---|---|---|---|---|
| `Gain` | int | -600..6600 | rw | 0.1 dB units. X = port, not channel — port mapping depends on patch. |
| `Pad` | bool | 0/1 | rw | -26 dB pad |
| `Phantom` | bool | 0/1 | rw | +48V on input port |

### 3.8 `MIXER:Lib/Bank/Scene/`

| Address | Type | Range | Notes |
|---|---|---|---|
| `Recall` | int | 0-100 | X = bank (1=A, 2=B), Y = scene |
| `Store` | int | 0-100 | Saves entire current state to specified bank+scene |
| `Title` | string | 0-64 | Scene name (rw) |
| `Comment` | string | 0-256 | Scene comment (rw) |

Use the `ssrecall_ex` / `ssstore_ex` verbs (see Section 1) rather than raw `set` for scene operations — they are atomic and trigger the proper notify chain.

### 3.9 `MIXER:Setup/RecallSafe/`

See Section 4.

### 3.10 `MIXER:Current/UserDef/`

| Address | Type | Range | Notes |
|---|---|---|---|
| `Function` | int | function code | RW. Function code list in TF Editor Settings PDF Appendix B. |
| `Param` | int | varies | RW. Parameter for the function. |

---

## 4. Special parameters

### 4.1 Recall Safe (`MIXER:Setup/RecallSafe/...`)

Global protection list. Channels/buses listed here are NOT overwritten by scene recall.

| Address | Type | RW | Meaning |
|---|---|---|---|
| `Setup/RecallSafe/InCh/On` | bool | rw | X = channel; if 1, channel is safe from recall |
| `Setup/RecallSafe/Mix/On` | bool | rw | X = mix bus |
| `Setup/RecallSafe/St/On` | bool | rw | Stereo master safe |
| `Setup/RecallSafe/DCA/On` | bool | rw | X = DCA index |
| `Setup/RecallSafe/HA/On` | bool | rw | X = port; protects headamp settings |

**TF series limitation**: Recall Safe is **GLOBAL**. The same set is in effect for every scene recall. CL, QL, and Rivage support per-scene "Focus Recall" (define which params each scene touches). TF does not — `MIXER:Setup/Focus/...` does not exist on TF.

### 4.2 User-defined keys (`MIXER:Current/UserDef/...`)

Twelve programmable keys (TF1) or sixteen (TF5). Each key maps to a function code + parameter. Function codes are documented in TF Editor Settings PDF, Appendix B. Common codes:

| Function code | Meaning |
|---|---|
| 0 | No assignment |
| 100..115 | Tap tempo / mute group / scene increment / decrement |
| 200..220 | Page navigation, cue list operations |
| 300..399 | Custom MIDI message send |

### 4.3 Headamp settings

Headamp parameters live under `MIXER:Current/HA/...` indexed by **port** (physical input), not channel. The patch (port-to-channel mapping) is itself a recallable scene parameter unless protected by Recall Safe. For state-deploy that wants stable channel→gain mapping across patches, set `Setup/RecallSafe/HA/On X=<port> Val=1` for every port whose gain you care about.

---

## 5. Scene management

### 5.1 Bank semantics

TF uses two banks of 100 scenes each:

| Bank index | Bank letter | Convention in this project |
|---|---|---|
| `1` | A | Engineer-owned working scenes |
| `2` | B | Code-pushed canonical scenes (pristine reference) |

Scene `0` in either bank is "Initial Data" — factory blank, no channels assigned, all faders at -infinity. Recalling scene 0 mid-service is a hard reset and should be avoided. Scenes `1`-`100` are user-writable.

See [scene-strategy.md](../guides/scene-strategy.md) for how this project uses bank A vs B.

### 5.2 Recall

Wire form (TF):

```
ssrecall_ex MIXER:Lib/Bank/Scene 1 5
```

Recalls bank A (1), scene 5. Mixer responds:

```
OK ssrecall_ex MIXER:Lib/Bank/Scene 1 5
NOTIFY sscurrent_ex MIXER:Lib/Bank/Scene 1 5
NOTIFY set MIXER:Current/InCh/Fader/Level 1 0 -600
... (NOTIFY for every parameter that changed) ...
```

Companion module form (matches Companion's exposed action):

```yaml
- action: yamaha_yibc:MIXER_Lib/Bank/Scene/Recall
  options: { X: 1, Y: 5 }   # X=bank, Y=scene
```

Note the X/Y mapping in the Companion module is reversed from intuition: **X=bank, Y=scene**. Verified in [action-ids.md](action-ids.md#tf-series-action-ids-in-use).

### 5.3 Store

Wire form:

```
ssstore_ex MIXER:Lib/Bank/Scene 2 5
```

Stores entire current console state to bank B (2), scene 5. Title and comment can be set afterward via `set MIXER:Lib/Bank/Scene/Title 2 5 "Sermon"`.

### 5.4 Title and comment

```
set MIXER:Lib/Bank/Scene/Title 2 5 "03-Sermon"
set MIXER:Lib/Bank/Scene/Comment 2 5 "Pastor lavalier hot, music down"
get MIXER:Lib/Bank/Scene/Title 2 5
```

Strings are double-quoted; embedded quotes are escaped with `\"`.

---

## 6. Cross-platform notes

### 6.1 TF1 vs TF5

| Aspect | TF1 (Saitama) | TF5 (YIBC) |
|---|---|---|
| Mono input channels | 16 | 32 |
| Stereo input pairs | 2 | 2 |
| Mix buses | 16 | 20 |
| Matrix buses | 4 | 4 |
| DCA groups | 8 | 8 |
| FX slots | 4 | 4 |
| RCP namespace | identical | identical |
| Scene library size | 100 + Initial | 100 + Initial |
| Recall Safe | global only | global only |

The address tree is the same on both consoles. Code that targets TF1 works on TF5 as long as it does not exceed channel ranges. `mixer-state-deploy.py` should refuse to write `InCh X=20` on TF1 (out of range error from mixer otherwise).

### 6.2 TF vs CL/QL/Rivage

TF lacks the following CL/QL/Rivage features in RCP:

| Feature | TF | CL/QL/Rivage |
|---|---|---|
| Per-scene Focus Recall | no | yes (`MIXER:Lib/Scene/Focus/...`) |
| Flat scene list (`MIXER:Lib/Scene/...`) | no — uses bank+scene | yes |
| `RecallInc` / `RecallDec` | no on TF | yes |
| HA per-channel direct (vs port) | no | yes |
| DCA `Assign` direct write | not reliable | yes |

For mixer-state-deploy targeting TF, do not emit any address under `MIXER:Lib/Scene/` (flat) or `MIXER:Lib/Focus/`.

---

## 7. Worked examples

### 7.1 Set channel 3 fader to -10 dB

```
set MIXER:Current/InCh/Fader/Level 3 0 -1000
```

(Y=0 because InCh has no destination axis.)

Response:

```
OK set MIXER:Current/InCh/Fader/Level 3 0 -1000
NOTIFY set MIXER:Current/InCh/Fader/Level 3 0 -1000
```

### 7.2 Mute channel 3 (set Fader/On = 0)

```
set MIXER:Current/InCh/Fader/On 3 0 0
```

Note the inverted logic: `Val=0` is **muted**, `Val=1` is **unmuted**. See [action-ids.md](action-ids.md#mute-logic-always-inverted).

### 7.3 Recall bank A scene 5

```
ssrecall_ex MIXER:Lib/Bank/Scene 1 5
```

After this, expect a flurry of NOTIFY messages reflecting every parameter the scene set.

### 7.4 Push a state, then store to bank B scene 5

```
set MIXER:Current/InCh/Label/Name 1 0 "Pastor"
set MIXER:Current/InCh/Fader/Level 1 0 -600
set MIXER:Current/InCh/Fader/On 1 0 1
set MIXER:Current/HA/Gain 1 0 350
set MIXER:Current/InCh/Fader/Level 2 0 -32768
set MIXER:Current/InCh/Fader/On 2 0 0
... (rest of state) ...
ssstore_ex MIXER:Lib/Bank/Scene 2 5
set MIXER:Lib/Bank/Scene/Title 2 5 "03-Sermon"
set MIXER:Lib/Bank/Scene/Comment 2 5 "Code-pushed baseline"
```

This is the pattern `mixer-state-deploy.py` (at `apps/companion/scripts/mixer-state-deploy.py`, planned) implements.

### 7.5 Protect stereo master and mix 17 from scene recall

```
set MIXER:Setup/RecallSafe/St/On 1 0 1
set MIXER:Setup/RecallSafe/Mix/On 17 0 1
```

After this, any scene recall (bank A or bank B, any number) will leave the stereo master fader and Mix 17 untouched.

---

## Cross-references

- [reference/action-ids.md](action-ids.md) — Companion-module-exposed subset, with project semantics
- [integrations/module-action-reference.md](../integrations/module-action-reference.md) — raw module action dump
- [reference/smooth-fades.md](smooth-fades.md) — software fade pattern (RCP has no native fade)
- [guides/scene-strategy.md](../guides/scene-strategy.md) — bank A / bank B hybrid model
- [apps/companion/CLAUDE.md](../../../apps/companion/CLAUDE.md) — project conventions
- `apps/companion/scripts/mixer-state-deploy.py` — RCP push tool (planned)
