# Guide: Live Test Runbook

Step-by-step procedure for the first hands-on test of the ARM service-start
chain, service-close pair, segment-transition pads, and `mixer-state-deploy.py`
RCP push. This is the bridge between "all built in YAML" and "running in
production."

Goal: validate each subsystem in isolation with a known-good fallback at
every step, before chaining them together.

Prerequisites:

- TF5 / TF1 mixer powered on with backup `.tff` loaded fresh (so console
  state is exactly what was committed to disk before code changes).
- Stream Decks awake, paired with Companion (web UI confirms surfaces
  green at `/companion/v4.2/...` ).
- ProPresenter open with the regular weekly setup, including a configured
  pre-service countdown timer.
- OBS / ATEM / Spotify reachable (or willingness to skip those phases
  until they're wired).
- Operator + a second person to monitor mixer + room — never test alone.
- Snapshot taken: TF Editor → Backup → save with timestamp BEFORE any
  test starts.

---

## Phase 0 — Verify connections (no buttons pressed yet)

Open Companion web UI on the Pi, Connections tab. Expected status:

| Connection | Status at YIBC | Status at Saitama |
|---|---|---|
| `homeassistant` | green | red (Saitama LAN can't reach HA on YIBC subnet) |
| `ptz` | green | red |
| `yamaha_yibc` | green | red |
| `yamaha_saitama` | red | green |
| `propresenter_yibc` | green | red |
| `propresenter_saitama` | red | green |
| `obs_yibc` | red until OBS host configured + reachable | red |
| `obs_saitama` | red | red until configured |
| `atem_saitama` | red | red until configured |
| `spotify_yibc` | red until OAuth completes | red |
| `spotify_saitama` | red | red until OAuth completes |

If a connection that should be green is red:

1. Verify network reachability with `kubectl exec -n companion deploy/companion -- nc -zv <host> <port>`.
2. Verify credentials in `connections.yaml` if applicable.
3. Check pod logs: `kubectl logs -n companion deploy/companion --tail=100`.

Don't proceed until the connections you intend to test are green.

---

## Phase 1 — Static button validation (no automation)

### 1.1 Page navigation

Walk every page on every Stream Deck. Verify pages render with no error
icons.

| Stream Deck | Pages to walk |
|---|---|
| MK2 (YIBC) | 30 (Ops), 31 (Segments). Confirm SEGMENTS button on page 30 row 2 col 4 navigates to page 31. Confirm ← OPS on page 31 row 2 col 0 returns. |
| Plus (YIBC) | 20 (PTZ), 21 (D-Pad), 22 (if any). Confirm rotation. |
| XL (Saitama) | 40 (Home), 41 (Audio), 42 (ProP), 43 (Stream), 44 (Segments). Confirm nav row 3 of each page. |

### 1.2 Existing audio buttons

These were working before this build cycle. Confirm they still work:

| Test | Expected | Action if failed |
|---|---|---|
| MK2 page 30 row 2 col 0 — Master Mute | Muting/unmuting toggles `St/Fader/On`, indicator turns red when muted | Check `Yamaha_TF5__YIBC_:MIXER_Current/St/Fader/On` variable in Companion UI |
| MK2 page 30 row 2 col 1 — DUCK / UNDUCK | 20-step fade down to -20dB then back, both ST master + Mix17 | If only ST faded, check Mix17 channel exists on TF5 (might be a different bus number) |
| XL page 41 — channel mute buttons | Each button toggles correct channel mute, feedback indicator inverts as expected | Check channel X values: Pastor=11, Worship=1, Keys=6, Guitar=4, Media=14 |

If anything on this list is broken, STOP. Do not proceed to ARM testing —
the new code may have introduced a regression.

---

## Phase 2 — Segment-transition pads (mixer-only impact)

These call `MIXER:Lib/Bank/Scene/Recall` against Bank A. **Mixer must
have Bank A scenes 1-6 populated first.** If Bank A scene 1-6 are
empty (factory blanks), pressing these buttons will reset channels to
factory defaults — likely undesirable.

Pre-test checklist on the mixer:

- [ ] TF Editor → Library → Scene → Bank A: confirm scenes 1-6 have
      meaningful contents (not Initial Data). If they don't, either
      (a) skip this phase, or (b) populate Bank A scenes from existing
      mixer state via TF Editor's Store function.
- [ ] Set Recall Safe (TF Editor → Setup → Recall Safe) to protect:
      Stereo master fader, Mix17, Mix21, Mix22, headamp on critical
      channels (1, 4, 6, 11, 14). Otherwise scene recall will snap
      room volume.

### 2.1 Test each segment button

Press each, watch the mixer screen for visible channel changes:

| Button | Stream Deck | Expected mixer reaction |
|---|---|---|
| ANNOUNCE | MK2 31 row 0 col 0 | Bank A scene 1 recalls — pastor mic up, music muted |
| WORSHIP | MK2 31 row 0 col 1 | Bank A scene 2 — music open, pastor standby |
| SERMON | MK2 31 row 0 col 2 | Bank A scene 3 — pulpit hot, music off |
| GREETING | MK2 31 row 0 col 3 | Bank A scene 4 — ambient room |
| PRELUDE | MK2 31 row 1 col 0 | Bank A scene 5 |
| OFFERING | MK2 31 row 1 col 1 | Bank A scene 6 |
| Status pad | MK2 31 row 0 col 4 | Updates `service_mode` + scene number display |

If a button does not appear to do anything:

1. Check the mixer screen for an error banner.
2. Check Companion's Log Viewer (Logs tab) for RCP error responses.
3. Confirm the connection (`yamaha_yibc`) is still green.

### 2.2 Repeat at Saitama (XL page 44)

Same pattern. Saitama also has Bank-B alternates on row 2 — DO NOT press
those during the first test unless Bank B has been pre-populated by
`mixer-state-deploy.py --apply` (Phase 4 below).

---

## Phase 3 — ARM service-start chain (DRY — no audio yet)

This phase exercises the ARM button + ARM-gated triggers without unmuting
the live recording bus. Useful as a smoke test before going hot.

### 3.1 Disable triggers that touch hardware

In Companion web UI → Triggers tab, the ARM-gated triggers ship DISABLED.
For this dry phase, leave them disabled. The ARM button itself only:

1. Sets `service_armed = "1"`.
2. Calls `propresenter_yibc:clockReset {clockIndex: "0"}`.
3. Calls `propresenter_yibc:clockStart {clockIndex: "0"}`.
4. Sets `service_mode = "Armed"`.
5. Advances button step to show DISARM state.

### 3.2 Press ARM

MK2 page 30 row 1 col 3. Watch for:

| Indicator | Expected |
|---|---|
| Button face | Switches to red `DISARM\n<MM:SS>` showing live countdown |
| ProPresenter | Clock 0 resets to its configured length and starts counting down |
| Status pad (row 1 col 4) | Shows `Armed\n<MM:SS>` |
| `service_armed` variable | Is `"1"` (Companion → Variables tab) |
| `service_mode` variable | Is `"Armed"` |

### 3.3 Press DISARM (the same button, second press)

| Indicator | Expected |
|---|---|
| Button face | Returns to dim `ARM\nService` |
| ProPresenter | Clock 0 stops counting (frozen at current value, NOT reset) |
| `service_armed` | Is `"0"` |
| `service_mode` | Is `"Ready"` |

### 3.4 If ARM does not start the PP timer

- Confirm `propresenter_yibc` connection is green.
- Confirm clock index 0 maps to the desired countdown timer in PP. If
  not, edit `mk2-page01-ops.yaml` row 1 col 3 step 0 actions to use a
  different `clockIndex` value (`"1"`, `"2"`, etc.).
- PP variable `video_countdown_timer` should populate as the clock
  counts. Watch in Companion → Variables tab. If empty, ProPresenter's
  `timerPolling` config flag may need re-confirming.

---

## Phase 4 — Code-pushed mixer scene baseline (Bank B)

Goal: push one declarative scene YAML to the mixer's Bank B and confirm
the script + RCP path work. Bank A is untouched.

### 4.1 Take a fresh backup

TF Editor → Backup → save with new timestamp. This is your rollback if
anything goes wrong below. Confirm the backup file exists on the laptop
running TF Editor before continuing.

### 4.2 Dry-run the deploy

```bash
python3 apps/companion/scripts/mixer-state-deploy.py \
    --location yibc --scene 03-sermon --dry-run
```

Inspect the output:

- Every `set MIXER:...` command should be syntactically clean.
- Channel numbers should match the actual TF5 patch (Pastor=11, etc.).
- The Mix bus number for the stream/record bus should match what's
  actually wired (placeholder is 21 — confirm with operator).
- The store sequence at the end should be `ssstore_ex MIXER:Lib/Bank/Scene 2 3`.

### 4.3 Apply

Only proceed if dry-run looks correct.

```bash
python3 apps/companion/scripts/mixer-state-deploy.py \
    --location yibc --scene 03-sermon --apply
```

Watch:

- Each `OK ...` response printed for every command.
- Mixer screen — channel labels, fader positions, mute states should
  visually update as commands fire.
- After `ssstore_ex`, scene 3 in Bank B should be populated. Verify in
  TF Editor → Library → Scene → Bank B → Scene 3.

If you see `ERROR` responses:

- Script aborts on first ERROR (state may be partial).
- Recall Bank A scene 3 (or the backup scene you saved before testing)
  to restore known-good state.
- Read the ERROR address — usually means a leaf doesn't exist on this
  firmware (e.g. `MIXER:Current/Mono/...` on a TF1 firmware that lacks
  mono master).

### 4.4 Mirror Bank B → Bank A

Once Bank B scene 3 is confirmed correct on the mixer:

1. In TF Editor: Library → Scene → Bank B → Scene 3 → Copy.
2. Library → Scene → Bank A → Scene 3 → Paste (or Store From Library
   on the front panel).
3. Now Bank A scene 3 is the same as Bank B scene 3.
4. Press SERMON button on MK2 page 31 — recalls Bank A scene 3 → mixer
   should land in the same state.

### 4.5 Repeat for other scenes

Push 01-announcements, 02-worship, 04-greeting from `apps/companion/config/scenes/yibc/`
the same way. Mirror to Bank A.

---

## Phase 5 — Service-close pair (HOT — fader moves)

The CLOSE 1 / CLOSE 2 buttons on MK2 page 30 row 2 col 2/3 fire the
recorded close sequence. This phase moves real faders. Have the room
quiet (no live audience) for the first run.

### 5.1 Confirm Spotify is connected

Spotify connection must be green before pressing CLOSE 1, otherwise the
`playPlaylist` action fails silently and the fade-up happens to silence.

If Spotify isn't ready: temporarily edit `mk2-page01-ops.yaml` to comment
out the `spotify_yibc:playPlaylist` line, redeploy via git push, and
test the fade behavior alone.

### 5.2 Set the playlist URI

Edit `apps/companion/config/pages/yibc/mk2-page01-ops.yaml` — locate the
`PLACEHOLDER_PLAYLIST_URI` string and replace with the actual Spotify
playlist URI (right-click → Share → Copy link in Spotify, format
`spotify:playlist:<id>`). Commit + push.

### 5.3 Set the closing graphic macro

Edit the same file — locate `PLACEHOLDER_CLOSING_GRAPHIC_MACRO` and
replace with the Pro7 macro UUID. Extract via Companion UI: open the
ProPresenter connection's variables, look for `pro7MacroUUID` for the
named closing macro. Commit + push.

### 5.4 Press CLOSE 1

Master fader should:

1. Fade from current level to -infinity over ~500ms (audible "duck out").
2. Spotify playlist starts playing on the configured device.
3. After 1.5s, fader fades up over ~6s to -10dB.

### 5.5 Press CLOSE 2

1. Master fader moves to closing target (-3dB by default).
2. Pro7 fires the closing graphic macro.
3. 12s hold — the graphic + audio play out on stream.
4. Record bus (Mix21) fades to -infinity over ~400ms.
5. Pro7 clearAll — graphic dismissed.
6. 800ms wait.
7. OBS stops recording, then streaming.
8. Master remains at -3dB — room music continues.

If anything in this chain misbehaves:

- Master mute on the mixer is the panic stop.
- Record bus fader can be manually pulled up if it ducked too aggressively.
- Pro7 → "Clear All" front panel kills the graphic if it stuck.
- OBS panel "Stop Recording" + "Stop Streaming" if Companion didn't.

---

## Phase 6 — Full ARM-gated chain (HOT)

Only after Phases 1-5 all passed clean.

1. Enable each ARM-gated trigger in Companion → Triggers tab one at a
   time, by clicking the Enable toggle. Triggers fire on condition
   match — they don't activate until the next condition transition.
2. Set ProPresenter clock 0 to a short test length (e.g. 1:30) to keep
   the test short.
3. Press ARM on MK2 page 30.
4. Watch the cascade:
   - At T-1:00 → OBS streaming starts (or whatever the trigger does).
   - At T-0:10 → OBS scene switches to Intro graphic.
   - At T=0:00 → record bus unmutes, OBS recording starts, 7s graphic
     hold, then OBS scene switches to Camera. Service mode flips to
     Live, ARM auto-clears.
5. Validate every transition. Verify the recording file actually started
   (OBS recordings folder).
6. Stop recording manually (or proceed to test the close pair to
   exercise the full service flow).

If a trigger doesn't fire:

- Check the variable comparison. Companion's condition match is exact
  string match — `"00:01:00"` must match exactly. If PP exposes
  `"0:01:00"` (no leading zero on hours), the condition never fires.
  Adjust the trigger conditions in `triggers.yaml` if needed.
- Check `service_armed == "1"` in the Variables tab — if it's "0", ARM
  was reset (auto-disarm at T=0:00 fires for the GO LIVE trigger and
  clears the flag).

---

## Phase 7 — Document delta + commit

After testing, write down:

- Anything that didn't behave as expected (in this runbook + in the
  per-page docs).
- Any placeholder values that needed to change (record_bus_idx, Spotify
  URI, macro UUIDs, OBS scene names).
- Any new failure modes discovered (add to
  `docs/companion/reference/troubleshooting.md`).

Commit the corrected YAML + docs. The YAML is the source of truth — if
something needs adjusting in production, change it there, not in
Companion's web UI.

---

## Rollback paths (memorize these)

| Failure | Rollback |
|---|---|
| Mixer in unexpected state after RCP push | Recall Bank A scene that was in use before, OR recall scene 0 (Initial Data) for hard reset, OR power-cycle mixer to load saved state |
| Companion config broken (Stream Deck shows wrong buttons) | `git revert HEAD && git push` — pipeline reconciles within ~1min |
| Pod stuck or not running | `ssh pi-edge-1 "kubectl rollout restart deployment/companion -n companion"` |
| Stream Deck unpaired | Companion web UI → Surfaces → Add Stream Deck Network Surface with the Pi's LAN IP |
| OBS recording lost | Check `~/Movies/OBS/` (or the configured recording folder) — file is on disk even if recording-stopped wasn't called cleanly |

---

## Cross-references

- ARM flow design: [reference/triggers.md](../reference/triggers.md)
- Page details: [pages/yibc-mk2-30-ops.md](../pages/yibc-mk2-30-ops.md), [pages/yibc-mk2-31-segments.md](../pages/yibc-mk2-31-segments.md)
- Scene strategy: [guides/scene-strategy.md](scene-strategy.md)
- RCP namespace: [reference/yamaha-rcp-namespace.md](../reference/yamaha-rcp-namespace.md)
- Troubleshooting: [reference/troubleshooting.md](../reference/troubleshooting.md)
- Deploy script: `apps/companion/scripts/mixer-state-deploy.py`
