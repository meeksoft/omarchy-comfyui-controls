import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.meeksoft.comfyui"
  ipcTarget: "io.github.meeksoft.comfyui"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool alarming: comfy.state === "error" || comfy.state === "foreign-port" || comfy.state === "crashed"
  readonly property color stateColor: alarming ? root.urgent
    : (comfy.state === "generating" || comfy.state === "queued" ? Color.accent : root.foreground)
  property int selectedAction: 0
  property bool cursorActive: false
  property bool previewExpanded: false
  property bool jobsExpanded: true
  property bool eventsExpanded: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function stateTitle() {
    if (comfy.state === "checking") return "Checking…"
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
  function allEvents() { return comfy.recentEvents.concat(comfy.logEvents).slice(0, 30) }
  function eventColor(level) { return level === "error" ? root.urgent : level === "warning" ? Color.accent : root.dim }
  function openOutput(output) { if (output && output.viewUrl) Qt.openUrlExternally(String(output.viewUrl)) }
  function actions() {
    var result = []
    if (comfy.healthy) result.push({ label: "Open ComfyUI", kind: "open" })
    else if (comfy.state !== "foreign-port") result.push({ label: "Start ComfyUI", kind: "start" })
    if (comfy.runningCount > 0) result.push({ label: "Interrupt generation", kind: "interrupt" })
    if (comfy.owned) result.push({ label: "Stop managed server", kind: "stop" })
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
    text: "C"
    active: comfy.state === "generating"
    activeColor: Color.accent
    foreground: root.alarming ? root.urgent : root.barForeground
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
            visible: comfy.state === "generating"
            width: parent.width
            spacing: Style.space(6)
            Item {
              width: parent.width
              height: progressLabel.implicitHeight
              Text {
                id: progressLabel
                text: comfy.progressMax > 0 ? "Node " + comfy.progressNode + " · " + Math.round(comfy.progress * 100) + "%" : "Node " + comfy.progressNode
                color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; anchors.left: parent.left
              }
              Text {
                text: comfy.pendingCount + " queued"; color: root.dim; font.family: root.fontFamily
                font.pixelSize: Style.font.caption; anchors.right: parent.right
              }
            }
            Rectangle {
              width: parent.width; height: Style.space(5); radius: height / 2
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
              Rectangle {
                width: parent.width * Math.max(0, Math.min(1, comfy.progress)); height: parent.height
                radius: parent.radius; color: Color.accent
                Behavior on width { NumberAnimation { duration: 120 } }
              }
            }
            InfoRow { label: comfy.jobStartExact ? "Started" : "Observed"; value: root.formatClock(comfy.jobStartMs) }
            InfoRow { label: "Elapsed"; value: root.formatDuration(comfy.elapsedSeconds) }
            InfoRow { label: "Estimated left"; value: comfy.etaSeconds >= 0 ? "~" + root.formatDuration(comfy.etaSeconds) : "Calculating…" }
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
                    text: modelData.nodeCount + " nodes · " + modelData.outputNodeCount + " output nodes"
                    color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                  }
                }
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

          Text {
            visible: comfy.lastError !== ""; width: parent.width; text: comfy.lastError; color: root.urgent
            font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
          }
          Text {
            visible: comfy.actionStatus !== ""; width: parent.width; text: comfy.actionStatus; color: root.dim
            font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
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
