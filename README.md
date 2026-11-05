# OBSBOT Meet SE for Omarchy

An Omarchy bar widget with a live preview and the controls of the OBSBOT
Meet SE webcam, without OBSBOT Center.

- Left click opens the panel. Right click mutes or unmutes the camera
  microphone (no effect while the microphone is off in the camera). Middle
  click reads the state again.
- In the panel: preview; AI framing (off, group, close-up, upper body); view
  (FoV, zoom, direction); mirror; gestures; microphone (mute, automatic
  gain, microphone while the camera sleeps, microphone enabled in the
  camera); image (brightness, contrast, saturation, sharpness, backlight,
  white balance, focus); restore factory defaults (two clicks). The `m` key
  toggles mute; `Esc` closes. The mouse wheel scrolls the panel even over
  the sliders; drag or click to adjust them.
- IPC: `omarchy-shell com.aeonarc.obsbot-meet-se toggle|open|close|show|hide|toggleMute|resetDefaults|status`.

## Requirements

`python`, `v4l-utils`, `qt6-multimedia` and PipeWire (the Omarchy default).
The user must be able to open `/dev/video*` (the `video` group or the logind
ACL, the default in a local session).

## Installation

```sh
omarchy plugin add https://github.com/AeonArcHQ/omarchy-obsbot-meet-se --enable
```

No udev rule is needed.

## Removing

```sh
omarchy plugin remove com.aeonarc.obsbot-meet-se
```

The plugin leaves nothing else behind. Settings changed from the panel
stay in the camera; "Restore factory defaults" brings them back before
removing, if you want.

## How it works

- `obsbot-xu`: a Python helper that finds the camera through sysfs and runs
  `UVCIOC_CTRL_QUERY` on its Extension Unit. It only moves 60-byte packets.
- `Model.js`: builds the packets, decodes the status and decides what the
  panel unlocks. The protocol is in [docs/protocol.md](docs/protocol.md).
- `Service.qml`: processes, PipeWire (microphone) and `v4l2-ctl` (image).
- `Panel.qml`: bar entry and panel, following the first-party Omarchy panels.

## Tests

```sh
tests/check.sh
```

Runs the `obsbot-xu` unittest, the `Model.js` qmltestrunner and
`omarchy plugin validate`. To run it before every commit:
`git config core.hooksPath .githooks`.

Checklist with the camera connected:

1. The icon shows in the bar; without the camera it is dimmed and the panel
   asks to connect the cable.
2. The preview opens with the panel and releases the camera when it closes.
3. Framing: group, close-up and upper body change the picture; off goes back
   to normal. While it is on, FoV, zoom and direction are locked with a
   caption. Test about 2 m from the camera: up close the person already fills
   the frame and the modes look almost the same.
4. FoV, zoom, horizontal and vertical move the picture.
5. Mirror and gestures turn on and off (gestures keep the camera's option).
6. Mute swaps the icon to 󰍭 and silences the PipeWire source; right click
   does the same.
7. "Microphone enabled in the camera" off: reconnecting notice, the camera
   comes back in about 15 s without the microphone; turning it on brings the
   microphone back.
8. Automatic white balance off unlocks the temperature; autofocus off unlocks
   the focus.
9. The mouse wheel over a slider scrolls the panel without changing the value.
10. "Restore factory defaults" asks for confirmation and, on the second
    click, brings the status back to the factory block in `docs/protocol.md`
    and the V4L2 controls to the `default` reported by
    `v4l2-ctl --list-ctrls`.

## Credits

The preview follows the pattern of the
[omarchy-webcam](https://github.com/kristoferlund/omarchy-webcam) plugin by
Kristofer Lund (MIT).

## License

MIT.
