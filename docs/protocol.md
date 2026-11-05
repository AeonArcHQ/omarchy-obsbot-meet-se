# OBSBOT Meet SE protocol

USB camera `3564:fefe`, firmware 4.6.5.1. Everything here comes from
reverse engineering OBSBOT Center 2.x for Windows (`libdev.dll`, sha256
`2486d1f3…`, and `OBSBOT_Main.exe`, sha256 `2239b73b…`) with REA
(`rea-agents@6.4.0`, Hopper and Ghidra 12.1.2), then checked on the real
camera on 2026-10-22. Evidence IDs refer to that session's REA ledger.

## Transport

- UVC Extension Unit 2, GUID `9a1e7291-6843-4683-6d92-39bc7906ee49`.
- Command: `SET_CUR` on selector 6, 60 bytes. Little-endian command word at
  `[0..1]`, arguments from `[2]`, the rest zeroed. There is no header and no
  checksum.
- Status: `GET_CUR` on selector 6, 60 bytes.
- On Windows, `sub_1800087f0` calls `IKsControl::KsProperty` with
  `Flags = 0x10000002` (SET | TOPOLOGY), `Id = 6`, size `0x3c`
  (ev_7da94b38…). On Linux the equivalent is `UVCIOC_CTRL_QUERY`
  (`0xC0107521`), done by `obsbot-xu`.

## Commands the plugin uses

| Word | libdev function | Arguments | Evidence |
|---|---|---|---|
| `0x0100` | cameraSetMediaModeU | `[2]` 0 normal, 2 auto framing | ev_fdceae22… |
| `0x0113` | cameraSetMicrophoneDuringSleepU | `[2]` 0/1 | ev_e6fefb06… |
| `0x0114` | cameraSetImageFlipHorizonU | `[2]` 0/1 | ev_0435a8f2… |
| `0x0117` | cameraSetAudioAutoGainU | `[2]` 0/1 | ev_175e6c3a… |
| `0x011c` | cameraSetAudioMicDisabledU | `[2]` = !disabled (libdev does `xor dl, 1`) | ev_52f02236… |
| `0x020d` | cameraSetAutoFramingModeU | `[2]` subject, `[3]` shot | ev_3914bb94… |
| `0x0520` | cameraSetGestureControlU | `[2]` enabled, `[3]` option, `[4]` bool, `[5..6]` u16; the plugin sends `[4..6]` zeroed and the camera accepts it (2026-10-22) | ev_4ee195a4… |

`0x0104` (cameraSetFovU, `[2]` 0 wide, 1 medium, 2 narrow, ev_d7342e4e…)
works, but the plugin has not used it since 2026-10-24: the presets are
`zoom_absolute` 0, 1 and 2 (see Observed behaviour).

Other commands found and not used: `0x0105`, `0x0106`, `0x0110`, `0x0111`
(virtual background; no effect on the Meet SE), `0x0107`, `0x010c`,
`0x0112`, `0x0118`, `0x0119`, `0x011b`, `0x011e`, `0x020b`, `0x020e`,
`0x0215`, `0x0216`, `0x0222`, `0x0223`, `0x0308`. The full list, with the
assembly excerpt for each, is in `libdev_ledger.txt` from the analysis
session.

## Auto framing

The "OSC - SetAutoFraming" handler in `OBSBOT_Main.exe` (`FUN_140116070`,
ev_cae3aa59…) sends:

- off: MediaMode 0;
- on: MediaMode 2, then AutoFramingMode with `(1, 0)` close-up, `(1, 1)`
  upper body or `(0, 0xff)` group.

The official app locks FoV, zoom and direction while auto framing is on
(string `Ctrl.AutoFrameTipsForMeet2`).

## Status

Factory block read on 2026-10-22:

```
270000020000000101037800000101350000000001000400000103000000001e000310000000840c0000000000000000000000000000000000000000
```

Offsets confirmed by sending each command and diffing the block before and
after:

| Byte | Meaning |
|---|---|
| `[4]` | effective zoom level, 0..12; the FoV presets are levels 0, 1 and 2 |
| `[17]` | FoV: 0 wide, 1 medium, 2 narrow, 3 manual zoom; reads 3 for ~0.3 s right after any zoom change |
| `[16]` | microphone while the camera sleeps |
| `[19]` | mirror |
| `[24]` | framing subject (1 single person) |
| `[25]` | microphone automatic gain |
| `[28]` | shot (0 close-up, 1 upper body, `ff` group); off = `[24]=0` and `[28]=0` |
| `[34]` | bit `0x10`: microphone enabled in the camera (`0x011c`); factory `0x10` (2026-10-24) |
| `[38]` | gestures: `0x80 \| option << 1 \| enabled` (factory `0x84`) |

## Observed behaviour

- With `0x011c` = 0 (microphone off), the camera re-enumerates on USB
  without its audio interface and has no video for about 15 s. With 1, it
  comes back. The camera keeps the value: with 0, it stayed without a
  microphone after unplugging and replugging the cable (2026-10-24).
- At the factory default (`0x0113` = 0), the microphone only delivers
  samples while some app uses the video. With 1, it also records while the
  camera sleeps.
- Zoom, pan/tilt, focus and image settings are standard V4L2 controls
  (`zoom_absolute` 0..12, `pan_absolute`/`tilt_absolute` ±648000 in steps of
  3600, `focus_automatic_continuous` and so on).
- FoV and zoom are one axis (2026-10-24, with video running): `0x0104` 1/2
  and `zoom_absolute` 1/2 leave the same status (`[4]` and `[17]` at 1/2).
  V4L2's `zoom_absolute` only keeps its own last write: after a `0x0104` it
  still reads the old value. `[4]` takes ~1 s to show a new level. With no
  video, the camera ignores requests to zoom in (and does not apply them
  later, when the video opens), but it does go back to level 0; that is why
  restoring defaults works with the panel closed (2026-10-24). With no
  video, a `pan_absolute` or `tilt_absolute` right after `zoom_absolute` = 0
  stops the zoom-out halfway (`[4]` stays at 5); the reset sends pan and
  tilt before zoom.
- A negative `pan_absolute` moves the frame to the right of the picture,
  mirrored or not (2026-10-24).
- Pan and tilt are a digital crop of the zoomed picture: with
  `zoom_absolute` = 0 the camera takes the value, but the picture does not
  move (photos from 2026-10-22).

## Factory reset

libdev has `cameraSetRestoreFactorySettingsR` (ev_6a80aa76…) and
`cameraSetFactorySettingsR` (ev_08126211…), but they use another transport
(`sub_180008180`, commands `0xd` and `0xc`), not the `sub_1800087f0` UVC path
verified on the Meet SE. The plugin does not use them: "Restore factory
defaults" sends the factory block values for each feature the panel controls
and brings the V4L2 controls back to the `default` the camera reports.
Checked on 2026-10-22: afterwards the status matched the factory block and
brightness, contrast, saturation, sharpness, backlight, pan, tilt and zoom
were back at their defaults.
