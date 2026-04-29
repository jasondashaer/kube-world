# YIBC — Companion Layout

## Devices
- **Stream Deck+** (4x2 buttons + 4 encoders + LCD strip) — PTZ camera control
- **Stream Deck MK2** (5x3 = 15 buttons) — Operations

## Equipment
- PTZ camera (VISCA/TCP at 192.168.1.113:5678, ptzoptics-visca module)
- Yamaha TF5 audio mixer (RCP at 192.168.1.54, yamaha-rcp module)
- ProPresenter 7 v18.4 (at 192.168.1.2:1025, renewedvision-propresenter module)

## Connections

| Module | ID | Host | Notes |
|--------|-----|------|-------|
| ptzoptics-visca | ptz | 192.168.1.113:5678 | VISCA/TCP |
| yamaha-rcp | yamaha | 192.168.1.54 | Model: TF, isFirstInit: true |
| renewedvision-propresenter | propresenter | 192.168.1.2:1025 | Pro7, sendPresentationCurrentMsgs: disabled |

## Camera Presets (VISCA)
| # | Name | Description |
|---|------|-------------|
| 0 | Cross | Cross/altar view |
| 1 | Wide | Wide shot |
| 2 | Sermon | Speaker close-up |
| 3 | Pulpit | Pulpit view |
| 4 | Worship | Worship leader |
| 5 | Guitar | Guitarist |
| 6 | Baptism | Baptism area |

## Stream Deck+ Pages

### Page 20: PTZ Encoder Control (default)
```
Row 0: [Cross ] [Wide  ] [Sermon] [ZOOM +]
Row 1: [Pulpit] [Worshp] [Guitar] [ZOOM -]
LCD:   [PAN ◄►] [TILT▲▼] [SPD 12] [PAGE ►]
Knobs: [PAN   ] [TILT  ] [SPEED ] [PAGE  ]
```
- E0/E1: Pan/Tilt with speed-scaled wait (move → wait → stop per click)
- E2: Speed 1-24 (adjusts camera speed + wait duration), press resets to 12
- E3: Page rotation (toggles between page 20 ↔ 21)
- Zoom: hold buttons to zoom, release to stop
- LCD col 3: pressable — advances to page 21
- Presets: tap = recall, long press = save

### Page 21: PTZ D-Pad Control
```
Row 0: [ZOOM -] [  ▲  ] [ZOOM +] [Wide  ]
Row 1: [  ◄   ] [  ▼  ] [  ►   ] [HOME  ]
LCD:   [Cross ] [Wide  ] [SPD 12] [PAGE ►]
Knobs: [PST A ] [PST B ] [SPEED ] [PAGE  ]
```
- Arrow key layout — hold to move, release to stop
- E0/E1: Preset selectors — rotate scrolls through preset names (Cross→Wide→...→Baptism), press recalls
- LCD col 0/1: pressable — also recalls the selected preset
- LCD col 3: pressable — advances to page 20

### Encoder Grid Mapping (Stream Deck+)
```
Row 0-1: LCD buttons (4x2)
Row 2:   LCD strip segments (4 zones, pressable)
Row 3:   Rotary encoder knobs (4 knobs, rotate + press + long-press)
```

### Speed Control
- Speed knob (E2) range: 1-24 (VISCA native)
- Affects both camera movement speed AND encoder wait duration
- Wait formula: `10 + (speed - 1) * 15` ms (10ms at speed 1, 355ms at speed 24)
- Press speed knob to reset to 12 (default)
- `ptSpeedU`/`ptSpeedD` commands adjust the camera's internal speed register

## Stream Deck MK2 — Page 30: Operations

```
Row 0: [STREAM] [REC   ] [Main  ] [Camera] [Clock ]
Row 1: [PREV  ] [NEXT  ] [CLR A ] [      ] [      ]
Row 2: [Mute  ] [DUCK  ] [      ] [      ] [→ PTZ ]
```

### ProPresenter Controls (Row 1)
- **PREV Slide** (`propresenter:last`) — go back one slide
- **NEXT Slide** (`propresenter:next`) — advance one slide
- **CLEAR All** (`propresenter:clearall`) — clear all outputs

### Audio Controls (Row 2)

#### Master Mute
- Toggles both **stereo master** and **aux 17** (front fill speakers) simultaneously
- Uses `yamaha:MIXER_Current/St/Fader/On` (X=1, Val=Toggle)
- Uses `yamaha:MIXER_Current/Mix/Fader/On` (X=17, Val=Toggle)
- Feedback shows red "MUTE" when stereo master is muted

#### Duck Button (-20dB)
Two-step toggle with smooth 1-second fade:

**Duck down** (press 1):
- Fades stereo master from 0dB to -20dB
- Fades aux 17 from -6dB to -26dB (maintains 6dB offset)
- 20 steps × 50ms = 1 second total
- 1dB per step for smooth transition
- Button changes to "UNDUCK Restore" (orange)

**Unduck up** (press 2):
- Fades stereo master from -20dB back to 0dB
- Fades aux 17 from -26dB back to -6dB
- Same 20 steps × 50ms = 1 second fade
- Button returns to "DUCK -20dB" (amber)

**Technical details:**
- Yamaha TF fader scale: -32768 = -∞dB, 0 = 0dB, 1000 = +10dB (100 units = 1dB)
- Each step sends 2 level commands (stereo + aux) then waits 50ms
- Total: 80 RCP commands per fade (40 level sets + 20 waits × 2 directions)
- The TF5's network stack handles this rate without issues

**Known limitations:**
- Duck assumes starting position of 0dB stereo / -6dB aux 17
- If the mixer is already ducked and Companion restarts, the first press will jump levels before fading
- Workaround: recall a scene to reset to known state before using duck
- Future improvement: use auto-create variable feedback to read actual fader level before ducking

#### Mute vs Duck
- **Mute**: instant on/off, cuts all audio immediately — for emergencies
- **Duck**: smooth -20dB fade over 1 second — for transitions (prayer, announcements, etc.)

## Network Topology (Testing)
```
Main network (192.168.1.x): Stream Decks (.41/.42/.43), PTZ (.113), TF5 (.54), ProPresenter (.2)
Apartment network (192.168.0.x): Pi running Companion (.175)
Companion connects outbound across subnets via Dream Router NAT.
```
