# Saitama — Companion Layout

## Devices
- **Stream Deck XL** (8x4 = 32 buttons) — Full production control

## Equipment
- ATEM switcher (model TBC)
- Yamaha TF1 or TF3 audio mixer
- OBS for streaming + recording
- ProPresenter (TBC)
- Future: Blackmagic dedicated recorder (networked)

## Not In Scope (currently)
- No PTZ camera
- No Home Assistant
- No network-controlled lighting

## Stream Deck XL Pages

### Page 40: Home Dashboard
```
Row 0: [ATEM ●] [OBS ●] [Audio ●] [Slides ●] [      ] [      ] [Mode  ] [Clock ]
Row 1: [STREAM] [REC  ] [      ] [Main   ] [Camera] [Slides] [PiP   ] [Wide  ]
Row 2: [CAM 1 ] [CAM 2] [CAM 3 ] [PC     ] [AUTO  ] [CUT   ] [FTB   ] [DSK   ]
Row 3: [Start ] [Shut ] [Mute  ] [      ] [→Audio] [→Slide] [→Strm ] [PANIC ]
```

### Page 41: Audio Mixer (Yamaha TF)
```
Row 0: [Pastor] [Worshp] [Choir ] [Keys  ] [Guitar] [Media ] [FX    ] [MASTER]
Row 1: [Mute  ] [Mute  ] [Mute  ] [Mute  ] [Mute  ] [Mute  ] [Mute  ] [Mute  ]
Row 2: [Pst ▲ ] [Pst ▼ ] [Wrs ▲ ] [Wrs ▼ ] [Med ▲ ] [Med ▼ ] [Mst ▲ ] [Mst ▼ ]
Row 3: [Scn 1 ] [Scn 2 ] [Scn 3 ] [Scn 4 ] [0dB   ] [-inf  ] [      ] [←Home ]
```

### Page 42: Slides (ProPresenter)
```
Row 0: [ProP ●] [      ] [      ] [      ] [      ] [      ] [      ] [Clock ]
Row 1: [PREV  ] [NEXT  ] [GO    ] [      ] [Sld 1 ] [Sld 2 ] [Sld 3 ] [Sld 4 ]
Row 2: [Norml ] [Lyric ] [Scrpt ] [Blank ] [      ] [CLR S ] [CLR M ] [CLR A ]
Row 3: [T Strt] [T Stop] [T Rst ] [+1min ] [-1min ] [Msg   ] [      ] [←Home ]
```

### Page 43: Stream / Recording
```
Row 0: [OBS ● ] [ATEM ●] [      ] [      ] [      ] [      ] [Recdr ] [Clock ]
Row 1: [Main  ] [Cam   ] [Slide ] [PiP   ] [Wide  ] [Intro ] [Outro ] [BRB   ]
Row 2: [AUTO  ] [CUT   ] [FTB   ] [      ] [      ] [      ] [RC BM ] [ST BM ]
Row 3: [STRM  ] [REC   ] [AudRC ] [      ] [      ] [      ] [      ] [←Home ]
```

## Navigation
- Home (40) → sub-pages via bottom row: →Audio (41), →Slides (42), →Stream (43)
- All sub-pages → Home via ←Home at [3,7]
- PANIC button (2-step confirm): activates FTB + master mute
