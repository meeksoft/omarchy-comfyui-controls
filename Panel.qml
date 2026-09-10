import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "meeksoft.comfyui-controls"
  ipcTarget: "meeksoft.comfyui-controls"
  manageIpc: false

  // The bar instantiates this panel once per monitor, so an IpcHandler
  // declared here would register the same target from every instance and only
  // the first would win, leaving the IPC surface owned by whichever screen
  // happened to load first. Elect one instance instead. Both sides rebind if
  // a monitor is added or removed, so the handler follows the surviving head.
  readonly property var panelScreen: root.QsWindow.window ? root.QsWindow.window.screen : null
  readonly property bool ipcOwner: !!panelScreen && Quickshell.screens.length > 0
    && panelScreen.name === Quickshell.screens[0].name

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color active: Color.bar.active
  readonly property color muted: Color.muted
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool alarming: comfy.state === "error" || comfy.state === "foreign-port" || comfy.state === "crashed"
  readonly property color stateColor: alarming ? root.urgent
    : (comfy.state === "generating" || comfy.state === "queued" ? root.active
    : (comfy.healthy ? root.foreground : root.muted))
  property int selectedAction: 0
  property bool cursorActive: false
  property bool previewExpanded: false
  property bool jobsExpanded: true
  property bool eventsExpanded: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function stateTitle() {
    if (comfy.state === "checking") return "Checking…"
    if (comfy.state === "starting") return "Starting…"
    if (comfy.state === "offline") return "Offline"
    if (comfy.state === "foreign-port") return "Port unavailable"
    if (comfy.state === "crashed") return "Server stopped unexpectedly"
    if (comfy.state === "generating") return "Generating"
    if (comfy.state === "queued") return "Queued"
    if (comfy.state === "idle") return "Ready"
    return "Needs attention"
  }
  function stateMeta() {
    if (comfy.healthy) return "ComfyUI " + comfy.version + (comfy.pendingCount > 0 ? " · " + comfy.pendingCount + " queued" : "")
    if (comfy.state === "starting") return "Waiting for the server to answer"
    if (comfy.state === "foreign-port") return "Another application owns the configured port"
    if (comfy.state === "crashed") return "Review Events for the last server messages"
    return comfy.serverUrl
  }
  function formatBytes(value) {
    var gib = Number(value || 0) / 1073741824
    return gib > 0 ? gib.toFixed(1) + " GiB" : "—"
  }
  function formatDuration(seconds) {
    if (!(seconds >= 0)) return "—"
    var hours = Math.floor(seconds / 3600)
    var minutes = Math.floor((seconds % 3600) / 60)
    var secs = Math.floor(seconds % 60)
    if (hours > 0) return hours + "h " + minutes + "m"
    if (minutes > 0) return minutes + "m " + secs + "s"
    return secs + "s"
  }
  function formatClock(milliseconds) {
    if (!(milliseconds > 0)) return "—"
    return new Date(milliseconds).toLocaleTimeString(Qt.locale(), "h:mm:ss AP")
  }
  function shortId(value) { return String(value || "").substring(0, 8) }
  function jobDetail(job) {
    var parts = []
    if (Number(job.nodeCount || 0) > 0) parts.push(job.nodeCount + " nodes")
    if (Number(job.outputNodeCount || 0) > 0) parts.push(job.outputNodeCount + " output nodes")
    if (Number(job.startedAt || 0) > 0) parts.push("started " + formatClock(Number(job.startedAt)))
    else if (Number(job.createdAt || 0) > 0) parts.push("queued " + formatClock(Number(job.createdAt)))
    return parts.join(" · ")
  }
  function allEvents() { return comfy.recentEvents.concat(comfy.logEvents).slice(0, 30) }
  function eventColor(level) { return level === "error" ? root.urgent : level === "warning" ? Color.accent : root.dim }
  function openOutput(output) { if (output && output.viewUrl) Qt.openUrlExternally(String(output.viewUrl)) }
  function actions() {
    var result = []
    if (comfy.healthy) result.push({ label: "Open ComfyUI", kind: "open" })
    else if (comfy.state !== "foreign-port" && comfy.state !== "starting") result.push({ label: "Start ComfyUI", kind: "start" })
    if (comfy.runningCount > 0) result.push({ label: "Interrupt generation", kind: "interrupt" })
    // A server this plugin started is stopped through its systemd unit; any
    // other healthy local server is stopped by signalling its listener. The
    // labels differ so the action never understates what it will end.
    if (comfy.owned) result.push({ label: "Stop managed server", kind: "stop" })
    else if (comfy.healthy) result.push({ label: "Stop ComfyUI server", kind: "stop" })
    if (root.alarming && comfy.acknowledgedState !== comfy.state) result.push({ label: "Dismiss alert", kind: "ack" })
    result.push({ label: "Refresh", kind: "refresh" })
    return result
  }
  function activateAction(index) {
    var list = actions()
    if (index < 0 || index >= list.length) return
    var kind = list[index].kind
    if (kind === "open") comfy.openServer()
    else if (kind === "start") comfy.startServer()
    else if (kind === "interrupt") comfy.interrupt()
    else if (kind === "stop") comfy.stopServer()
    else if (kind === "ack") comfy.acknowledge()
    else comfy.refresh()
  }

  onOpenedChanged: if (opened) {
    cursorActive = false; selectedAction = 0
    previewExpanded = comfy.boolSetting("showPreviewByDefault", false)
    comfy.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service { id: comfy; settings: root.settings }

  IpcHandler {
    enabled: root.ipcOwner
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { comfy.refresh(); return "ok" }
    function status(): string { return comfy.state }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        OpticalGlyph {
          anchors.fill: parent
          text: "C"
          fontFamily: root.fontFamily
          fontSize: Style.bar.iconFont
          color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        }
        BorderSurface {
          visible: root.alarming && comfy.acknowledgedState !== comfy.state
          width: Math.max(7, parent.width * 0.42)
          height: width
          radius: width / 2
          color: root.urgent
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          borderSpec: Border.flat(Color.popups.background, 1)
          Text {
            anchors.centerIn: parent
            text: "!"
            color: Color.background
            font.family: Style.font.family
            font.pixelSize: Math.max(6, parent.height * 0.72)
            font.bold: true
          }
        }
      }
    }
    active: comfy.state === "generating" || comfy.state === "queued"
    activeColor: root.active
    foreground: root.alarming ? root.urgent : (comfy.healthy ? root.foreground : root.muted)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton && comfy.healthy) comfy.openServer()
      else if (buttonCode === Qt.MiddleButton) comfy.refresh()
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
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy === 0) return
        root.cursorActive = true
        root.selectedAction = Math.max(0, Math.min(root.actions().length - 1, root.selectedAction + dy))
      }
      onActivateRequested: root.activateAction(root.selectedAction)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") comfy.refresh()
        else if ((text === "o" || text === "O") && comfy.healthy) comfy.openServer()
        else if (text === "p" || text === "P") root.previewExpanded = !root.previewExpanded
        else if (text === "j" || text === "J") root.jobsExpanded = !root.jobsExpanded
        else if (text === "e" || text === "E") root.eventsExpanded = !root.eventsExpanded
        else if ((text === "a" || text === "A") && root.alarming) comfy.acknowledge()
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: content
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: root.stateTitle()
            meta: root.stateMeta()
            foreground: root.stateColor
            fontFamily: root.fontFamily
          }

          Column {
            visible: comfy.state === "generating"
            width: parent.width
            spacing: Style.space(6)
            Item {
              width: parent.width
              height: progressLabel.implicitHeight
              Text {
                id: progressLabel
                text: comfy.progressMax > 0
                  ? (comfy.progressNode !== "" ? "Node " + comfy.progressNode + " · " : "") + Math.round(comfy.progress * 100) + "%"
                  : "Generating…"
                color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; anchors.left: parent.left
              }
              Text {
                text: comfy.pendingCount + " queued"; color: root.dim; font.family: root.fontFamily
                font.pixelSize: Style.font.caption; anchors.right: parent.right
              }
            }
            Rectangle {
              visible: comfy.progressMax > 0
              width: parent.width; height: Style.space(5); radius: height / 2
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
              Rectangle {
                width: parent.width * Math.max(0, Math.min(1, comfy.progress)); height: parent.height
                radius: parent.radius; color: Color.accent
                Behavior on width { NumberAnimation { duration: 120 } }
              }
            }
            Rectangle {
              id: indeterminateBar
              visible: comfy.progressMax === 0
              width: parent.width; height: Style.space(5); radius: height / 2
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
              clip: true
              Rectangle {
                id: runner
                width: parent.width * 0.3; height: parent.height
                radius: height / 2; color: Color.accent
                NumberAnimation on x {
                  loops: Animation.Infinite; duration: 1300
                  from: -runner.width; to: indeterminateBar.width
                  easing.type: Easing.InOutQuad
                }
              }
            }
            InfoRow { label: comfy.jobStartExact ? "Started" : "Observed"; value: root.formatClock(comfy.jobStartMs) }
            InfoRow { label: "Elapsed"; value: root.formatDuration(comfy.elapsedSeconds) }
            InfoRow { label: "Estimated left"; value: comfy.etaSeconds >= 0 ? "~" + root.formatDuration(comfy.etaSeconds) : "—" }
          }

          Text {
            visible: comfy.lastError !== ""; width: parent.width; text: comfy.lastError; color: root.urgent
            font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
          }
          Text {
            visible: comfy.actionStatus !== ""; width: parent.width; text: comfy.actionStatus; color: root.dim
            font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          Column {
            visible: comfy.healthy
            width: parent.width
            spacing: Style.space(7)
            InfoRow { label: "Queue"; value: comfy.runningCount + " running · " + comfy.pendingCount + " pending" }
            InfoRow { label: "Device"; value: comfy.device }
            InfoRow { label: "VRAM"; value: root.formatBytes(comfy.vramTotal - comfy.vramFree) + " / " + root.formatBytes(comfy.vramTotal) }
            InfoRow { label: "Ownership"; value: comfy.owned ? "Managed by this plugin" : "External server" }
          }

          Column {
            visible: comfy.jobs.length > 0
            width: parent.width
            spacing: Style.space(7)
            Button {
              width: parent.width; text: (root.jobsExpanded ? "▾  " : "▸  ") + "Jobs  ·  " + comfy.jobs.length
              bordered: true; foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.jobsExpanded = !root.jobsExpanded
            }
            Repeater {
              model: root.jobsExpanded ? comfy.jobs : []
              BorderSurface {
                required property var modelData
                required property int index
                width: parent.width; implicitHeight: jobColumn.implicitHeight + Style.space(16)
                radius: Style.cornerRadius
                color: Qt.rgba(root.stateColor.r, root.stateColor.g, root.stateColor.b, modelData.state === "running" ? 0.10 : 0.04)
                Column {
                  id: jobColumn
                  anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8); spacing: Style.space(3)
                  Text {
                    text: (modelData.state === "running" ? "● Running" : (index + 1) + "  Pending") + "  ·  " + root.shortId(modelData.promptId)
                    color: modelData.state === "running" ? Color.accent : root.foreground
                    font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true
                  }
                  Text {
                    text: root.jobDetail(modelData)
                    color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          Column {
            visible: comfy.outputs.length > 0
            width: parent.width
            spacing: Style.space(7)
            Button {
              width: parent.width
              text: (root.previewExpanded ? "▾  " : "▸  ") + "Latest output  ·  " + String(comfy.latestOutput.filename || "")
              bordered: true; foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.previewExpanded = !root.previewExpanded
            }
            BorderSurface {
              visible: root.previewExpanded
              width: parent.width
              implicitHeight: String(comfy.latestOutput.mediaKind || "") === "image" ? Style.space(190) : Style.space(72)
              radius: Style.cornerRadius
              clip: true
              Image {
                anchors.fill: parent
                visible: String(comfy.latestOutput.mediaKind || "") === "image"
                source: visible ? String(comfy.latestOutput.viewUrl || "") : ""
                fillMode: Image.PreserveAspectFit; asynchronous: true; cache: false
              }
              Text {
                anchors.centerIn: parent
                visible: String(comfy.latestOutput.mediaKind || "") !== "image"
                text: "Open " + String(comfy.latestOutput.mediaKind || "output")
                color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body
              }
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.openOutput(comfy.latestOutput) }
            }
            InfoRow { visible: root.previewExpanded; label: "Filename"; value: String(comfy.latestOutput.filename || "") }
            InfoRow { visible: root.previewExpanded; label: "Completed"; value: root.formatClock(Number(comfy.latestOutput.completedAt || 0)) }
            Button {
              visible: root.previewExpanded
              width: parent.width; text: "Open output"; bordered: true
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.openOutput(comfy.latestOutput)
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: root.actions()
              Button {
                required property var modelData
                required property int index
                width: parent.width; text: modelData.label
                selected: root.cursorActive && index === root.selectedAction; hasCursor: selected
                bordered: true; foreground: root.foreground; fontFamily: root.fontFamily; enabled: !comfy.busy
                onClicked: { root.cursorActive = true; root.selectedAction = index; root.activateAction(index) }
              }
            }
          }

          Column {
            visible: root.allEvents().length > 0
            width: parent.width
            spacing: Style.space(7)
            Button {
              width: parent.width; text: (root.eventsExpanded ? "▾  " : "▸  ") + "Events  ·  " + root.allEvents().length
              bordered: true; foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.eventsExpanded = !root.eventsExpanded
            }
            Repeater {
              model: root.eventsExpanded ? root.allEvents() : []
              Item {
                required property var modelData
                width: parent.width
                implicitHeight: eventText.implicitHeight + Style.space(8)
                Rectangle {
                  anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                  width: Style.space(3); radius: width / 2; color: root.eventColor(String(modelData.level || "info"))
                }
                Text {
                  id: eventText
                  anchors.left: parent.left; anchors.leftMargin: Style.space(10); anchors.right: parent.right
                  text: (modelData.timestamp ? root.formatClock(Number(modelData.timestamp)) + "  " : "") + String(modelData.message || "")
                  color: root.eventColor(String(modelData.level || "info")); font.family: root.fontFamily
                  font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
                }
              }
            }
          }
        }
      }
    }
  }

  component InfoRow: Item {
    property string label: ""
    property string value: ""
    width: parent ? parent.width : 0
    implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight)
    Text {
      id: labelText; text: parent.label; color: root.dim; font.family: root.fontFamily
      font.pixelSize: Style.font.caption; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      id: valueText; text: parent.value; color: root.foreground; font.family: root.fontFamily
      font.pixelSize: Style.font.caption; elide: Text.ElideMiddle; horizontalAlignment: Text.AlignRight
      anchors.left: labelText.right; anchors.leftMargin: Style.space(12); anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
    }
  }
}
