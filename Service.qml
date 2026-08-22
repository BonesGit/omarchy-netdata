import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Polls a remote Netdata v3 endpoint for GPU utilization. Lives as a
// hidden child of the bar widget so the pill stays live even while the
// popup is closed; the panel asks it for a history window on demand.
Item {
  id: root
  width: 0
  height: 0
  visible: false

  property var settings: ({})

  property bool connected: false
  property var currentValue: null
  property var points: []
  property string lastError: ""
  property string nodeName: ""
  property string units: "%"
  property real dbFirst: 0
  property real dbLast: 0
  property real lastSampleAt: 0
  property bool polling: true
  property int failCount: 0
  property bool countedThisPoll: false

  readonly property string hostRaw: Model.configuredHost(settings)
  readonly property string contextId: Model.configuredContext(settings)
  readonly property string hostLabel: Model.hostLabel(hostRaw)
  readonly property int refreshMs: Model.configuredRefreshMs(settings)
  readonly property int retryAttempts: Model.configuredRetryAttempts(settings)
  readonly property string status: Model.statusKey(connected, currentValue)

  signal seriesUpdated()

  function togglePolling() {
    polling = !polling
    failCount = 0
    if (polling) refreshLatest()
  }

  function refreshLatest() {
    if (latestProc.running) return
    countedThisPoll = false
    latestProc.command = ["curl", "-fsS", "--max-time", "4", "--max-filesize", String(Model.maxLatestResponseBytes()), Model.latestUrl(hostRaw, contextId)]
    latestProc.running = true
  }

  function refreshHistory(startSec, endSec, pointsWanted) {
    if (historyProc.running) {
      pendingHistory = { start: startSec, end: endSec, points: pointsWanted }
      return
    }
    pendingHistory = null
    historyProc.command = ["curl", "-fsS", "--max-time", "6", "--max-filesize", String(Model.maxHistoryResponseBytes()), Model.historyUrl(hostRaw, contextId, startSec, endSec, pointsWanted)]
    historyProc.running = true
  }

  function applyLatest(raw) {
    if (!Model.responseWithinLimit(raw, Model.maxLatestResponseBytes())) {
      markDisconnected("latest response too large")
      return
    }
    var payload = Model.parsePayload(raw)
    if (!payload || !payload.result) {
      markDisconnected("empty latest payload")
      return
    }
    var series = Model.parseSeries(payload)
    var meta = Model.parseMeta(payload)
    var value = Model.latestValue(series)
    connected = true
    lastError = ""
    failCount = 0
    currentValue = value
    if (meta.nodeName) nodeName = meta.nodeName
    if (meta.units) units = meta.units
    if (isFinite(meta.dbFirst)) dbFirst = meta.dbFirst
    if (isFinite(meta.dbLast)) dbLast = meta.dbLast
    if (series.length) {
      var last = series[series.length - 1]
      lastSampleAt = last.t
      points = Model.prunePoints(Model.mergePoint(points, last.t, last.v), last.t)
    }
    seriesUpdated()
  }

  function applyHistory(raw) {
    if (!Model.responseWithinLimit(raw, Model.maxHistoryResponseBytes())) {
      lastError = "history response too large"
      return
    }
    var payload = Model.parsePayload(raw)
    if (!payload || !payload.result) {
      lastError = "empty history payload"
      return
    }
    var series = Model.parseSeries(payload)
    var meta = Model.parseMeta(payload)
    connected = true
    lastError = ""
    failCount = 0
    if (meta.nodeName) nodeName = meta.nodeName
    if (meta.units) units = meta.units
    if (isFinite(meta.dbFirst)) dbFirst = meta.dbFirst
    if (isFinite(meta.dbLast)) dbLast = meta.dbLast
    points = series
    var value = Model.latestValue(series)
    if (value !== null) currentValue = value
    if (series.length) lastSampleAt = series[series.length - 1].t
    seriesUpdated()
  }

  function markDisconnected(reason) {
    connected = false
    currentValue = null
    lastError = reason || "unreachable"
    if (!polling || countedThisPoll) return
    countedThisPoll = true
    failCount += 1
    if (failCount >= retryAttempts) {
      polling = false
      failCount = 0
    }
  }

  property var pendingHistory: null

  onHostRawChanged: {
    points = []
    currentValue = null
    connected = false
    lastError = ""
    failCount = 0
    refreshLatest()
  }

  onContextIdChanged: {
    points = []
    currentValue = null
    failCount = 0
    refreshLatest()
  }

  Timer {
    id: pollTimer
    interval: root.refreshMs
    running: root.polling
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshLatest()
  }

  Process {
    id: latestProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyLatest(text)
    }
    onExited: function(code) {
      if (code !== 0) root.markDisconnected("latest fetch failed")
    }
  }

  Process {
    id: historyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyHistory(text)
    }
    onExited: function(code) {
      if (code !== 0) root.lastError = "history fetch failed"
      if (root.pendingHistory) {
        var req = root.pendingHistory
        root.pendingHistory = null
        Qt.callLater(function() { root.refreshHistory(req.start, req.end, req.points) })
      }
    }
  }
}
