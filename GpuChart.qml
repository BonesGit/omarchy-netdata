import QtQuick
import qs.Commons
import "Model.js" as Model

// Interactive GPU utilization chart. Wheel zooms the time window around
// the cursor; drag pans along X. Painting stays on a Canvas so the rest
// of the panel can keep using stock Omarchy surfaces.
Item {
  id: root

  property var points: []
  property real windowStart: 0
  property real windowEnd: 0
  property color lineColor: Color.accent
  property color gridColor: Color.muted
  property color textColor: Color.foreground
  property color crosshairColor: Color.foreground
  property string fontFamily: Style.font.family
  property bool live: true
  property bool autoScale: false
  property bool compact: false
  property bool temperature: false
  property real yMin: 0
  property real yMax: 100

  readonly property real windowSpan: Math.max(1, windowEnd - windowStart)
  readonly property var plotPoints: Model.visiblePoints(points, windowStart, windowEnd)
  readonly property real axisBand: compact ? Style.space(4) : Style.space(18)
  readonly property real plotHeight: Math.max(1, height - axisBand)
  readonly property var valueRange: {
    if (!autoScale) return { min: yMin, max: yMax }
    var lo = Infinity
    var hi = -Infinity
    var pts = plotPoints
    for (var i = 0; i < pts.length; i++) {
      var n = Number(pts[i].v)
      if (!isFinite(n)) continue
      if (n < lo) lo = n
      if (n > hi) hi = n
    }
    if (!isFinite(lo)) return { min: yMin, max: yMax }
    if (lo === hi) {
      lo = Math.max(0, lo - 5)
      hi = hi + 5
    } else {
      var pad = Math.max(2, (hi - lo) * 0.15)
      lo -= pad
      hi += pad
    }
    return { min: lo, max: hi }
  }

  property real hoverX: -1
  property real hoverT: NaN
  property var hoverV: null
  property real wheelAcc: 0

  signal zoomRequested(real factor, real anchorSec)
  signal panRequested(real deltaSec)

  function xForTime(t) {
    return ((t - windowStart) / windowSpan) * canvas.width
  }

  function timeForX(x) {
    return windowStart + (x / Math.max(1, canvas.width)) * windowSpan
  }

  function yForValue(v) {
    var n = Number(v)
    if (!isFinite(n)) return canvas.height
    var lo = Number(valueRange.min)
    var hi = Number(valueRange.max)
    var span = hi - lo
    if (!isFinite(span) || span <= 0) span = 1
    var t = (n - lo) / span
    t = Math.max(0, Math.min(1, t))
    return canvas.height - axisBand - t * plotHeight
  }

  function yTicks() {
    if (!autoScale) return [0, 25, 50, 75, 100]
    var lo = Number(valueRange.min)
    var hi = Number(valueRange.max)
    if (!isFinite(lo) || !isFinite(hi)) return []
    if (compact) return [lo, hi]
    return [lo, (lo + hi) / 2, hi]
  }

  function hoverText() {
    var value = temperature ? Model.formatTemp(hoverV) : (Model.formatPercent(hoverV) + "%")
    return value + "  " + Model.formatHoverTick(hoverT, windowSpan)
  }

  function updateHover(x) {
    if (x < 0 || x > width || plotPoints.length === 0) {
      hoverX = -1
      hoverT = NaN
      hoverV = null
      return
    }
    hoverX = x
    hoverT = timeForX(x)
    hoverV = Model.interpolate(plotPoints, hoverT)
    canvas.requestPaint()
  }

  onPointsChanged: canvas.requestPaint()
  onWindowStartChanged: canvas.requestPaint()
  onWindowEndChanged: canvas.requestPaint()
  onAutoScaleChanged: canvas.requestPaint()
  onCompactChanged: canvas.requestPaint()
  onLineColorChanged: canvas.requestPaint()
  onGridColorChanged: canvas.requestPaint()
  onTextColorChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent

    onPaint: {
      var ctx = getContext("2d")
      var w = width
      var h = height
      ctx.reset()
      ctx.clearRect(0, 0, w, h)
      if (w < 2 || h < 2) return

      ctx.lineWidth = 1
      ctx.strokeStyle = Util.alpha(root.gridColor, 0.28).toString()
      ctx.fillStyle = Util.alpha(root.textColor, 0.45).toString()
      ctx.font = Style.font.caption + "px \"" + root.fontFamily + "\""
      ctx.textAlign = "left"
      ctx.textBaseline = "top"

      var ticks = root.yTicks()
      var plotBottom = root.plotHeight
      for (var i = 0; i < ticks.length; i++) {
        var y = root.yForValue(ticks[i])
        ctx.beginPath()
        ctx.moveTo(0, y)
        ctx.lineTo(w, y)
        ctx.stroke()
        if (!root.compact && ticks[i] !== 0) ctx.fillText(String(Math.round(ticks[i])), 2, Math.max(0, y + 2))
      }

      var xTicks = Model.axisTicks(root.windowStart, root.windowEnd, Math.max(4, Math.min(6, Math.round(w / 78))))
      ctx.textBaseline = "top"
      var prevTick = NaN
      for (var xt = 0; xt < xTicks.length; xt++) {
        var tx = root.xForTime(xTicks[xt])
        ctx.beginPath()
        ctx.strokeStyle = Util.alpha(root.gridColor, 0.18).toString()
        ctx.moveTo(tx, 0)
        ctx.lineTo(tx, plotBottom)
        ctx.stroke()

        if (root.compact) continue
        var label = Model.formatAxisTick(xTicks[xt], root.windowStart, root.windowEnd, prevTick)
        prevTick = xTicks[xt]
        ctx.fillStyle = Util.alpha(root.textColor, 0.55).toString()
        if (xt === 0) ctx.textAlign = "left"
        else if (xt === xTicks.length - 1) ctx.textAlign = "right"
        else ctx.textAlign = "center"
        ctx.fillText(label, Math.max(0, Math.min(w, tx)), plotBottom + 2)
      }

      var series = root.plotPoints
      if (!series.length) return

      ctx.beginPath()
      var started = false
      var firstX = 0
      var lastX = 0
      for (var p = 0; p < series.length; p++) {
        if (!isFinite(Number(series[p].v))) {
          started = false
          continue
        }
        var x = root.xForTime(series[p].t)
        var yv = root.yForValue(series[p].v)
        if (!started) {
          ctx.moveTo(x, yv)
          firstX = x
          started = true
        } else {
          ctx.lineTo(x, yv)
        }
        lastX = x
      }

      if (started) {
        ctx.strokeStyle = root.lineColor.toString()
        ctx.lineWidth = 1.75
        ctx.lineJoin = "round"
        ctx.lineCap = "round"
        ctx.stroke()

        ctx.lineTo(lastX, plotBottom)
        ctx.lineTo(firstX, plotBottom)
        ctx.closePath()
        ctx.fillStyle = Util.alpha(root.lineColor, 0.16).toString()
        ctx.fill()
      }

      if (root.hoverX >= 0 && isFinite(root.hoverT)) {
        ctx.beginPath()
        ctx.strokeStyle = Util.alpha(root.crosshairColor, 0.45).toString()
        ctx.lineWidth = 1
        ctx.moveTo(root.hoverX, 0)
        ctx.lineTo(root.hoverX, plotBottom)
        ctx.stroke()

        if (root.hoverV !== null && isFinite(Number(root.hoverV))) {
          var hx = root.hoverX
          var hy = root.yForValue(root.hoverV)
          ctx.beginPath()
          ctx.fillStyle = root.lineColor.toString()
          ctx.arc(hx, hy, 3.2, 0, Math.PI * 2)
          ctx.fill()
        }
      }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton
    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
    property real lastX: 0
    property bool dragging: false

    onPressed: function(event) {
      dragging = true
      lastX = event.x
      root.updateHover(event.x)
    }
    onReleased: dragging = false
    onCanceled: dragging = false
    onExited: {
      if (!dragging) {
        root.hoverX = -1
        root.hoverT = NaN
        root.hoverV = null
        canvas.requestPaint()
      }
    }
    onPositionChanged: function(event) {
      if (dragging) {
        var dt = ((lastX - event.x) / Math.max(1, width)) * root.windowSpan
        lastX = event.x
        if (dt !== 0) root.panRequested(dt)
      }
      root.updateHover(event.x)
    }
    onWheel: function(wheel) {
      var stepped = Util.wheelSteps(root.wheelAcc, wheel.angleDelta.y)
      root.wheelAcc = stepped.remainder
      if (stepped.steps !== 0) {
        var factor = stepped.steps > 0 ? Math.pow(0.8, stepped.steps) : Math.pow(1.25, -stepped.steps)
        root.zoomRequested(factor, root.timeForX(wheel.x))
      }
      wheel.accepted = true
    }
  }

  Rectangle {
    visible: root.hoverX >= 0 && root.hoverV !== null && isFinite(Number(root.hoverV))
    x: Math.min(Math.max(0, root.hoverX + Style.space(8)), Math.max(0, parent.width - implicitWidth))
    y: Style.space(4)
    implicitWidth: hoverLabel.implicitWidth + Style.space(10)
    implicitHeight: hoverLabel.implicitHeight + Style.space(6)
    radius: Math.min(Style.cornerRadius, height / 2)
    color: Color.popups.background
    border.width: 1
    border.color: Util.alpha(root.textColor, 0.2)

    Text {
      id: hoverLabel
      anchors.centerIn: parent
      text: root.hoverText()
      color: root.textColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }
}
