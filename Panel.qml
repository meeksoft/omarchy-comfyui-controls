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
  readonly property bool alarming: comfy.state === "error" || comfy.state === "foreign-port"
  property int selectedAction: 0
  property bool cursorActive: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function stateTitle() {
    if (comfy.state === "checking") return "Checking…"
    if (comfy.state === "offline") return "Offline"
    if (comfy.state === "foreign-port") return "Port unavailable"
    if (comfy.state === "generating") return "Generating"
    if (comfy.state === "queued") return "Queued"
    if (comfy.state === "idle") return "Ready"
    return "Needs attention"
  }
  function stateMeta() {
    if (comfy.healthy) return "ComfyUI " + comfy.version + (comfy.pendingCount > 0 ? " · " + comfy.pendingCount + " queued" : "")
    if (comfy.state === "foreign-port") return "Another application owns the configured port"
    return comfy.serverUrl
  }
  function formatBytes(value) {
    var gib = Number(value || 0) / 1073741824
    return gib > 0 ? gib.toFixed(1) + " GiB" : "—"
  }
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
    cursorActive = false; selectedAction = 0; comfy.refresh()
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
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: content
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: root.stateTitle()
            meta: root.stateMeta()
            foreground: root.alarming ? root.urgent : root.foreground
            fontFamily: root.fontFamily
          }

          BorderSurface {
            visible: comfy.previewUrl !== ""
            width: parent.width
            implicitHeight: Style.space(190)
            radius: Style.cornerRadius
            clip: true
            Image { anchors.fill: parent; source: comfy.previewUrl; fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: false }
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
                radius: parent.radius; color: root.foreground
                Behavior on width { NumberAnimation { duration: 120 } }
              }
            }
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
