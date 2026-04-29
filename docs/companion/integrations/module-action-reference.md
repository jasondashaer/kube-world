# Companion Module Action/Feedback/Variable Reference

Extracted 2026-04-24 from live pod modules.

---

## ProPresenter (renewedvision-propresenter 3.0.2)

### Actions

Action IDs are used as `propresenter:<actionId>` in Companion configs.

| Action ID | Name | Options |
|-----------|------|---------|
| `next` | Next Slide | (none) |
| `last` | Previous Slide | (none) |
| `slideNumber` | Specific Slide | `slide` (textinput), `path` (textinput) |
| `slideLabel` | Specific Slide With Label | `playlistName`, `presentationName`, `slideLabel` |
| `groupSlide` | Specific Slide In A Group | `groupName`, `slideNumber`, `presentationPath` |
| `clearall` | Clear All | (none) |
| `clearslide` | Clear Slide | (none) |
| `clearprops` | Clear Props | (none) |
| `clearaudio` | Clear Audio | (none) |
| `clearbackground` | Clear Background | (none) |
| `cleartelestrator` | Clear Telestrator | (none) |
| `cleartologo` | Clear to Logo | (none) |
| `clearAnnouncements` | Clear Announcements | (none) |
| `clearMessages` | Clear Messages | (none) |
| `stageDisplayLayout` | Pro6 Stage Display Layout | `index` |
| `pro7StageDisplayLayout` | Pro7 Stage Display Layout | `pro7StageScreenUUID`, `pro7StageLayoutUUID` |
| `pro7SetLook` | Pro7 Set Look | `pro7LookUUID` |
| `pro7TriggerMacro` | Pro7 Trigger Macro | `pro7MacroUUID` |
| `stageDisplayMessage` | Stage Display Message | `message` |
| `stageDisplayHideMessage` | Stage Display Hide Message | (none) |
| `clockStart` | Start Clock | `clockIndex` |
| `clockStop` | Stop Clock | `clockIndex` |
| `clockReset` | Reset Clock | `clockIndex` |
| `clockUpdate` | Update Clock | `clockName`, `clockIndex`, `clockTime` |
| `messageSend` | Show Message | `messageIndex`, `messageKeys`, `messageValues` |
| `messageHide` | Hide Message | `messageIndex` |
| `audioStartCue` | Audio Start Cue | `audioChildPath` |
| `audioPlayPause` | Audio Play/Pause | (none) |
| `timelinePlayPause` | Timeline Play/Pause | `presentationPath` |
| `timelineRewind` | Timeline Rewind | `presentationPath` |
| `enableFollowerControl` | Enable Follower Control | `enableFollowerControl` (yes/no) |
| `nwSpecificSlide` | Specific Slide (Network Link) | `playlistName`, `presentationName`, `slideIndex` |
| `nwPropTrigger` | Prop Trigger (Network Link) | `propIndex`, `propName` |
| `nwPropClear` | Prop Clear (Network Link) | `propIndex`, `propName` |
| `nwMessageClear` | Message Clear (Network Link) | `messageIndex`, `messageName` |
| `nwTriggerMedia` | Trigger Media (Network Link) | `playlistName`, `mediaIndex`, `mediaName` |
| `nwTriggerAudio` | Trigger Audio (Network Link) | `playlistName`, `audioIndex`, `audioName` |
| `nwVideoInput` | Trigger Video Input (Network Link) | `videoInputIndex`, `videoInputName` |
| `newRandomNumber` | New Random Number | `randomLimit` |
| `nwCustom` | Custom Action (Network Link) | `endpointPath`, `jsonData` |
| `customAction` | Custom Action (Support Use Only) | `customAction` |

### Feedbacks

| Feedback ID | Description |
|-------------|-------------|
| `propresenter_module_connected` | Module connected to ProPresenter |
| `propresenter_follower_connected` | Follower connected |
| `active_look` | Active Look matches selection |
| `pro7_stagelayout_active` | Pro7 Stage Layout is active |
| `stagedisplay_active` | Stage Display layout is active |

### Variables

