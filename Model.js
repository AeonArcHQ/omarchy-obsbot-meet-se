// OBSBOT Meet SE vendor protocol. Every command is a 60-byte SET_CUR on
// selector 6 of the camera's UVC extension unit: a little-endian command word
// at [0..1], arguments from [2]. See docs/protocol.md for the evidence.

var PACKET_SIZE = 60

var MEDIA_MODE = 0x0100
var AUTO_FRAMING = 0x020d
var MEDIA_MODE_NORMAL = 0
var MEDIA_MODE_AUTO_FRAMING = 2

// AutoFramingType pairs sent by OBSBOT Center after switching to auto framing.
var FRAMING = {
  group: [0, 0xff],
  closeup: [1, 0],
  upperBody: [1, 1]
}

// Each feature maps a UI value to the [command, args] steps the camera needs.
// FoV presets are not here: they are zoom_absolute 0-2 (docs/protocol.md).
var COMMANDS = {
  // The camera takes "enabled"; libdev's cameraSetAudioMicDisabledU inverts.
  micHardware: function(enabled) { return [[0x011c, [enabled ? 1 : 0]]] },
  micDuringSleep: function(on) { return [[0x0113, [on ? 1 : 0]]] },
  mirror: function(on) { return [[0x0114, [on ? 1 : 0]]] },
  micAutoGain: function(on) { return [[0x0117, [on ? 1 : 0]]] },
  gestures: function(value) { return [[0x0520, [value.enabled ? 1 : 0, value.option]]] },
  framing: function(mode) {
    if (mode === "off") return [[MEDIA_MODE, [MEDIA_MODE_NORMAL]]]
    return [[MEDIA_MODE, [MEDIA_MODE_AUTO_FRAMING]], [AUTO_FRAMING, FRAMING[mode]]]
  }
}

// Status offsets confirmed by sending each command and diffing the block.
var STATUS = {
  // [4] is the effective zoom level. The FoV presets are its first three
  // steps: [17] follows it as 0, 1, 2 or 3 (manual), but reads 3 for ~0.3 s
  // after every zoom change, so the panel goes by [4] alone.
  zoom: 4,
  micDuringSleep: 16,
  mirror: 19,
  framingSubject: 24,
  framingShot: 28,
  micAutoGain: 25,
  // Bit 0x10 is set while the microphone is enabled in hardware (0x011c).
  micHardware: 34,
  gestures: 38
}

function hexByte(value) {
  var text = (value & 0xff).toString(16)
  return text.length === 1 ? "0" + text : text
}

function packet(command, args) {
  var bytes = [command & 0xff, (command >> 8) & 0xff].concat(args)
  var hex = ""
  for (var i = 0; i < PACKET_SIZE; i++) hex += hexByte(i < bytes.length ? bytes[i] : 0)
  return hex
}

function packets(feature, value) {
  return COMMANDS[feature](value).map(function(step) { return packet(step[0], step[1]) })
}

function decodeFraming(subject, shot) {
  if (subject === 1) return shot === 1 ? "upperBody" : "closeup"
  return shot === 0xff ? "group" : "off"
}

// Wide, Medium and Narrow are zoom_absolute 0, 1 and 2; above that no preset.
function fovForZoom(zoom) {
  return zoom >= 0 && zoom <= 2 ? zoom : -1
}

// The status with a zoom level the camera has not reported yet.
function withZoom(status, zoom) {
  if (status === null || status === undefined) return status
  return Object.assign({}, status, { zoom: zoom, fov: fovForZoom(zoom) })
}

function decodeStatus(hex) {
  var text = String(hex || "")
  if (!/^[0-9a-fA-F]+$/.test(text) || text.length !== PACKET_SIZE * 2) return null
  function byteAt(index) { return parseInt(text.substr(index * 2, 2), 16) }
  return {
    zoom: byteAt(STATUS.zoom),
    fov: fovForZoom(byteAt(STATUS.zoom)),
    mirror: byteAt(STATUS.mirror) === 1,
    framing: decodeFraming(byteAt(STATUS.framingSubject), byteAt(STATUS.framingShot)),
    micAutoGain: byteAt(STATUS.micAutoGain) === 1,
    micDuringSleep: byteAt(STATUS.micDuringSleep) === 1,
    micHardware: (byteAt(STATUS.micHardware) & 0x10) !== 0,
    // 0x80 | option << 1 | enabled; see docs/protocol.md.
    gestures: (byteAt(STATUS.gestures) & 0x01) === 1,
    gestureOption: (byteAt(STATUS.gestures) >> 1) & 0x3f
  }
}

var NOTICES = {
  starting: "Looking for the camera…",
  missing: "OBSBOT Meet SE not found. Connect the USB cable.",
  "access-denied": "No permission to access the camera.",
  disconnected: "The camera disconnected.",
  reconnecting: "The camera is reconnecting; this takes about 15 seconds.",
  error: "The camera did not answer the command."
}

