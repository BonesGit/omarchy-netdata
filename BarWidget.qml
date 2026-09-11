import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  // moduleName is injected by the bar. Binding it here makes the
  // property read-only and injectProps() throws before settings land.
  //
  // Polling lives in the plugin `service` singleton. Dual-monitor pills
  // with the same host+charts share one Poller.

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  property var netdata: null

  readonly property color statusColor: {
    if (!netdata || !netdata.connected) return Color.muted
    var key = netdata.status
    if (key === "low") return themeGreen
    if (key === "mid") return themeYellow
    if (key === "high") return Color.urgent
    return Color.muted
  }
  readonly property string hostLabel: netdata ? netdata.hostLabel : Model.hostLabel(Model.configuredHost(root.settings))
  readonly property int matrixColumns: Model.configuredMatrixColumns(root.settings)
  readonly property int matrixRows: Model.configuredMatrixRows(root.settings)
  readonly property var matrixGeom: Model.matrixLayout(matrixColumns, matrixRows, Style.bar.iconCanvas, Style.space(1))
  readonly property var sparkSamples: Model.sparkWindow(netdata ? netdata.sparkValues : [], matrixColumns)
  readonly property real openPanelIndicatorWidth: root.vertical ? 0 : contentRow.implicitWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))
  readonly property string tooltip: {
    if (!netdata || !netdata.polling) return hostLabel + " · stopped"
    if (!netdata.connected) return hostLabel + " · offline"
    if (netdata.splitEnabled && netdata.splitValues && netdata.splitValues.length > 1)
      return hostLabel + " GPU " + Model.formatValueList(netdata.splitValues, Model.formatPercent, "%")
    return hostLabel + " GPU " + Model.formatPercent(netdata.currentValue) + "%"
  }

  property color themeGreen: "#3ecf6a"
  property color themeYellow: "#e0b44b"

  function bindService() {
    if (!root.moduleName) return
    if (!bar || !bar.shell || typeof bar.shell.serviceFor !== "function") return
    var s = bar.shell.serviceFor("io.github.bonesgit.omarchy-netdata")
    if (!s || typeof s.pollerFor !== "function") return
    var poller = s.pollerFor(root.settings)
    if (!poller) return
    if (netdata !== poller) netdata = poller
    injectPanel()
  }

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }
  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }
  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }
  function refresh() {
    if (netdata) netdata.refreshLatest()
    if (panelLoader.item && panelLoader.item.refreshHistory) panelLoader.item.refreshHistory()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = netdata
    if ("statusColor" in target) target.statusColor = root.statusColor
  }

  function sparkDotColor(colIndex, rowFromTop) {
    var values = root.sparkSamples
    var v = values && colIndex < values.length ? values[colIndex] : null
    var key = Model.matrixCellKey(v, root.matrixRows - 1 - rowFromTop, root.matrixRows)
    if (key === "low") return themeGreen
    if (key === "mid") return themeYellow
    if (key === "high") return Color.urgent
    return Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.38)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: bindService()
  onSettingsChanged: bindService()
  onNetdataChanged: injectPanel()
  onStatusColorChanged: if (panelLoader.item && "statusColor" in panelLoader.item) panelLoader.item.statusColor = statusColor

  Timer {
    interval: 200
    running: root.netdata === null
    repeat: true
    triggeredOnStart: true
    onTriggered: root.bindService()
  }

  // Stopped (not polling): grey square outline.
  // Polling: N×M LED matrix (default 5×5). Columns are refresh slices
  // (newest on the right); rows are utilization, green at the bottom to
  // red at the top. Offline / checking is the same grid with unlit dots.
  component StatusMark: Item {
    implicitWidth: root.matrixGeom.width
    implicitHeight: Math.max(root.matrixGeom.height, Style.space(8))
    width: implicitWidth
    height: implicitHeight

    Rectangle {
      visible: !(netdata && netdata.polling)
      width: Style.space(8)
      height: Style.space(8)
      color: "transparent"
      border.width: 1
      border.color: Color.muted
      anchors.centerIn: parent
    }

    Row {
      visible: !!(netdata && netdata.polling)
      anchors.centerIn: parent
      spacing: root.matrixGeom.gap

      Repeater {
        model: root.matrixColumns
        Column {
          id: sparkCol
          spacing: root.matrixGeom.gap
          property int colIndex: index

          Repeater {
            model: root.matrixRows
            Rectangle {
              width: root.matrixGeom.cell
              height: root.matrixGeom.cell
              radius: width / 2
              color: root.sparkDotColor(sparkCol.colIndex, index)
            }
          }
        }
      }
    }
  }

  IpcHandler {
    target: "io.github.bonesgit.omarchy-netdata"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    tooltipText: root.tooltip
    fixedWidth: root.vertical ? -1 : Math.max(Style.bar.iconSlot, contentRow.implicitWidth + Style.space(16))
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton || buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }

    Row {
      id: contentRow
      visible: !root.vertical
      anchors.centerIn: parent
      spacing: Style.space(6)

      StatusMark {
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: root.hostLabel
        textFormat: Text.PlainText
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    StatusMark {
      visible: root.vertical
      anchors.centerIn: parent
    }
  }
}
