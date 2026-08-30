import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "omanetmonitor"

  // Same identity-forwarding pattern as other popup-widget plugins: the
  // bar's popout coordinator and findPanelWidget() key off the bar-widget
  // root, not the nested Panel, so opened/open/close live here and forward.
  readonly property bool opened: panelItem ? panelItem.opened === true : false
  function open() { if (panelItem) panelItem.open() }
  function close() { if (panelItem) panelItem.close() }
  function togglePanel() { if (panelItem) panelItem.toggle() }

  readonly property bool popoutSwitchClosing: panelItem ? panelItem.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelItem) panelItem.closeForPopoutSwitch() }

  // Target of the "refresh" IPC broadcast (see IpcHandler below) — the
  // broadcast helper calls this by name on every live widget instance.
  function runScan() { if (panelItem) panelItem.runScan() }

  readonly property int flaggedCount: panelItem ? (panelItem.flaggedCount || 0) : 0
  readonly property int totalConnections: panelItem ? (panelItem.totalConnections || 0) : 0
  readonly property bool scanFailed: panelItem ? panelItem.scanFailed === true : false

  property var panelItem: null

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    panelItem = target
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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

  IpcHandler {
    target: "omanetmonitor"

    function refresh(): void { root.broadcast("runScan") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.scanFailed ? "" : (root.flaggedCount > 0 ? "" : "")
    active: root.flaggedCount > 0 || root.scanFailed
    tooltipText: root.scanFailed
      ? "OmaNetMonitor — scan failed, click for details"
      : (root.flaggedCount > 0
          ? "OmaNetMonitor — " + root.flaggedCount + " outbound connection" + (root.flaggedCount === 1 ? "" : "s") + " outside your allowed region"
          : "OmaNetMonitor — all outbound connections in your allowed region")

    onPressed: function(b) {
      if (b === Qt.LeftButton) root.togglePanel()
    }

    // Small count badge in the corner when there's something to see.
    Rectangle {
      visible: root.flaggedCount > 0
      width: Style.space(14)
      height: width
      radius: width / 2
      color: Color.urgent
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(2)
      anchors.topMargin: Style.space(2)

      Text {
        anchors.centerIn: parent
        text: root.flaggedCount > 9 ? "9+" : String(root.flaggedCount)
        color: "white"
        font.family: Style.font.family
        font.pixelSize: Style.font.caption * 0.8
        font.bold: true
      }
    }
  }
}
