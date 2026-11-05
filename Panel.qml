import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Bar entry and popup for the OBSBOT Meet SE. Structure follows the
// first-party panels (omarchy.tailscale): one Service child owns every
// process, the popup is a KeyboardPanel, and all protocol and UI rules live in
// Model.js where tests/tst_model.qml covers them.
Panel {
  id: root
  moduleName: "com.aeonarc.obsbot-meet-se"
  ipcTarget: "com.aeonarc.obsbot-meet-se"
  manageIpc: false
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var cam: camera.status || ({})
  readonly property var view: camera.view
  readonly property var icon: Model.barIcon(camera.connection, camera.micPresent && camera.micMuted)
  readonly property bool directionNeedsZoom: Model.directionNeedsZoom(camera.status)
  readonly property bool lockedByFraming: view.controls && !view.manualView
  readonly property real lockedOpacity: 0.45

  readonly property var framingOptions: [
    { value: "off", label: "Off" },
    { value: "group", label: "Group" },
    { value: "closeup", label: "Close-up" },
    { value: "upperBody", label: "Upper body" }
  ]
  readonly property var fovOptions: [
    { value: "0", label: "Wide" },
    { value: "1", label: "Medium" },
    { value: "2", label: "Narrow" }
  ]

  // Restoring defaults takes two clicks; the second must come within 5 s.
  property bool confirmingReset: false
  Timer {
    id: resetConfirmTimer
    interval: 5000
    onTriggered: root.confirmingReset = false
  }

  // Scroll the panel by a wheel step; sliders hand their wheel events here so
  // scrolling past them does not change the camera.
  function scrollBy(wheel) {
    var dy = wheel.pixelDelta.y !== 0 ? wheel.pixelDelta.y : wheel.angleDelta.y / 2
    var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
    panelFlick.contentY = Math.max(0, Math.min(maxY, panelFlick.contentY - dy))
  }

  function control(name) {
    return camera.controls && camera.controls[name] ? camera.controls[name] : null
  }

  onOpenedChanged: if (opened) {
    confirmingReset = false
    mediaDevicesLoader.active = true
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: camera
    active: root.opened
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function toggleMute(): string { camera.toggleMute(); return "ok" }
    function status(): string { return camera.connection }
    function resetDefaults(): string { camera.resetDefaults(); return camera.view.controls ? "ok" : camera.connection }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon.glyph
    active: root.icon.active
    dimmed: root.icon.dimmed
    tooltipText: camera.connection !== "ready" ? "OBSBOT Meet SE · " + root.view.notice
      : (camera.micMuted ? "OBSBOT Meet SE · microphone muted" : "OBSBOT Meet SE")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) camera.toggleMute()
      else if (buttonCode === Qt.MiddleButton) camera.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "m" || t === "M") camera.toggleMute()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Preview ----------
          Rectangle {
            width: parent.width
            height: Math.round(width * 9 / 16)
            radius: Style.cornerRadius
            color: "black"
            clip: true

            // Only while the camera answers: when it re-enumerates (microphone
            // switched off in hardware) the old Camera keeps the dead node, so
            // the preview is dropped and built again once it is back.
            Loader {
              id: previewLoader
              anchors.fill: parent
              active: root.opened && camera.device !== "" && root.view.controls
              sourceComponent: previewComponent
            }

            PreviewNotice {
              visible: !previewLoader.active
              text: root.view.notice
            }
          }

          // ---------- Framing ----------
          Section {
            title: "FRAMING"
            ChoiceRow {
              options: root.framingOptions
              value: root.cam.framing || "off"
              onPicked: function(v) { camera.apply("framing", v) }
            }
          }

          // ---------- View ----------
          Section {
            title: "VIEW"
            // The zoom hint lives in the direction labels: a note here would
            // appear and vanish above the zoom slider while it is dragged.
            note: root.lockedByFraming ? "Locked while auto framing is on, as in the official app." : ""

            ChoiceRow {
              options: root.fovOptions
              value: String(root.cam.fov !== undefined ? root.cam.fov : 0)
              locked: !root.view.manualView
              // The presets are zoom levels 0-2; going through V4L2 keeps the
              // zoom slider and the boxes on one value.
              onPicked: function(v) { camera.setControl("zoom_absolute", Number(v)) }
            }
            SliderRow {
              label: "Zoom"
              controlName: "zoom_absolute"
              // V4L2 keeps only its own last write; the status has the level
              // the presets and hand gestures set too.
              current: root.cam.zoom
              locked: !root.view.manualView
              format: function(v) { return (1 + v / 4).toFixed(2).replace(/\.?0+$/, "") + "×" }
            }
            DirectionRow {
              label: "Horizontal"
              controlName: "pan_absolute"
              // Negative pan moves the picture right, mirrored or not (24/10).
              inverted: true
            }
            DirectionRow {
              label: "Vertical"
              controlName: "tilt_absolute"
            }
            SwitchRow {
              label: "Mirror image"
              checked: root.cam.mirror === true
              onFlipped: camera.apply("mirror", !root.cam.mirror)
            }
            SwitchRow {
              label: "Gestures"
              description: "Control framing and zoom with your hands."
              checked: root.cam.gestures === true
              onFlipped: camera.apply("gestures", { enabled: !root.cam.gestures, option: root.cam.gestureOption })
            }
          }

          // ---------- Microphone ----------
          Section {
            title: "MICROPHONE"

            SwitchRow {
              label: "Mute"
              description: camera.micPresent ? "Instant, through PipeWire. Shortcut: m or right-click the icon."
                : (root.cam.micHardware === false ? "The microphone is off in the camera."
                  : "The system does not see the camera microphone yet.")
              checked: camera.micPresent && camera.micMuted
              locked: !camera.micPresent
              onFlipped: camera.toggleMute()
            }
            SwitchRow {
              label: "Automatic gain"
              checked: root.cam.micAutoGain === true
              onFlipped: camera.apply("micAutoGain", !root.cam.micAutoGain)
            }
            SwitchRow {
              label: "Microphone while the camera sleeps"
              description: "When off, the microphone only records while an app uses the video."
              checked: root.cam.micDuringSleep === true
              onFlipped: camera.apply("micDuringSleep", !root.cam.micDuringSleep)
            }
            SwitchRow {
              label: "Microphone enabled in the camera"
              description: "Turning it off removes the microphone from the system. The camera reconnects and has no video for about 15 seconds."
              // From the camera's status, not the PipeWire node: the node can
              // vanish on its own (WirePlumber restart) with the mic still on.
              checked: root.cam.micHardware === true
              onFlipped: camera.setMicHardware(!root.cam.micHardware)
            }
          }

          // ---------- Image ----------
          Section {
            title: "IMAGE"

            SliderRow { label: "Brightness"; controlName: "brightness" }
            SliderRow { label: "Contrast"; controlName: "contrast" }
            SliderRow { label: "Saturation"; controlName: "saturation" }
            SliderRow { label: "Sharpness"; controlName: "sharpness" }
            SliderRow { label: "Backlight compensation"; controlName: "backlight_compensation" }
            AutoSwitchRow {
              label: "Automatic white balance"
              controlName: "white_balance_automatic"
            }
            SliderRow {
              label: "Color temperature"
              controlName: "white_balance_temperature"
              format: function(v) { return Math.round(v) + " K" }
            }
            AutoSwitchRow {
              label: "Autofocus"
              controlName: "focus_automatic_continuous"
            }
            SliderRow { label: "Focus"; controlName: "focus_absolute" }
          }

          // ---------- Defaults ----------
          Section {
            title: "FACTORY DEFAULTS"
            note: root.confirmingReset
              ? "Click again to confirm. A microphone turned off in the camera stays off."
              : "Resets framing, view, mirror, gestures, gain, sleep microphone and image to their defaults."

            Button {
              width: parent.width
              text: root.confirmingReset ? "Confirm reset" : "Restore factory defaults"
              bordered: true
              selected: root.confirmingReset
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: {
                if (!root.confirmingReset) {
                  root.confirmingReset = true
                  resetConfirmTimer.restart()
                  return
                }
                root.confirmingReset = false
                resetConfirmTimer.stop()
                camera.resetDefaults()
              }
            }
          }

          Item { width: parent.width; height: Style.space(2) }
        }
      }
    }
  }

  // The first Camera loads Qt Multimedia's FFmpeg backend, which froze the
  // shell for ~2 s on the first open. Load it
  // once, shortly after the shell starts, and keep it.
  Loader {
    id: mediaDevicesLoader
    active: false
    sourceComponent: Component {
      Item {
        readonly property var videoInputs: devices.videoInputs
        MediaDevices { id: devices }
        // An idle Camera pulls in the FFmpeg backend ahead of time.
        Camera { active: false }
      }
    }
  }
  Timer {
    interval: 4000
    running: true
    onTriggered: mediaDevicesLoader.active = true
  }

  Component {
    id: previewComponent

    Item {
      id: previewHost
      property string cameraError: ""

      readonly property var matchedDevice: {
        var inputs = mediaDevicesLoader.item ? mediaDevicesLoader.item.videoInputs : []
        for (var i = 0; i < inputs.length; i++) {
          if (String(inputs[i].id) === camera.device) return inputs[i]
        }
        return null
      }

      // Qt resets cameraFormat when the device is set and when the camera
      // starts, so it is re-applied after the event loop (same quirk as the
      // omarchy-webcam plugin). Without it Qt opens the camera at 1080p.
      function applyFormat() {
        Qt.callLater(function() {
          if (!previewHost || !previewCamera || !previewHost.matchedDevice) return
          var want = Model.previewFormat(previewHost.matchedDevice.videoFormats)
          if (want !== null && previewCamera.cameraFormat !== want) previewCamera.cameraFormat = want
        })
      }

      // Opening the camera blocks the shell for a moment; let the panel paint
      // first.
      Component.onCompleted: previewHost.applyFormat()
      property bool started: false
      Timer {
        interval: 180
        running: true
        onTriggered: previewHost.started = true
      }

      Camera {
        id: previewCamera
        cameraDevice: previewHost.matchedDevice
        active: previewHost.started && previewHost.matchedDevice !== null
        onCameraDeviceChanged: previewHost.applyFormat()
        onActiveChanged: if (previewCamera.active) previewHost.applyFormat()
        onErrorOccurred: function(error, errorString) { previewHost.cameraError = errorString }
      }
      CaptureSession { camera: previewCamera; videoOutput: videoOutput }
      VideoOutput {
        id: videoOutput
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectFit
      }
      PreviewNotice {
        visible: previewHost.matchedDevice === null || previewCamera.error !== Camera.NoError
        text: previewHost.matchedDevice === null ? "Preview unavailable."
          : (previewHost.cameraError || "Another app may be using the camera.")
      }
    }
  }

  // A titled block, laid out like the sections of omarchy.monitor.
  component Section: Column {
    property string title: ""
    property string note: ""
    default property alias rows: body.data

    width: parent ? parent.width : 0
    spacing: Style.space(6)
    enabled: root.view.controls
    opacity: enabled ? 1 : root.lockedOpacity

    PanelSeparator { width: parent.width; foreground: root.fg }
    PanelSectionHeader { text: parent.title; foreground: root.fg; fontFamily: root.fontFamily }
    Text {
      width: parent.width
      visible: parent.note !== ""
      text: parent.note
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
    }
    Column {
      id: body
      width: parent.width
      spacing: Style.space(8)
    }
  }

  component ChoiceRow: ButtonGroup {
    property bool locked: false
    signal picked(string value)

    enabled: !locked
    opacity: locked ? root.lockedOpacity : 1
    foreground: root.fg
    fontFamily: root.fontFamily
    onChanged: function(v) { picked(v) }
  }

  // A plain row with the compact switch on the trailing edge, as in the
  // first-party audio and network panels; the whole row flips it. Sizes follow
  // the network list: label in body, the description under it in caption.
  component SwitchRow: Item {
    id: switchRow
    property string label: ""
    property string description: ""
    property bool checked: false
    property bool locked: false
    signal flipped()

    width: parent ? parent.width : 0
    implicitHeight: Math.max(rowText.implicitHeight, rowSwitch.implicitHeight)
    enabled: !locked
    opacity: locked ? root.lockedOpacity : 1

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: switchRow.flipped()
    }
    Column {
      id: rowText
      anchors.left: parent.left
      anchors.right: rowSwitch.left
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        width: parent.width
        text: switchRow.label
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
      }
      Text {
        width: parent.width
        visible: switchRow.description !== ""
        text: switchRow.description
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
      }
    }
    ToggleSwitch {
      id: rowSwitch
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      checked: switchRow.checked
      foreground: root.fg
      onToggled: switchRow.flipped()
    }
  }

  // Header with the live value on the right, then the slider; hidden when the
  // camera does not report the control.
  // White text centred on the black preview area.
  component PreviewNotice: Text {
    anchors.centerIn: parent
    width: parent.width - Style.space(40)
    color: "white"
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
  }

  // A camera auto mode (V4L2 bool); hidden when the camera lacks it.
  component AutoSwitchRow: SwitchRow {
    property string controlName: ""
    readonly property var spec: root.control(controlName)
    visible: spec !== null
    checked: spec !== null && spec.value === 1
    onFlipped: camera.setControl(controlName, checked ? 0 : 1)
  }

  // Pan or tilt: a crop of the zoomed picture, so locked at zoom 1×.
  component DirectionRow: SliderRow {
    hint: root.directionNeedsZoom && !root.lockedByFraming ? "zoom in first" : ""
    locked: !root.view.manualView || root.directionNeedsZoom
    format: function(v) { return Math.round(v / 3600) + "°" }
  }

  component SliderRow: Column {
    id: sliderRow
    property string label: ""
    property string controlName: ""
    property bool locked: false
    property var format: function(v) { return String(Math.round(v)) }
    property var current: undefined
    // Why the slider is locked, shown after the label so the row keeps its height.
    property string hint: ""
    property bool inverted: false
    readonly property var spec: root.control(controlName)
    readonly property int sign: inverted ? -1 : 1
    // Clamped: on 24/10 the camera reported tilt 680401 with max 648000.
    readonly property real shown: spec ? sign * Math.max(spec.min, Math.min(spec.max, current !== undefined ? current : spec.value)) : 0
    readonly property bool inactive: spec !== null && spec.inactive === true

    width: parent ? parent.width : 0
    spacing: Style.space(4)
    visible: spec !== null
    enabled: !locked && !inactive
    opacity: enabled ? 1 : root.lockedOpacity

    Item {
      width: parent.width
      implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight)

      Text {
        id: labelText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: sliderRow.label + (sliderRow.inactive ? " · automatic" : (sliderRow.hint ? " · " + sliderRow.hint : ""))
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        textFormat: Text.PlainText
      }
      Text {
        id: valueText
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: sliderRow.spec ? sliderRow.format(slider.dragging ? slider.liveValue : sliderRow.shown) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        textFormat: Text.PlainText
      }
    }

    PanelSlider {
      id: slider
      bar: root.bar
      width: parent.width
      minimum: sliderRow.spec ? (sliderRow.inverted ? -sliderRow.spec.max : sliderRow.spec.min) : 0
      maximum: sliderRow.spec ? (sliderRow.inverted ? -sliderRow.spec.min : sliderRow.spec.max) : 1
      step: sliderRow.spec && sliderRow.spec.step ? sliderRow.spec.step : 1
      integer: true
      value: sliderRow.shown
      onMoved: function(v) { camera.setControl(sliderRow.controlName, sliderRow.sign * v) }
      onReleased: function(v) { camera.setControl(sliderRow.controlName, sliderRow.sign * v) }

      // Above the slider's own MouseArea: takes only the wheel, so clicks and
      // drags still reach the slider.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        onWheel: function(wheel) { root.scrollBy(wheel) }
      }
    }
  }
}