| Variable ID | Name |
|-------------|------|
| `connection_status` | Connection Status |
| `connection_timer` | Connection Timer |
| `current_slide` | Current Slide |
| `total_slides` | Total Slides |
| `remaining_slides` | Remaining Slides |
| `presentation_name` | Presentation Name |
| `current_presentation_path` | Current Presentation Path |
| `current_announcement_presentation_path` | Current Announcement Presentation Path |
| `current_announcement_slide` | Current Announcement Slide |
| `current_stage_display_index` | Current Stage Display Index |
| `current_stage_display_name` | Current Stage Display Name |
| `current_pro7_look_name` | Current Pro7 Look Name |
| `current_pro7_stage_layout_name` | Current Pro7 Stage Layout Name |
| `current_random_number` | Current Random Number |
| `video_countdown_timer` | Video Countdown Timer |
| `video_countdown_timer_hourless` | Video Countdown Timer (no hours) |
| `video_countdown_timer_totalseconds` | Video Countdown Timer (total seconds) |
| `watched_clock_current_time` | Watched Clock Current Time |
| `time_since_last_clock_update` | Time Since Last Clock Update |
| `sd_connection_status` | Stage Display Connection Status |
| `pro7_clock_<N>` | Pro7 Clock N (dynamic per clock) |

---

## Yamaha RCP (yamaha-rcp 3.5.10)

Actions are dynamically built from parameter files per mixer model.
Action ID format: Address with `:` replaced by `_` (e.g., `MIXER_Current/InCh/Fader/On`).
All actions with `rw` support are also available as feedbacks (same ID).

Options for every action:
- `X` - Channel/source number (1-based, dropdown or textinput). Supports variables.
- `Y` - Destination/bus number (when applicable). Supports variables.
- `Val` - Value to set. For `bool` type: 0=Off, 1=On, Toggle. For `integer`: numeric range. For `string`: text.

### TF Series Actions (church-relevant subset)

#### Input Channels (x: 1-40)

| Action ID | Name | Type | Range |
|-----------|------|------|-------|
| `MIXER_Current/InCh/Fader/Level` | InCh/Fader/Level | integer | -32768 to 1000 |
| `MIXER_Current/InCh/Fader/On` | InCh/Fader/On (Mute) | bool | 0-1 (0=Mute, 1=On) |
| `MIXER_Current/InCh/Label/Name` | InCh/Label/Name | string | 0-64 chars |
| `MIXER_Current/InCh/Label/Color` | InCh/Label/Color | string | 0-8 |
| `MIXER_Current/InCh/ToMix/Level` | InCh/ToMix/Level | integer | -32768 to 1000 |
| `MIXER_Current/InCh/ToMix/On` | InCh/ToMix/On | bool | 0-1 |
| `MIXER_Current/InCh/ToMix/Pan` | InCh/ToMix/Pan | integer | -63 to 63 |
| `MIXER_Current/InCh/ToMix/PrePost` | InCh/ToMix/PrePost | integer | 0-1 |
| `MIXER_Current/InCh/ToMono/Level` | InCh/ToMono/Level | integer | -32768 to 1000 |
| `MIXER_Current/InCh/ToMono/On` | InCh/ToMono/On | bool | 0-1 |
| `MIXER_Current/InCh/ToFx/Level` | InCh/ToFx/Level | integer | -32768 to 1000 |
| `MIXER_Current/InCh/ToFx/On` | InCh/ToFx/On | bool | 0-1 |
| `MIXER_Current/InCh/ToFx/PrePost` | InCh/ToFx/PrePost | integer | 0-1 |
| `MIXER_Current/InCh/ToStereo/Pan` | InCh/ToStereo/Pan | integer | -63 to 63 |

#### Stereo Input Channels (x: 1-4)

| Action ID | Name | Type | Range |
|-----------|------|------|-------|
| `MIXER_Current/StInCh/Fader/Level` | StInCh/Fader/Level | integer | -32768 to 1000 |
| `MIXER_Current/StInCh/Fader/On` | StInCh/Fader/On | bool | 0-1 |
| `MIXER_Current/StInCh/Label/Name` | StInCh/Label/Name | string | 0-64 chars |

#### FX Return Channels (x: 1-4)

| Action ID | Name | Type | Range |
|-----------|------|------|-------|
| `MIXER_Current/FxRtnCh/Fader/Level` | FxRtnCh/Fader/Level | integer | -32768 to 1000 |
| `MIXER_Current/FxRtnCh/Fader/On` | FxRtnCh/Fader/On | bool | 0-1 |

#### Mix Buses (x: 1-20)

| Action ID | Name | Type | Range |
|-----------|------|------|-------|
| `MIXER_Current/Mix/Fader/Level` | Mix/Fader/Level | integer | -32768 to 1000 |
| `MIXER_Current/Mix/Fader/On` | Mix/Fader/On | bool | 0-1 |
| `MIXER_Current/Mix/Label/Name` | Mix/Label/Name | string | 0-64 chars |

#### Matrix Outputs (x: 1-4)

| Action ID | Name | Type | Range |
|-----------|------|------|-------|
| `MIXER_Current/Mtrx/Fader/Level` | Mtrx/Fader/Level | integer | -32768 to 1000 |
| `MIXER_Current/Mtrx/Fader/On` | Mtrx/Fader/On | bool | 0-1 |
| `MIXER_Current/Mtrx/Label/Name` | Mtrx/Label/Name | string | 0-64 chars |

