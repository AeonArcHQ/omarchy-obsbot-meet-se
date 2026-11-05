import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import "Model.js" as Model

// Camera state for one bar entry. The vendor protocol goes through obsbot-xu
// (60-byte packets built by Model.js), image controls through v4l2-ctl, and
// the microphone through PipeWire, the same way omarchy.microphone does it.
Item {
  id: root

  // The panel is open: refresh image controls too, and poll faster.
  property bool active: false

  property string connection: "starting"
  property var status: null
  property string device: ""
  property var controls: ({})
  property string lastError: ""

  readonly property var view: Model.availability(connection, status)
  readonly property string helperPath: String(Qt.resolvedUrl("obsbot-xu")).replace(/^file:\/\//, "")

  readonly property var micNode: {
    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i] && Model.isCameraMic(nodes[i].name)) return nodes[i]
    }
    return null
  }
  // No capture node while the camera answers means its microphone is off in
  // hardware (the camera drops its USB audio interface).
  readonly property bool micPresent: micNode !== null
  readonly property bool micMuted: micNode && micNode.audio ? micNode.audio.muted : false

  property var _queue: []
  property var _pendingControl: null
  // Zoom the panel just asked for; status polls inside zoomHold keep it, since
  // the camera takes about a second to report a new level.
  property int _zoomHold: -1
  property bool _resetPending: false
  property int _reconnectTicks: 0
  // Set once the camera has dropped off the bus during a reconnect; only an
  // answer after that means it came back.
  property bool _sawDisconnect: false

  function refresh() {
    if (!statusProcess.running) {
      statusProcess.command = [root.helperPath, "get"]
      statusProcess.running = true
      pollWatchdog.restart()
    }
    // Skip while a write is queued or running, or the read-back would undo the
    // optimistic value.
    var writing = root._pendingControl !== null || setControlProcess.running || resetControlsProcess.running
    if (root.active && !writing) root.readControls()
  }

  function readControls() {
    if (controlsProcess.running || root.device === "") return
    controlsProcess.command = ["v4l2-ctl", "-d", root.device, "--list-ctrls"]
    controlsProcess.running = true
  }

  function apply(feature, value) {
    if (!root.view.controls) return
    root._queue = root._queue.concat(Model.packets(feature, value))
    root.sendNext()
  }

  function sendNext() {
    if (sendProcess.running || root._queue.length === 0) return
    sendProcess.command = [root.helperPath, "set", root._queue[0]]
    root._queue = root._queue.slice(1)
    sendProcess.running = true
  }

  // The camera re-enumerates on USB after this, so the panel shows a
  // reconnecting notice until the helper finds it again.
  function setMicHardware(enabled) {
    if (!root.view.controls) return
    root.apply("micHardware", enabled)
    root.connection = "reconnecting"
    root._reconnectTicks = 0
    root._sawDisconnect = false
    reconnectTimer.restart()
  }

  // Vendor settings go through the packet queue; V4L2 controls one by one, so
  // a control the camera rejects does not stop the rest.
  function resetDefaults() {
    if (!root.view.controls || root.device === "") return
    // Image controls are only polled while the panel is open; read them first
    // when a reset comes from IPC with the panel closed.
    if (Object.keys(root.controls).length === 0) {
      root._resetPending = true
      root.readControls()
      return
    }
    var plan = Model.factoryReset(root.controls)
    root._queue = root._queue.concat(plan.packets)
    root.sendNext()
    if (plan.controls.length === 0 || resetControlsProcess.running) return
    var steps = plan.controls.map(function(pair) {
      return "v4l2-ctl -d \"$0\" " + Model.setCtrlArg(pair[0], pair[1])
    })
    resetControlsProcess.command = ["sh", "-c", steps.join("; "), root.device]
    resetControlsProcess.running = true
  }

  function toggleMute() {
    if (root.micNode && root.micNode.audio) root.micNode.audio.muted = !root.micNode.audio.muted
  }

  // Sliders fire on every step; only the latest value reaches v4l2-ctl.
  function setControl(name, value) {
    if (!root.view.controls || root.device === "" || !root.controls[name]) return
    var snapped = Model.snapControl(root.controls[name], value)
    // Show the new value at once; the read-back after the write confirms it.
    var next = Object.assign({}, root.controls)
    next[name] = Object.assign({}, next[name], { value: snapped })
    root.controls = next
    if (name === "zoom_absolute") {
      root._zoomHold = snapped
      root.status = Model.withZoom(root.status, snapped)
      zoomHold.restart()
    }
    root._pendingControl = { name: name, value: snapped }
    controlDebounce.restart()
  }

  function applyHelperResult(text) {
    var result = null
    try { result = JSON.parse(String(text || "")) } catch (error) { result = null }
    if (!result || typeof result !== "object") {
      root.connection = "error"
      return
    }
    var reconnecting = root.connection === "reconnecting" && reconnectTimer.running
    if (result.ok !== true) {
      // While re-enumerating, the camera vanishes for ~15 seconds.
      if (reconnecting) {
        root._sawDisconnect = true
        return
      }
      root.connection = String(result.error || "error")
      root.status = null
      return
    }
    if (reconnecting && !root._sawDisconnect) return
    root.device = String(result.device || "")
    if (result.status !== undefined) {
      var decoded = Model.decodeStatus(result.status)
      if (decoded === null) {
        root.connection = "error"
        return
      }
      root.status = zoomHold.running ? Model.withZoom(decoded, root._zoomHold) : decoded
    }
    root.connection = "ready"
    reconnectTimer.stop()
  }

  PwObjectTracker { objects: root.micNode ? [root.micNode] : [] }

  onActiveChanged: if (active) refresh()

  Timer {
    id: refreshTimer
    interval: root.active ? 2000 : 6000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: reconnectTimer
    interval: 1500
    repeat: true
    onTriggered: {
      root._reconnectTicks += 1
      if (root._reconnectTicks > 20) {
        reconnectTimer.stop()
        root.connection = "disconnected"
        return
      }
      root.refresh()
    }
  }

  Timer {
    id: controlDebounce
    interval: 120
    repeat: false
    onTriggered: {
      if (root._pendingControl === null) return
      if (setControlProcess.running) {
        controlDebounce.restart()
        return
      }
      var control = root._pendingControl
      root._pendingControl = null
      setControlProcess.command = ["v4l2-ctl", "-d", root.device, Model.setCtrlArg(control.name, control.value)]
      setControlProcess.running = true
    }
  }

  Timer {
    id: zoomHold
    interval: 2000
    repeat: false
  }

  Timer {
    // An ioctl on a camera that is dropping off the bus can hang; reap it so
    // the next poll starts clean.
    id: pollWatchdog
    interval: 5000
    repeat: false
    onTriggered: if (statusProcess.running) statusProcess.running = false
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    onExited: {
      pollWatchdog.stop()
      root.applyHelperResult(statusStdout.text)
    }
  }

  Process {
    id: sendProcess
    running: false
    command: []
    stdout: StdioCollector { id: sendStdout; waitForEnd: true }
    onExited: {
      root.applyHelperResult(sendStdout.text)
      root.sendNext()
    }
  }

  Process {
    id: controlsProcess
    running: false
    command: []
    stdout: StdioCollector { id: controlsStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.controls = Model.parseControls(controlsStdout.text)
      if (root._resetPending) {
        root._resetPending = false
        if (exitCode === 0) root.resetDefaults()
      }
    }
  }

  Process {
    id: resetControlsProcess
    running: false
    command: []
    onExited: root.readControls()
  }

  Process {
    id: setControlProcess
    running: false
    command: []
    stderr: StdioCollector { id: setControlStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.lastError = exitCode === 0 ? "" : String(setControlStderr.text || "").trim()
      // Auto modes flip other controls' inactive flags; read them back.
      root.readControls()
    }
  }
}
