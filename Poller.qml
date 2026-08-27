import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Polls a remote Netdata v3 endpoint for GPU utilization. Created by
// the plugin service registry (one per host+context group) so dual-
// monitor pills share connected/polling state. The panel asks it for a
// history window on demand.
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
  property string chartTitle: Model.defaultTitle()
  property string units: "%"
  property real dbFirst: 0
  property real dbLast: 0
  property real lastSampleAt: 0
  property bool polling: true
  property int failCount: 0
  property bool countedThisPoll: false
  property bool latestAborted: false
  property bool historyAborted: false
  property bool tempAborted: false
  property bool tempHistoryAborted: false
  property bool latestSawData: false
  property bool historySawData: false
  property bool tempSawData: false
  property bool tempHistorySawData: false
  property var tempValue: null
  property var tempPoints: []
  property var series: []
  property var tempSeries: []
  property var splitValues: []
  property var splitTempValues: []
  property string tempUnits: "°C"
  property string tempTitle: Model.defaultTempTitle()

  readonly property string hostRaw: Model.configuredHost(settings)
  readonly property string contextId: Model.configuredContext(settings)
  readonly property var tempQuery: Model.configuredTempQuery(settings)
  readonly property string tempContextId: tempQuery.context
  readonly property string hostLabel: Model.hostLabel(hostRaw)
  readonly property int refreshMs: Model.configuredRefreshMs(settings)
  readonly property int retryAttempts: Model.configuredRetryAttempts(settings)
  readonly property bool splitEnabled: Model.configuredSplit(settings)
  readonly property string status: Model.statusKey(connected, currentValue)

  signal seriesUpdated()

  function togglePolling() {
    polling = !polling
    failCount = 0
    if (polling) refreshLatest()
  }

  function abortIfTooLarge(proc, data, maxBytes) {
    if (!Model.collectorOverLimit(data, maxBytes)) return false
    if (proc.running) proc.running = false
    return true
  }

  function wrapSingle(points) {
    return [{ name: "", key: "", points: points }]
  }

  function parseChartSeries(payload) {
    if (splitEnabled) return Model.parseSeriesSplit(payload)
    return wrapSingle(Model.parseSeries(payload))
  }

  function parseTempChartSeries(payload) {
    var parsed = parseChartSeries(payload)
    if (series.length) return Model.alignSeriesByKey(series, parsed)
    return parsed
  }

  function lastRow(parsed) {
    if (!parsed || !parsed.length || !parsed[0].points || !parsed[0].points.length)
      return null
    var lastT = parsed[0].points[parsed[0].points.length - 1].t
    var values = []
    for (var i = 0; i < parsed.length; i++) {
      var pts = parsed[i].points
      values.push(pts && pts.length ? pts[pts.length - 1].v : null)
    }
    return { t: lastT, values: values }
  }

  function replaceWithLastSample(parsed) {
    var last = lastRow(parsed)
    if (!last) return []
    var next = []
    for (var i = 0; i < parsed.length; i++) {
      next.push({
        name: parsed[i].name,
        key: parsed[i].key,
        points: [{ t: last.t, v: last.values[i] }]
      })
    }
    return next
  }

  function adoptSeries(next) {
    series = next
    points = next.length ? next[0].points : []
    splitValues = Model.latestValuePerSeries(next)
    if (tempSeries.length) adoptTempSeries(tempSeries)
  }

  function adoptTempSeries(next) {
    var aligned = series.length ? Model.alignSeriesByKey(series, next) : next
    tempSeries = aligned
    tempPoints = aligned.length ? aligned[0].points : []
    splitTempValues = Model.latestValuePerSeries(aligned)
  }

  function clearSeriesState() {
    series = []
    tempSeries = []
    points = []
    tempPoints = []
    splitValues = []
    splitTempValues = []
    currentValue = null
    tempValue = null
  }

  function refreshLatest() {
    if (latestProc.running) {
      refreshTemp()
      return
    }
    countedThisPoll = false
    latestAborted = false
    latestSawData = false
    latestProc.command = ["curl", "-fsS", "--max-time", "4", "--max-filesize", String(Model.maxLatestResponseBytes()), Model.latestUrl(hostRaw, contextId, Model.queryExtra(null, splitEnabled))]
    latestProc.running = true
    refreshTemp()
  }

  function refreshTemp() {
    if (!tempContextId) {
      tempValue = null
      return
    }
    if (tempProc.running) return
    tempAborted = false
    tempSawData = false
    tempProc.command = ["curl", "-fsS", "--max-time", "4", "--max-filesize", String(Model.maxLatestResponseBytes()), Model.latestUrl(hostRaw, tempContextId, Model.queryExtra(tempQuery, splitEnabled))]
    tempProc.running = true
  }

  function refreshHistory(startSec, endSec, pointsWanted) {
    if (historyProc.running) {
      pendingHistory = { start: startSec, end: endSec, points: pointsWanted }
    } else {
      pendingHistory = null
      historyAborted = false
      historySawData = false
      historyProc.command = ["curl", "-fsS", "--max-time", "6", "--max-filesize", String(Model.maxHistoryResponseBytes()), Model.historyUrl(hostRaw, contextId, startSec, endSec, pointsWanted, Model.queryExtra(null, splitEnabled))]
      historyProc.running = true
    }
    refreshTempHistory(startSec, endSec, pointsWanted)
  }

  function refreshTempHistory(startSec, endSec, pointsWanted) {
    if (!tempContextId) {
      tempPoints = []
      return
    }
    if (tempHistoryProc.running) {
      pendingTempHistory = { start: startSec, end: endSec, points: pointsWanted }
      return
    }
    pendingTempHistory = null
    tempHistoryAborted = false
    tempHistorySawData = false
    tempHistoryProc.command = ["curl", "-fsS", "--max-time", "6", "--max-filesize", String(Model.maxHistoryResponseBytes()), Model.historyUrl(hostRaw, tempContextId, startSec, endSec, pointsWanted, Model.queryExtra(tempQuery, splitEnabled))]
    tempHistoryProc.running = true
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
    var parsed = parseChartSeries(payload)
    var meta = Model.parseMeta(payload)
    var values = Model.latestValuePerSeries(parsed)
    var value = Model.maxOf(values)
    if (value === null) {
      markDisconnected("no latest value")
      return
    }
    connected = true
    lastError = ""
    failCount = 0
    currentValue = value
    splitValues = values
    if (meta.nodeName) nodeName = meta.nodeName
    if (meta.title) chartTitle = meta.title
    if (meta.units) units = meta.units
    if (isFinite(meta.dbFirst)) dbFirst = meta.dbFirst
    if (isFinite(meta.dbLast)) dbLast = meta.dbLast
    var last = lastRow(parsed)
    if (last) {
      lastSampleAt = last.t
      var next = series.length !== parsed.length
        ? replaceWithLastSample(parsed)
        : Model.mergeSeriesPoint(series, last.t, last.values)
      adoptSeries(Model.pruneSeries(next, last.t))
      splitValues = values
    }
    seriesUpdated()
  }

  function applyTemp(raw) {
    if (!Model.responseWithinLimit(raw, Model.maxLatestResponseBytes())) {
      tempValue = null
      return
    }
    var payload = Model.parsePayload(raw)
    if (!payload || !payload.result) {
      tempValue = null
      return
    }
    var parsed = parseTempChartSeries(payload)
    var meta = Model.parseMeta(payload)
    var values = Model.latestValuePerSeries(parsed)
    var value = Model.maxOf(values)
    if (value !== null) tempValue = value
    splitTempValues = values
    if (meta.units) tempUnits = meta.units
    var last = lastRow(parsed)
    if (last) {
      var next = tempSeries.length !== parsed.length
        ? replaceWithLastSample(parsed)
        : Model.mergeSeriesPoint(tempSeries, last.t, last.values)
      adoptTempSeries(Model.pruneSeries(next, last.t))
      splitTempValues = values
    }
  }

  function applyTempHistory(raw) {
    if (!Model.responseWithinLimit(raw, Model.maxHistoryResponseBytes()))
      return
    var payload = Model.parsePayload(raw)
    if (!payload || !payload.result)
      return
    var parsed = parseTempChartSeries(payload)
    var meta = Model.parseMeta(payload)
    var values = Model.latestValuePerSeries(parsed)
    var value = Model.maxOf(values)
    if (value !== null) tempValue = value
    splitTempValues = values
    if (meta.units) tempUnits = meta.units
    adoptTempSeries(Model.pruneSeries(parsed))
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
    var parsed = parseChartSeries(payload)
    var meta = Model.parseMeta(payload)
    var values = Model.latestValuePerSeries(parsed)
    var value = Model.maxOf(values)
    lastError = ""
    if (value !== null) {
      connected = true
      failCount = 0
      currentValue = value
    }
    splitValues = values
    if (meta.nodeName) nodeName = meta.nodeName
    if (meta.title) chartTitle = meta.title
    if (meta.units) units = meta.units
    if (isFinite(meta.dbFirst)) dbFirst = meta.dbFirst
    if (isFinite(meta.dbLast)) dbLast = meta.dbLast
    adoptSeries(Model.pruneSeries(parsed))
    if (parsed.length && parsed[0].points && parsed[0].points.length)
      lastSampleAt = parsed[0].points[parsed[0].points.length - 1].t
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
  property var pendingTempHistory: null

  onHostRawChanged: {
    clearSeriesState()
    connected = false
    lastError = ""
    failCount = 0
    chartTitle = Model.defaultTitle()
    tempTitle = Model.defaultTempTitle()
    refreshLatest()
  }

  onContextIdChanged: {
    clearSeriesState()
    connected = false
    failCount = 0
    chartTitle = Model.defaultTitle()
    refreshLatest()
  }

  onTempContextIdChanged: {
    tempValue = null
    tempPoints = []
    tempSeries = []
    splitTempValues = []
    if (polling) refreshTemp()
  }

  onSplitEnabledChanged: {
    clearSeriesState()
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
      waitForEnd: false
      onDataChanged: {
        root.latestSawData = true
        if (root.abortIfTooLarge(latestProc, data, Model.maxLatestResponseBytes()))
          root.latestAborted = true
      }
      onStreamFinished: {
        if (root.latestAborted) {
          root.markDisconnected("latest response too large")
          return
        }
        // waitForEnd:false leaves mData uncleared; do not apply a prior run.
        root.applyLatest(root.latestSawData ? text : "")
      }
    }
    onExited: function(code) {
      if (root.latestAborted) return
      if (code !== 0) root.markDisconnected("latest fetch failed")
    }
  }

  Process {
    id: tempProc
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: {
        root.tempSawData = true
        if (root.abortIfTooLarge(tempProc, data, Model.maxLatestResponseBytes()))
          root.tempAborted = true
      }
      onStreamFinished: {
        if (root.tempAborted)
          return
        // waitForEnd:false leaves mData uncleared; do not apply a prior run.
        root.applyTemp(root.tempSawData ? text : "")
      }
    }
  }

  Process {
    id: historyProc
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: {
        root.historySawData = true
        if (root.abortIfTooLarge(historyProc, data, Model.maxHistoryResponseBytes()))
          root.historyAborted = true
      }
      onStreamFinished: {
        if (root.historyAborted) {
          root.lastError = "history response too large"
          return
        }
        // waitForEnd:false leaves mData uncleared; do not apply a prior run.
        root.applyHistory(root.historySawData ? text : "")
      }
    }
    onExited: function(code) {
      if (!root.historyAborted && code !== 0) root.lastError = "history fetch failed"
      if (root.pendingHistory) {
        var req = root.pendingHistory
        root.pendingHistory = null
        Qt.callLater(function() { root.refreshHistory(req.start, req.end, req.points) })
      }
    }
  }

  Process {
    id: tempHistoryProc
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: {
        root.tempHistorySawData = true
        if (root.abortIfTooLarge(tempHistoryProc, data, Model.maxHistoryResponseBytes()))
          root.tempHistoryAborted = true
      }
      onStreamFinished: {
        if (root.tempHistoryAborted)
          return
        // waitForEnd:false leaves mData uncleared; do not apply a prior run.
        root.applyTempHistory(root.tempHistorySawData ? text : "")
      }
    }
    onExited: function(code) {
      if (root.pendingTempHistory) {
        var req = root.pendingTempHistory
        root.pendingTempHistory = null
        Qt.callLater(function() { root.refreshTempHistory(req.start, req.end, req.points) })
      }
    }
  }
}
