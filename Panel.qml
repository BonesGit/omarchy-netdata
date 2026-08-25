import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  // moduleName is injected by the bar host when this file is the entry
  // point. Nested under BarWidget it is unused; do not bind it.
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  property color statusColor: Color.muted

  property real windowStart: 0
  property real windowEnd: 0
  property bool live: true
  property real durationSec: Model.defaultWindowSec()
  property string preset: "live"

  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string hostText: service ? service.hostLabel : Model.hostLabel(Model.defaultHost())
  readonly property bool connected: service ? service.connected : false
  readonly property bool polling: service ? service.polling : true
  readonly property var currentValue: service ? service.currentValue : null
  readonly property string percentText: connected ? Model.formatPercent(currentValue) : "—"
  readonly property string utilText: {
    if (!service || !connected) return ""
    var splitVals = service.splitValues
    if (splitVals && splitVals.length > 1)
      return Model.formatValueList(splitVals, Model.formatPercent, "%")
    return Model.formatPercent(currentValue) + "%"
  }
  readonly property string tempText: {
    if (!service) return ""
    var splitTemps = service.splitTempValues
    if (splitTemps && splitTemps.length > 1)
      return Model.formatValueList(splitTemps, Model.formatTemp)
    if (service.tempValue === null || service.tempValue === undefined) return ""
    return Model.formatTemp(service.tempValue)
  }
  readonly property bool showTemp: !!(service && service.tempContextId)
  readonly property var tempPoints: service ? service.tempPoints : []
  readonly property var chartSeries: service ? service.series : []
  readonly property var tempSeriesList: service ? service.tempSeries : []
  readonly property bool splitEnabled: service ? service.splitEnabled : false
  readonly property string tempTitle: service && service.tempTitle ? service.tempTitle : Model.defaultTempTitle()
  readonly property string metaText: {
    if (!polling) return "Stopped"
    if (!connected) return "Offline"
    return live ? ("Live · " + Model.formatWindow(durationSec)) : Model.formatWindow(durationSec)
  }
  readonly property var chartPoints: service ? service.points : []
  readonly property string chartTitle: service && service.chartTitle ? service.chartTitle : Model.defaultTitle()

  function openDashboard() {
    var url = Model.configuredDashboardUrl(root.settings)
    if (!url) return
    Quickshell.execDetached(["omarchy-launch-browser", url])
  }

  function open() {
    resetLiveWindow()
    root.controller.show()
    refreshHistory()
  }

  function close() {
    root.controller.hide()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function nowBound() {
    if (service && isFinite(service.dbLast) && service.dbLast > 0) return service.dbLast
    return Model.nowSec()
  }

  function dbFirst() {
    return service && isFinite(service.dbFirst) ? service.dbFirst : 0
  }

  function applyWindow(next) {
    windowStart = next.start
    windowEnd = next.end
    live = next.live
    durationSec = Math.max(1, next.end - next.start)
    historyDebounce.restart()
  }

  function resetLiveWindow() {
    preset = "live"
    applyWindow(Model.liveWindow(Model.defaultWindowSec(), nowBound()))
  }

  function applyPreset(id) {
    var key = String(id || "live")
    preset = key
    if (key === "live") {
      applyWindow(Model.liveWindow(Model.defaultWindowSec(), nowBound()))
      return
    }
    applyWindow(Model.liveWindow(Model.presetDuration(key), nowBound()))
  }

  function refreshHistory() {
    if (!service) return
    service.refreshHistory(windowStart, windowEnd, Model.historyPointsForWidth(chart.width))
  }

  function zoomBy(factor, anchor) {
    preset = ""
    applyWindow(Model.zoomWindow(windowStart, windowEnd, factor, anchor, nowBound(), dbFirst()))
  }

  function panBy(delta) {
    preset = ""
    applyWindow(Model.panWindow(windowStart, windowEnd, delta, nowBound(), dbFirst()))
  }

  function nudge(dx) {
    if (dx === 0) return
    panBy(dx * durationSec * 0.15)
  }

  onOpenedChanged: if (opened) {
    resetLiveWindow()
    refreshHistory()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  onSplitEnabledChanged: if (opened) refreshHistory()

  Connections {
    target: root.service
    function onSeriesUpdated() {
      if (!root.opened) return
      if (root.live) {
        var next = Model.liveWindow(root.durationSec, root.nowBound())
        root.windowStart = next.start
        root.windowEnd = next.end
        root.live = true
      }
    }
  }

  Timer {
    id: historyDebounce
    interval: 140
    onTriggered: root.refreshHistory()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(500))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.nudge(dx)
        else if (dy < 0) root.zoomBy(0.8, (root.windowStart + root.windowEnd) / 2)
        else if (dy > 0) root.zoomBy(1.25, (root.windowStart + root.windowEnd) / 2)
      }
      onTextKey: function(t) {
        if (t === "r" || t === "R") {
          if (root.service) root.service.refreshLatest()
          root.refreshHistory()
        } else if (t === "0") {
          root.resetLiveWindow()
        } else if (t === "+" || t === "=") {
          root.zoomBy(0.8, (root.windowStart + root.windowEnd) / 2)
        } else if (t === "-" || t === "_") {
          root.zoomBy(1.25, (root.windowStart + root.windowEnd) / 2)
        }
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(14)

        Item {
          width: parent.width
          implicitHeight: Math.max(heroDot.height, heroLabels.implicitHeight, heroInlineValue.implicitHeight, pollSwitch.implicitHeight)

          Rectangle {
            id: heroDot
            width: Style.space(14)
            height: Style.space(14)
            radius: root.polling ? width / 2 : 0
            color: root.polling ? root.statusColor : "transparent"
            border.width: root.polling ? 0 : 1
            border.color: Color.muted
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color {
              ColorAnimation { duration: 160 }
            }
          }

          ToggleSwitch {
            id: pollSwitch
            checked: root.polling
            foreground: root.foreground
            accent: Color.accent
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onToggled: if (root.service) root.service.togglePolling()

            PanelToolTip {
              visible: pollSwitch.containsMouse
              text: root.polling ? "Stop updates" : "Start updates"
              fontFamily: root.fontFamily
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroDot.right
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(hostName.implicitWidth, Math.max(0, parent.width - heroDot.width - Style.space(12) - heroInlineValue.implicitWidth - Style.space(8) - pollSwitch.width - Style.space(12)))
            spacing: Style.space(2)

            Text {
              id: hostName
              width: parent.width
              text: root.hostText
              textFormat: Text.PlainText
              color: hostClick.containsMouse ? Color.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              font.underline: hostClick.containsMouse
              elide: Text.ElideRight

              MouseArea {
                id: hostClick
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openDashboard()
              }
            }

            Text {
              width: parent.width
              text: root.metaText.toUpperCase()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
            }
          }

          Row {
            id: heroInlineValue
            anchors.left: heroLabels.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: root.percentText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: 48
              font.bold: true
            }
            Text {
              visible: root.connected
              text: "%"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              font.bold: true
              anchors.top: parent.top
              anchors.topMargin: Style.space(10)
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(utilTitleLabel.implicitHeight, utilValueLabel.implicitHeight)

              Text {
                id: utilTitleLabel
                anchors.left: parent.left
                anchors.right: utilValueLabel.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: root.chartTitle
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                elide: Text.ElideRight
              }

              Text {
                id: utilValueLabel
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.utilText !== "" ? root.utilText : "—"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
            }

            GpuChart {
              id: chart
              width: parent.width
              height: Style.space(184)
              points: root.chartPoints
              series: root.chartSeries
              windowStart: root.windowStart
              windowEnd: root.windowEnd
              live: root.live
              lineColor: Color.accent
              secondaryColor: Color.urgent
              gridColor: Color.muted
              textColor: root.foreground
              crosshairColor: root.foreground
              fontFamily: root.fontFamily
              onZoomRequested: function(factor, anchor) { root.zoomBy(factor, anchor) }
              onPanRequested: function(delta) { root.panBy(delta) }
            }
          }

          Column {
            width: parent.width
            visible: root.showTemp
            height: visible ? implicitHeight : 0
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(tempTitleLabel.implicitHeight, tempValueLabel.implicitHeight)

              Text {
                id: tempTitleLabel
                anchors.left: parent.left
                anchors.right: tempValueLabel.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: root.tempTitle
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                elide: Text.ElideRight
              }

              Text {
                id: tempValueLabel
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.tempText !== "" ? root.tempText : "—"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
            }

            GpuChart {
              id: tempChart
              width: parent.width
              height: Math.round(chart.height / 3)
              points: root.tempPoints
              series: root.tempSeriesList
              windowStart: root.windowStart
              windowEnd: root.windowEnd
              live: root.live
              autoScale: true
              compact: true
              temperature: true
              lineColor: Color.accent
              secondaryColor: Color.urgent
              gridColor: Color.muted
              textColor: root.foreground
              crosshairColor: root.foreground
              fontFamily: root.fontFamily
              onZoomRequested: function(factor, anchor) { root.zoomBy(factor, anchor) }
              onPanRequested: function(delta) { root.panBy(delta) }
            }
          }
        }

        Item {
          width: parent.width
          implicitHeight: Style.spacing.controlHeight
          height: implicitHeight

          ButtonGroup {
            id: rangeButtons
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            focusable: false
            foreground: root.foreground
            background: "transparent"
            accent: Color.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            value: root.preset
            options: [
              { value: "3d", label: "3D" },
              { value: "2d", label: "2D" },
              { value: "24h", label: "24H" },
              { value: "6h", label: "6H" },
              { value: "3h", label: "3H" },
              { value: "1h", label: "1H" },
              { value: "live", label: "Live" }
            ]
            onChanged: function(v) { root.applyPreset(v) }
          }
        }
      }
    }
  }
}
