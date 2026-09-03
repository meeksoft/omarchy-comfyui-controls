import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root
  property var settings: ({})
  property string state: "checking"
  property bool healthy: false
  property bool owned: false
  property int runningCount: 0
  property int pendingCount: 0
  property string version: ""
  property string device: ""
  property double vramTotal: 0
  property double vramFree: 0
  property string previewUrl: ""
  property string serverUrl: ""
  property string progressNode: ""
  property int progressValue: 0
  property int progressMax: 0
  property string actionStatus: ""
  property string lastError: ""
  property bool refreshing: false

  readonly property bool busy: actionProcess.running
  readonly property real progress: progressMax > 0 ? progressValue / progressMax : 0
  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("bin/comfyui-control").toString().replace(/^file:\/\//, ""))
  readonly property string host: stringSetting("host", "127.0.0.1")
  readonly property int port: intSetting("port", 8188, 1, 65535)
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 2, 1, 60)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }
  function stringSetting(name, fallback) { return String(setting(name, fallback) || fallback) }
  function intSetting(name, fallback, min, max) {
    var value = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(value)) value = fallback
    return Math.max(min, Math.min(max, value))
  }
  function commonArgs(command) { return [helperPath, command, "--host", host, "--port", String(port)] }
  function refresh() {
    if (statusProcess.running) return
    refreshing = true; statusProcess.command = commonArgs("status"); statusProcess.running = true
  }
  function runAction(command, message) {
    if (busy) return
    actionStatus = message; lastError = ""; actionProcess.command = command; actionProcess.running = true
  }
  function startServer() {
    var command = commonArgs("start")
    command.push("--root", String(setting("comfyRoot", "")))
    command.push("--python", String(setting("pythonPath", "")))
    runAction(command, "Starting ComfyUI…")
  }
  function stopServer() { if (owned) runAction(commonArgs("stop"), "Stopping ComfyUI…") }
  function interrupt() { if (healthy && runningCount > 0) runAction(commonArgs("interrupt"), "Requesting interrupt…") }
  function openServer() { if (healthy && serverUrl !== "") Qt.openUrlExternally(serverUrl) }

  function applyStatus(raw) {
    var parsed
    try { parsed = JSON.parse(String(raw || "{}")) }
    catch (error) { lastError = "Could not understand the controller response."; return }
    state = String(parsed.state || "error"); healthy = parsed.healthy === true; owned = parsed.owned === true
    runningCount = Number(parsed.running || 0); pendingCount = Number(parsed.pending || 0)
    version = String(parsed.version || ""); device = String(parsed.device || "")
    vramTotal = Number(parsed.vramTotal || 0); vramFree = Number(parsed.vramFree || 0)
    serverUrl = String(parsed.url || ("http://" + host + ":" + port))
    if (parsed.previewUrl) previewUrl = String(parsed.previewUrl)
    if (state !== "generating") { progressNode = ""; progressValue = 0; progressMax = 0 }
    if (parsed.ok === false) lastError = String(parsed.message || "Controller error")
    else if (state !== "error" && state !== "foreign-port") lastError = ""
    updateWatcher()
  }
  function applyEvent(raw) {
    var event
    try { event = JSON.parse(String(raw || "{}")) } catch (error) { return }
    if (event.type === "progress") {
      progressValue = Number(event.value || 0); progressMax = Number(event.max || 0)
      progressNode = String(event.node || ""); state = "generating"
    } else if (event.type === "executing") {
      progressNode = String(event.node || ""); if (progressNode === "") refreshSoon.restart()
    } else if (event.type === "status" && Number(event.queueRemaining || 0) === 0) refreshSoon.restart()
    else if (event.type === "execution_error" || event.type === "execution_interrupted") {
      lastError = String(event.message || "ComfyUI execution stopped"); refreshSoon.restart()
    }
  }
  function updateWatcher() {
    if (healthy && !watchProcess.running) { watchProcess.command = commonArgs("watch"); watchProcess.running = true }
    else if (!healthy && watchProcess.running) watchProcess.running = false
  }

  Timer { interval: root.refreshIntervalSec * 1000; repeat: true; running: true; triggeredOnStart: true; onTriggered: root.refresh() }
  Timer { id: refreshSoon; interval: 300; onTriggered: root.refresh() }
  Timer { id: reconnectTimer; interval: 1500; onTriggered: root.updateWatcher() }
  Timer { id: actionMessageTimer; interval: 3000; onTriggered: root.actionStatus = "" }

  Process {
    id: statusProcess; command: []
    stdout: StdioCollector { id: statusOutput; waitForEnd: true }
    onExited: function(exitCode) { root.refreshing = false; root.applyStatus(statusOutput.text) }
  }
  Process {
    id: actionProcess; command: []
    stdout: StdioCollector { id: actionOutput; waitForEnd: true }
    stderr: StdioCollector { id: actionError; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = null
      try { parsed = JSON.parse(String(actionOutput.text || "")) } catch (error) {}
      if (parsed && parsed.message) root.actionStatus = String(parsed.message)
      if (exitCode !== 0) root.lastError = parsed && parsed.message ? String(parsed.message) : String(actionError.text || "Action failed").trim()
      actionMessageTimer.restart(); refreshSoon.restart()
    }
  }
  Process {
    id: watchProcess; command: []
    stdout: SplitParser { onRead: function(data) { root.applyEvent(data) } }
    onExited: function(exitCode) { if (root.healthy) reconnectTimer.restart() }
  }
}
