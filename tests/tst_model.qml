import QtQuick
import QtTest
import "../Model.js" as Model

TestCase {
  name: "ObsbotMeetSeModel"

  function packet(prefix) {
    var hex = prefix
    while (hex.length < 120) hex += "0"
    return hex
  }

  // Expected bytes come from libdev.dll cameraSetImageFlipHorizonU: the
  // command word 0x0114 is stored little-endian at [0..1] and the flag at [2].
  function test_encode_places_command_word_and_value() {
    compare(Model.packets("mirror", true), [packet("140101")])
  }

  // On 24/10, 0x011c = 1 set [34] to 0x10 and 0 cleared it, in step with the
  // camera's capture node appearing and vanishing in PipeWire.
  function test_mic_hardware_comes_from_bit_4_of_byte_34() {
    compare(Model.decodeStatus(factoryStatus).micHardware, true)
    compare(Model.decodeStatus(withByte(factoryStatus, 34, "00")).micHardware, false)
  }

  function test_set_ctrl_arg_rounds_the_value() {
    compare(Model.setCtrlArg("zoom_absolute", 2.4), "--set-ctrl=zoom_absolute=2")
  }

  // OBSBOT Center (Ctrl.AutoFrameTipsForMeet2): "When Auto Framing is
  // activated, adjustment of FoV, Zoom in/out and Direction will be disabled."
  function test_fov_zoom_and_direction_are_locked_while_auto_framing() {
    var framed = Model.decodeStatus(withByte(factoryStatus, 28, "ff"))
    compare(Model.availability("ready", framed).manualView, false)
    compare(Model.availability("ready", Model.decodeStatus(factoryStatus)).manualView, true)
  }

  function test_controls_are_locked_until_the_camera_answers() {
    var states = ["starting", "missing", "access-denied", "disconnected", "reconnecting", "error"]
    for (var i = 0; i < states.length; i++) {
      var view = Model.availability(states[i], null)
      compare(view.controls, false, states[i])
      verify(view.notice.length > 0, states[i])
    }
    var ready = Model.availability("ready", Model.decodeStatus(factoryStatus))
    compare(ready.controls, true)
    compare(ready.notice, "")
  }

  // Like omarchy.microphone, a muted mic swaps the glyph instead of relying on
  // colour alone.
  function test_bar_icon_shows_mute_and_missing_camera() {
    var normal = Model.barIcon("ready", false)
    compare(normal.glyph, "󰖠")
    compare(normal.active, false)
    compare(normal.dimmed, false)

    var muted = Model.barIcon("ready", true)
    compare(muted.glyph, "󰍭")
    compare(muted.active, true)

    var missing = Model.barIcon("missing", false)
    compare(missing.glyph, "󰖠")
    compare(missing.dimmed, true)
  }

  // PipeWire node names on 22/10: the laptop mic, its speaker monitor, the
  // camera's video node and the camera's capture node.
  function test_recognises_only_the_camera_capture_node() {
    verify(Model.isCameraMic("alsa_input.usb-Remo_Tech_Co.__Ltd._OBSBOT_Meet_SE-02.analog-stereo"))
    verify(!Model.isCameraMic("alsa_input.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Mic1__source"))
    verify(!Model.isCameraMic("alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Speaker__sink.monitor"))
    verify(!Model.isCameraMic("v4l2_input.pci-0000_00_14.0-usb-0_3_1.0"))
  }

  // Sizes `v4l2-ctl --list-formats-ext` lists for the camera on 22/10. The
  // panel shows ~475 px wide, so decoding 1080p in the shell only costs time.
  function test_preview_uses_the_smallest_16_9_format() {
    function f(w, h, fps) { return { resolution: { width: w, height: h }, maxFrameRate: fps } }
    var formats = [f(1920, 1080, 30), f(1280, 720, 30), f(640, 480, 30), f(640, 360, 15), f(640, 360, 30)]
    var chosen = Model.previewFormat(formats)
    compare(chosen.resolution.width, 640)
    compare(chosen.resolution.height, 360)
    compare(chosen.maxFrameRate, 30)
    compare(Model.previewFormat([]), null)
    compare(Model.previewFormat([f(1920, 1080, 30)]).resolution.width, 1920)
  }

  // Restoring defaults sends what the factory status block says (framing off,
  // wide FoV, no mirror, auto gain on, mic asleep with the camera, gestures off
  // on option 2) and puts each V4L2 control the panel shows back to the default
  // the camera reports, auto modes first; a manual value under an auto mode
  // that is on by default is left alone, since the camera rejects it.
  function test_factory_reset_matches_the_factory_status_and_v4l2_defaults() {
    var plan = Model.factoryReset(Model.parseControls(controlsOutput))
    compare(plan.packets, [packet("000100"), packet("140100"),
      packet("170101"), packet("130100"), packet("20050002")])
    compare(plan.controls, [["white_balance_automatic", 1], ["focus_automatic_continuous", 1],
      ["pan_absolute", 0], ["zoom_absolute", 0], ["brightness", 50]])

    var applied = Model.decodeStatus(factoryStatus)
    compare(applied.framing, "off")
    compare(applied.gestureOption, 2)
  }

  // pan_absolute steps by 3600 (one degree); a click lands anywhere on the
  // track, so the value is rounded to the step the camera reports.
  function test_snap_control_rounds_to_the_camera_step() {
    var pan = Model.parseControls(controlsOutput).pan_absolute
    compare(Model.snapControl(pan, 12345), 10800)
    compare(Model.snapControl(pan, 999999), 648000)
    compare(Model.snapControl({ min: 0, max: 100 }, 49.6), 50)
  }

  // On 22/10 the camera took pan/tilt at zoom 0 but the picture did not move;
  // at zoom 6 it panned. Direction is a digital crop of the zoomed image. The
  // level comes from the status, which also sees preset and gesture zoom.
  function test_direction_needs_zoom() {
    var status = Model.decodeStatus(factoryStatus)
    compare(Model.directionNeedsZoom(status), true)
    compare(Model.directionNeedsZoom(Model.withZoom(status, 6)), false)
    compare(Model.directionNeedsZoom(null), false)
  }

  // On 24/10, with video running: FoV 1/2 and zoom_absolute 1/2 both set [4]
  // and [17] to 1/2; zoom 3+ set [4] to the level and [17] to 3. Right after a
  // change [17] read 3 for ~0.3 s while [4] still held the old level.
  function test_fov_follows_the_zoom_level_in_byte_4() {
    compare(Model.decodeStatus(withByte(factoryStatus, 4, "01")).fov, 1)
    compare(Model.decodeStatus(withByte(factoryStatus, 4, "02")).fov, 2)
    var zoomed = Model.decodeStatus(withByte(withByte(factoryStatus, 4, "06"), 17, "03"))
    compare(zoomed.zoom, 6)
    compare(zoomed.fov, -1)
    var settling = Model.decodeStatus(withByte(withByte(factoryStatus, 4, "01"), 17, "03"))
    compare(settling.fov, 1)
  }

  // A zoom the panel just sent shows at once, on the slider and the boxes.
  function test_with_zoom_updates_level_and_preset_together() {
    var status = Model.decodeStatus(factoryStatus)
    var medium = Model.withZoom(status, 1)
    compare(medium.zoom, 1)
    compare(medium.fov, 1)
    compare(medium.mirror, status.mirror)
    compare(Model.withZoom(status, 6).fov, -1)
    compare(status.zoom, 0)
    compare(Model.withZoom(null, 1), null)
  }

  // Excerpt of `v4l2-ctl -d /dev/video2 --list-ctrls` on 22/10.
  readonly property string controlsOutput: [
    "",
    "User Controls",
    "",
    "                     brightness 0x00980900 (int)    : min=0 max=100 step=1 default=50 value=50 flags=has-min-max",
    "        white_balance_automatic 0x0098090c (bool)   : default=1 value=1",
    "           power_line_frequency 0x00980918 (menu)   : min=0 max=2 default=3 value=2 (60 Hz)",
    "      white_balance_temperature 0x0098091a (int)    : min=2000 max=10000 step=100 default=5000 value=3500 flags=inactive, has-min-max",
    "",
    "Camera Controls",
    "",
    "                   pan_absolute 0x009a0908 (int)    : min=-648000 max=648000 step=3600 default=0 value=0 flags=has-min-max",
    "     focus_automatic_continuous 0x009a090c (bool)   : default=1 value=1",
    "                  zoom_absolute 0x009a090d (int)    : min=0 max=12 step=1 default=0 value=0 flags=has-min-max"
  ].join("\n")

  function test_parse_v4l2_controls_reads_ranges_values_and_flags() {
    var controls = Model.parseControls(controlsOutput)
    compare(controls.brightness.min, 0)
    compare(controls.brightness.max, 100)
    compare(controls.brightness.value, 50)
    compare(controls.brightness.inactive, false)
    compare(controls.white_balance_automatic.type, "bool")
    compare(controls.white_balance_automatic.value, 1)
    compare(controls.white_balance_temperature.step, 100)
    compare(controls.white_balance_temperature.inactive, true)
    compare(controls.pan_absolute.min, -648000)
    compare(controls.zoom_absolute.max, 12)
    compare(controls.power_line_frequency.value, 2)
  }

  // cameraSetMicrophoneDuringSleepU (0x0113). On 22/10 the camera mic gave no
  // samples without video until this was 1; status [16] followed it.
  function test_mic_during_sleep_command_and_status() {
    compare(Model.packets("micDuringSleep", true), [packet("130101")])
    compare(Model.decodeStatus(factoryStatus).micDuringSleep, false)
    compare(Model.decodeStatus(withByte(factoryStatus, 16, "01")).micDuringSleep, true)
  }

  // cameraSetImageFlipHorizonU (0x0114) and cameraSetAudioAutoGainU (0x0117)
  // take the plain flag at [2].
  function test_mirror_and_mic_auto_gain_send_plain_flags() {
    compare(Model.packets("mirror", true), [packet("140101")])
    compare(Model.packets("micAutoGain", false), [packet("170100")])
  }

  // cameraSetGestureControlU writes enabled at [2] and the gesture option at
  // [3]. Status [38] is 0x80 | option << 1 | enabled: factory 0x84 is option 2,
  // off, and sending (0, 2) restored it on 22/10.
  function test_gestures_keep_the_option_the_camera_reports() {
    compare(Model.packets("gestures", { enabled: true, option: 2 }), [packet("20050102")])
    compare(Model.decodeStatus(factoryStatus).gestureOption, 2)
  }

  // Sequences copied from OBSBOT_Main.exe's OSC SetAutoFraming handler
  // (FUN_140116070): media mode 2 first, then cameraSetAutoFramingModeU.
  function test_framing_sequences_match_official_app() {
    compare(Model.packets("framing", "off"), [packet("000100")])
    compare(Model.packets("framing", "closeup"), [packet("000102"), packet("0d020100")])
    compare(Model.packets("framing", "upperBody"), [packet("000102"), packet("0d020101")])
    compare(Model.packets("framing", "group"), [packet("000102"), packet("0d0200ff")])
  }

  // Status bytes [24]/[28] read after each sequence on 22/10.
  function test_decode_framing_mode() {
    compare(Model.decodeStatus(factoryStatus).framing, "off")
    var single = withByte(factoryStatus, 24, "01")
    compare(Model.decodeStatus(single).framing, "closeup")
    compare(Model.decodeStatus(withByte(single, 28, "01")).framing, "upperBody")
    compare(Model.decodeStatus(withByte(factoryStatus, 28, "ff")).framing, "group")
  }

  // Status read from the camera on 22/10 with factory settings.
  readonly property string factoryStatus: "270000020000000101037800000101350000000001000400000103000000001e000310000000840c0000000000000000000000000000000000000000"

  function withByte(status, index, value) {
    return status.slice(0, index * 2) + value + status.slice(index * 2 + 2)
  }

  function test_decode_factory_status() {
    var state = Model.decodeStatus(factoryStatus)
    compare(state.fov, 0)
    compare(state.mirror, false)
    compare(state.micAutoGain, true)
    compare(state.gestures, false)
  }

  // Byte changes observed on the camera after each command on 22/10.
  function test_decode_follows_observed_byte_changes() {
    compare(Model.decodeStatus(withByte(factoryStatus, 4, "02")).fov, 2)
    compare(Model.decodeStatus(withByte(factoryStatus, 19, "01")).mirror, true)
    compare(Model.decodeStatus(withByte(factoryStatus, 25, "00")).micAutoGain, false)
    compare(Model.decodeStatus(withByte(factoryStatus, 38, "85")).gestures, true)
  }

  function test_decode_rejects_short_or_garbled_blocks() {
    compare(Model.decodeStatus("2700"), null)
    compare(Model.decodeStatus(""), null)
  }

  // cameraSetAudioMicDisabledU sends !disabled (xor dl, 1). On 22/10 the raw
  // byte 0 made the camera drop its USB audio interface; 1 brought it back.
  function test_encode_mic_hardware_sends_one_when_enabled() {
    compare(Model.packets("micHardware", true), [packet("1c0101")])
    compare(Model.packets("micHardware", false), [packet("1c0100")])
  }
}