#### DCA Groups (x: 1-8)

| Action ID | Name | Type | Range |
|-----------|------|------|-------|
| `MIXER_Current/DCA/Fader/Level` | DCA/Fader/Level | integer | -32768 to 1000 |
| `MIXER_Current/DCA/Fader/On` | DCA/Fader/On (Mute) | bool | 0-1 |
| `MIXER_Current/DCA/Label/Name` | DCA/Label/Name | string | 0-64 chars |
| `MIXER_Current/DCA/Label/Color` | DCA/Label/Color | string | 0-8 |

#### Stereo Master (x: 1-2)

| Action ID | Name | Type | Range |
|-----------|------|------|-------|
| `MIXER_Current/St/Fader/Level` | St/Fader/Level | integer | -32768 to 1000 |
| `MIXER_Current/St/Fader/On` | St/Fader/On | bool | 0-1 |
| `MIXER_Current/St/Out/Balance` | St/Out/Balance | integer | -63 to 63 |

#### Mono Master (x: 1)

| Action ID | Name | Type | Range |
|-----------|------|------|-------|
| `MIXER_Current/Mono/Fader/Level` | Mono/Fader/Level | integer | -32768 to 1000 |
| `MIXER_Current/Mono/Fader/On` | Mono/Fader/On | bool | 0-1 |

#### Scene Recall (TF)

| Action ID | Name | Type | Range | Notes |
|-----------|------|------|-------|-------|
| `MIXER_Lib/Bank/Scene/Recall` | Bank/Scene/Recall | integer | 0-100 | X=bank, Y=A(1)/B(2) |
| `MIXER_Lib/Bank/Scene/Store` | Bank/Scene/Store | integer | 0-100 | X=bank, Y=A(1)/B(2) |

### CL/QL Series Actions (differences from TF)

- Input channels: x=1-72 (CL5), y=1 (layer)
- DCA groups: x=1-16
- Mix buses: x=1-24
- Matrix outputs: x=1-8
- Has `InCh/Port/HA/Gain` (range -600 to 6600, i.e. -60.0 to +66.0 dB)
- Has `InCh/Dyna1/Threshold`, `InCh/Dyna2/Threshold`
- Has `InCh/DCA/Assign` (x=channel, y=DCA 1-16)
- Has `FaderBank` recall/toggle actions (CL/QL specific)

#### Scene Recall (CL/QL)

| Action ID | Name | Type | Range |
|-----------|------|------|-------|
| `MIXER_Lib/Scene/Recall` | Scene/Recall | integer | 0-300 |
| `MIXER_Lib/Scene/Store` | Scene/Store | integer | 0-300 |
| `MIXER_Lib/Scene/RecallInc` | Scene/RecallInc | none | (next scene) |
| `MIXER_Lib/Scene/RecallDec` | Scene/RecallDec | none | (prev scene) |

### Yamaha Variables

| Variable ID | Name |
|-------------|------|
| `modelName` | Device Model Name |
| `deviceName` | Device Label |
| `runMode` | Device Run Mode |
| `error` | Device Status |
| `curScene` | Current Scene Number |
| `curSceneName` | Current Scene Name |
| `curSceneComment` | Current Scene Comment |
| `cuedInChannels` | Inputs Cued |
| `cuedStInChannels` | Stereo Inputs Cued |
| `cuedMixes` | Mixes Cued |
| `cuedMatrices` | Matrices Cued |
| `cuedDCAs` | DCAs Cued |

### Yamaha Feedbacks

All writable actions with `rw` access are also feedbacks using the same ID.
Feedbacks return `true` when the current mixer state matches the configured value.
Bool feedbacks support auto-create variable option.

---

## Notes

- **Yamaha fader values**: -32768 = -inf dB, 0 = 0 dB, 1000 = +10 dB. Scale is not linear.
- **Yamaha mute logic**: `Fader/On` = 1 means channel is ON (unmuted), 0 = muted. This is inverted from "mute" terminology.
- **Yamaha action ID in Companion configs**: Use as `yamaha-rcp:<actionId>` where actionId uses `/` separators (the module handles the `:` to `_` conversion internally for lookups).
- **ProPresenter UUIDs**: Look/Macro/StageLayout UUIDs are populated dynamically from the connected ProPresenter instance. Use the Companion UI dropdown to select them.
- **Supported Yamaha models**: CL/QL, TF, PM (Rivage), DM3, DM7, RIO, TIO, RSIO. Each has its own parameter file with model-specific channel counts and features.
