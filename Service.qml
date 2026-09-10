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
  property var jobs: []
  property var outputs: []
  property var recentEvents: []
  property var logEvents: []
  property string serverUrl: ""
  property string progressNode: ""
  property int progressValue: 0
  property int progressMax: 0
  property string actionStatus: ""
  property string lastError: ""
  property bool refreshing: false
  property double nowMs: Date.now()
  property double jobStartMs: 0
  property bool jobStartExact: false
  property double nodeStartMs: 0
  property double lastProgressMs: 0
  property int lastProgressValue: 0
  property real secondsPerStep: 0
  property int journalEtaSeconds: -1
  property string prevState: ""
  property string acknowledgedState: ""
  property double lastAlarmNotifyMs: Date.now()
  property double lastFailureNotifyMs: 0

  readonly property bool busy: actionProcess.running
  readonly property var latestOutput: outputs.length > 0 ? outputs[0] : ({})
  readonly property real progress: progressMax > 0 ? progressValue / progressMax : 0
  readonly property int elapsedSeconds: jobStartMs > 0 ? Math.max(0, Math.floor((nowMs - jobStartMs) / 1000)) : 0
  readonly property int nodeElapsedSeconds: nodeStartMs > 0 ? Math.max(0, Math.floor((nowMs - nodeStartMs) / 1000)) : 0
  readonly property int etaSeconds: lastProgressMs > 0 && nowMs - lastProgressMs < 5000
    ? (secondsPerStep > 0 && progressMax > progressValue
       ? Math.max(0, Math.round(secondsPerStep * (progressMax - progressValue))) : -1)
    : journalEtaSeconds
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
  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    return value === true || String(value).toLowerCase() === "true"
  }
  function commonArgs(command) {
    return [helperPath, command, "--host", host, "--port", String(port),
            "--log-path", String(setting("logPath", ""))]
  }
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
  function stopServer() { if (owned || healthy) runAction(commonArgs("stop"), "Stopping ComfyUI…") }
  function interrupt() { if (healthy && runningCount > 0) runAction(commonArgs("interrupt"), "Requesting interrupt…") }
  function openServer() { if (healthy && serverUrl !== "") Qt.openUrlExternally(serverUrl) }

  function applyStatus(raw) {
    var parsed
    try { parsed = JSON.parse(String(raw || "{}")) }
    catch (error) { lastError = "Could not understand the controller response."; return }
    state = String(parsed.state || "error"); healthy = parsed.healthy === true; owned = parsed.owned === true
    if (state !== acknowledgedState) acknowledgedState = ""
    runningCount = Number(parsed.running || 0); pendingCount = Number(parsed.pending || 0)
    version = String(parsed.version || ""); device = String(parsed.device || "")
    vramTotal = Number(parsed.vramTotal || 0); vramFree = Number(parsed.vramFree || 0)
    jobs = parsed.jobs || []; outputs = parsed.outputs || []
    recentEvents = parsed.recentEvents || []; logEvents = parsed.logEvents || []
    serverUrl = String(parsed.url || ("http://" + host + ":" + port))
    previewUrl = outputs.length > 0 ? String(outputs[0].viewUrl || "") : ""
    if (state === "generating") {
      var runningJob = null
      for (var i = 0; i < jobs.length; i++)
        if (jobs[i].state === "running") { runningJob = jobs[i]; break }
      var exactStart = runningJob ? Number(runningJob.startedAt || 0) : 0
      if (exactStart > 0) { jobStartMs = exactStart; jobStartExact = true }
      else if (jobStartMs === 0) { jobStartMs = Date.now(); jobStartExact = false }
      var watcherFresh = lastProgressMs > 0 && Date.now() - lastProgressMs < 5000
      if (watcherFresh) journalEtaSeconds = -1
      else if (parsed.progress && Number(parsed.progress.max || 0) > 0) {
        progressNode = ""
        progressValue = Number(parsed.progress.value || 0)
        progressMax = Number(parsed.progress.max || 0)
        journalEtaSeconds = Number(parsed.progress.etaSeconds || -1)
      } else {
        progressNode = ""; progressValue = 0; progressMax = 0; journalEtaSeconds = -1
      }
    } else if (state !== "generating") {
      progressNode = ""; progressValue = 0; progressMax = 0
      jobStartMs = 0; nodeStartMs = 0; secondsPerStep = 0; lastProgressMs = 0; lastProgressValue = 0
      journalEtaSeconds = -1
    }
    if (parsed.ok === false) lastError = String(parsed.message || "Controller error")
    else if (state !== "error" && state !== "foreign-port") lastError = ""
    checkAlarmNotify(); prevState = state
    updateWatcher()
  }
  function applyEvent(raw) {
    var event
    try { event = JSON.parse(String(raw || "{}")) } catch (error) { return }
    if (event.type === "progress") {
      var eventNode = String(event.node || "")
      var value = Number(event.value || 0)
      var moment = Date.now()
      if (eventNode !== progressNode) {
        progressNode = eventNode; nodeStartMs = moment; secondsPerStep = 0; lastProgressMs = 0; lastProgressValue = 0
      }
      if (lastProgressMs > 0 && value > lastProgressValue) {
        var sample = (moment - lastProgressMs) / 1000 / (value - lastProgressValue)
        secondsPerStep = secondsPerStep > 0 ? secondsPerStep * 0.7 + sample * 0.3 : sample
      }
      progressValue = value; progressMax = Number(event.max || 0)
      lastProgressMs = moment; lastProgressValue = value; state = "generating"
      if (jobStartMs === 0) { jobStartMs = moment; jobStartExact = false }
    } else if (event.type === "executing") {
      var nextNode = String(event.node || "")
      if (nextNode !== "" && nextNode !== progressNode) {
        progressNode = nextNode; nodeStartMs = Date.now(); progressValue = 0; progressMax = 0
        secondsPerStep = 0; lastProgressMs = 0; lastProgressValue = 0
      }
      if (nextNode === "") refreshSoon.restart()
    } else if (event.type === "execution_start") {
      jobStartMs = Number(event.timestamp || Date.now()); jobStartExact = true; state = "generating"
    } else if (event.type === "execution_success") {
      refreshSoon.restart()
    } else if (event.type === "status" && Number(event.queueRemaining || 0) === 0) refreshSoon.restart()
    else if (event.type === "execution_error" || event.type === "execution_interrupted") {
      lastError = String(event.message || "ComfyUI execution stopped")
      recentEvents = [{ level: event.type === "execution_error" ? "error" : "warning",
                        kind: event.type, timestamp: Number(event.timestamp || Date.now()),
                        promptId: String(event.promptId || ""), message: lastError }].concat(recentEvents).slice(0, 20)
      if (event.type === "execution_error" && Date.now() - lastFailureNotifyMs > 600000) {
        lastFailureNotifyMs = Date.now()
        notify("normal", "ComfyUI generation failed", lastError !== "" ? lastError.slice(0, 200) : "A queued prompt failed.")
      }
      refreshSoon.restart()
    }
  }
  function updateWatcher() {
    if (healthy && !watchProcess.running) { watchProcess.command = commonArgs("watch"); watchProcess.running = true }
    else if (!healthy && watchProcess.running) watchProcess.running = false
  }
  function notify(urgency, summary, body) {
    if (notifyProcess.running) return
    notifyProcess.command = ["notify-send", "-u", urgency, "-a", "ComfyUI Control", summary, body]
    notifyProcess.running = true
  }
  function acknowledge() { acknowledgedState = state }
  function checkAlarmNotify() {
    if (state !== "error" && state !== "crashed") return
    if (state === acknowledgedState) return
    var now = Date.now()
    var transition = prevState !== "" && prevState !== "checking" && prevState !== state
    if (transition || now - lastAlarmNotifyMs > 600000) {
      lastAlarmNotifyMs = now
      if (state === "crashed")
        notify("critical", "ComfyUI server stopped", "The managed server exited unexpectedly. Open the panel and check Events.")
      else
        notify("critical", "ComfyUI needs attention", lastError !== "" ? lastError : "The controller reported an error.")
    }
  }

  Timer { interval: root.refreshIntervalSec * 1000; repeat: true; running: true; triggeredOnStart: true; onTriggered: root.refresh() }
  Timer { interval: 1000; repeat: true; running: true; onTriggered: root.nowMs = Date.now() }
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
  Process { id: notifyProcess; command: [] }
}