// What the panel may touch for a given helper connection state and status.
function availability(connection, status) {
  var ready = connection === "ready" && status !== null && status !== undefined
  return {
    controls: ready,
    // OBSBOT Center locks FoV, zoom and direction while auto framing drives
    // the view.
    manualView: ready && status.framing === "off",
    notice: ready ? "" : (NOTICES[connection] || NOTICES.error)
  }
}

// Parse `v4l2-ctl --list-ctrls` into { name: { type, min, max, step,
// default, value, inactive } }. Menu labels after the value are ignored.
function parseControls(text) {
  var controls = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^\s*([a-z0-9_]+) 0x[0-9a-f]+ \((\w+)\)\s*:\s*(.*)$/)
    if (!match) continue
    var control = { type: match[2], inactive: false }
    var fields = match[3].split(/\s+/)
    for (var j = 0; j < fields.length; j++) {
      var pair = fields[j].match(/^(min|max|step|default|value)=(-?\d+)$/)
      if (pair) control[pair[1]] = Number(pair[2])
    }
    var flags = match[3].match(/flags=(.*)$/)
    control.inactive = !!flags && /\binactive\b/.test(flags[1])
    controls[match[1]] = control
  }
  return controls
}

// Whether a PipeWire node name is the camera's microphone capture node.
function isCameraMic(name) {
  return /^alsa_input\.usb-Remo_Tech_Co.*OBSBOT_Meet_SE/.test(String(name || ""))
}

var GLYPH_WEBCAM = "󰖠"
var GLYPH_MIC_OFF = "󰍭"

// Bar glyph for a helper connection state and the camera mic's mute flag.
function barIcon(connection, micMuted) {
  var ready = connection === "ready"
  return {
    glyph: ready && micMuted ? GLYPH_MIC_OFF : GLYPH_WEBCAM,
    active: ready && micMuted === true,
    dimmed: !ready
  }
}

// Preview format: the smallest 16:9 size at least 640 wide, at its highest
// frame rate. The panel is ~475 px wide and Qt decodes in the shell process.
function previewFormat(formats) {
  var best = null
  for (var i = 0; i < (formats ? formats.length : 0); i++) {
    var size = formats[i].resolution
    if (size.width < 640 || size.width * 9 !== size.height * 16) continue
    if (best === null || size.width < best.resolution.width
        || (size.width === best.resolution.width && formats[i].maxFrameRate > best.maxFrameRate)) best = formats[i]
  }
  if (best !== null || !formats || formats.length === 0) return best
  return formats[0]
}

// Values in the factory status block (docs/protocol.md), as panel features.
var FACTORY = [
  ["framing", "off"],
  ["mirror", false],
  ["micAutoGain", true],
  ["micDuringSleep", false],
  ["gestures", { enabled: false, option: 2 }]
]

// V4L2 controls the panel shows, auto modes first: the camera rejects a manual
// value while its auto mode is on. Zoom goes after pan and tilt and last of
// the three: with no video, a pan or tilt right after it stopped the zoom-out
// at level 5 (24/10).
var RESET_CONTROLS = ["white_balance_automatic", "focus_automatic_continuous",
  "pan_absolute", "tilt_absolute", "zoom_absolute", "brightness", "contrast",
  "saturation", "sharpness", "backlight_compensation",
  "white_balance_temperature", "focus_absolute"]
var AUTO_FOR = {
  white_balance_temperature: "white_balance_automatic",
  focus_absolute: "focus_automatic_continuous"
}

// What "restore defaults" sends: vendor packets, then [name, default] pairs.
function factoryReset(controls) {
  var list = []
  for (var i = 0; i < FACTORY.length; i++) list = list.concat(packets(FACTORY[i][0], FACTORY[i][1]))
  var pairs = []
  for (var j = 0; j < RESET_CONTROLS.length; j++) {
    var name = RESET_CONTROLS[j]
    var spec = controls ? controls[name] : null
    if (!spec || spec["default"] === undefined) continue
    var auto = controls[AUTO_FOR[name]]
    if (auto && auto["default"] === 1) continue
    pairs.push([name, spec["default"]])
  }
  return { packets: list, controls: pairs }
}

// v4l2-ctl argument that sets one control.
function setCtrlArg(name, value) {
  return "--set-ctrl=" + name + "=" + Math.round(value)
}

// Round a slider value to the control's step and clamp it to its range.
function snapControl(spec, value) {
  var step = spec.step || 1
  var snapped = spec.min + Math.round((value - spec.min) / step) * step
  return Math.max(spec.min, Math.min(spec.max, snapped))
}

// Pan and tilt crop the zoomed picture; at zoom 0 there is nothing to move.
function directionNeedsZoom(status) {
  return !!status && status.zoom === 0
}
