import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// OmaNetMonitor popup: periodically scans established outbound TCP
// connections (via the plugin-local bin/omanetmonitor-scan helper), flags
// any whose remote IP geolocates outside the user's allowed countries, and
// lists every flagged connection (IP, country, port) in a scrollable list,
// sorted by connection count.
Panel {
  id: root
  moduleName: "omanetmonitor"
  ipcTarget: ""
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color panelBackground: Color.popups.background

  // ------------------------------------------------------------------ settings

  readonly property string allowedCountriesRaw: root.setting("allowedCountries", "US")
  readonly property var allowedCountries: Model.normalizeCountryList(root.allowedCountriesRaw)
  readonly property int refreshIntervalSec: {
    var v = parseInt(root.setting("refreshIntervalSec", 30))
    return (v >= 10 && v <= 600) ? v : 30
  }

  // Inline settings editor. Dirty state is two plain flags, each toggled by
  // exactly one kind of event (a real user edit, or an explicit reset/save) —
  // never a property whose binding both reads and gets written to as part of
  // resolving the same dependency chain. That combination (countriesDirty as
  // `computed from countriesField.text`, with a change handler on one of its
  // own dependencies turning around and writing countriesField.text) is what
  // an earlier version of this file had, and Qt correctly flagged it as a
  // binding loop — it converged in practice, but relying on evaluation-order
  // side effects like that is fragile.
  //
  // syncingCountriesField distinguishes a programmatic text assignment from
  // a real keystroke: TextField has no separate "user edited" signal, so
  // onTextChanged fires for both; without the guard, our own sync writes
  // would mark the field dirty against itself.
  property bool syncingCountriesField: false
  property bool countriesDirty: false
  property int pendingIntervalSec: root.refreshIntervalSec
  property bool intervalDirty: false
  readonly property bool settingsDirty: root.countriesDirty || root.intervalDirty

  function setCountriesFieldText(value) {
    root.syncingCountriesField = true
    countriesField.text = value
    root.syncingCountriesField = false
  }

  function resetSettingsDraft() {
    root.setCountriesFieldText(root.allowedCountriesRaw)
    root.countriesDirty = false
    root.pendingIntervalSec = root.refreshIntervalSec
    root.intervalDirty = false
  }

  function saveSettings() {
    var codes = Model.normalizeCountryList(countriesField.text)
    var csv = codes.join(",")
    saveCountriesProcess.command = ["omarchy", "bar", "set", "omanetmonitor", "allowedCountries", csv]
    saveCountriesProcess.running = true
    saveIntervalProcess.command = ["omarchy", "bar", "set", "omanetmonitor", "refreshIntervalSec", String(root.pendingIntervalSec), "--json"]
    saveIntervalProcess.running = true
    root.setCountriesFieldText(csv)
    root.countriesDirty = false
    root.intervalDirty = false
    root.runScanWith(csv)
  }

  Process { id: saveCountriesProcess }
  Process { id: saveIntervalProcess }

  onAllowedCountriesRawChanged: {
    if (!root.countriesDirty) root.setCountriesFieldText(root.allowedCountriesRaw)
  }
  onRefreshIntervalSecChanged: {
    if (!root.intervalDirty) root.pendingIntervalSec = root.refreshIntervalSec
    scanTimer.restart()
  }

  // ------------------------------------------------------------------- scan

  property var flaggedEntries: []
  property int flaggedCount: 0
  property int totalConnections: 0
  property int totalUniquePeers: 0
  property int lastScanAt: 0
  property bool scanning: false
  property bool scanFailed: false
  property string scanErrorText: ""

  readonly property string scanScriptPath: Model.localFilePath(Qt.resolvedUrl("bin/omanetmonitor-scan"))

  function runScan() { root.runScanWith(root.allowedCountries.join(",")) }

  // Split out so saveSettings() can scan against the just-saved country list
  // immediately, instead of the stale one still in `settings` until the
  // shell.json write round-trips back through settings injection.
  function runScanWith(countryCsv) {
    if (scanProcess.running) return
    root.scanning = true
    scanProcess.command = [root.scanScriptPath, countryCsv]
    scanProcess.running = true
  }

  // Quickshell's Process/StdioCollector don't expose a way to cap bytes
  // while streaming or to reach into the child's process group from QML —
  // that streaming-bounded enforcement lives in the scan script itself,
  // which is the thing actually reading `ss` and the network response. At
  // this layer the two things available are: a hard wall-clock deadline
  // (the watchdog below, which stops the process via `running = false` if
  // it hasn't exited in time) and rejecting the collected output outright
  // if it's larger than a sane scan result should ever be, before it's
  // parsed at all.
  readonly property int scanWatchdogMs: 20000
  readonly property int maxScanOutputLen: 256 * 1024

  Process {
    id: scanProcess
    stdout: StdioCollector { id: scanStdout; waitForEnd: true }
    onRunningChanged: {
      if (scanProcess.running) scanWatchdog.restart()
      else scanWatchdog.stop()
    }
    onExited: function(exitCode) {
      scanWatchdog.stop()
      root.scanning = false
      if (exitCode !== 0) {
        root.scanFailed = true
        root.scanErrorText = "Scan exited with code " + exitCode
        return
      }
      if (scanStdout.text.length > root.maxScanOutputLen) {
        root.scanFailed = true
        root.scanErrorText = "Scan output too large"
        return
      }
      var data = Model.parseScanOutput(scanStdout.text)
      if (!data) {
        root.scanFailed = true
        root.scanErrorText = "Could not parse scan output"
        return
      }
      root.scanFailed = false
      root.scanErrorText = ""
      root.flaggedEntries = data.flagged || []
      root.flaggedCount = data.totalFlagged || 0
      root.totalConnections = data.totalConnections || 0
      root.totalUniquePeers = data.totalUniquePeers || 0
      root.lastScanAt = data.generatedAt || Math.round(Date.now() / 1000)
    }
  }

  Timer {
    id: scanWatchdog
    interval: root.scanWatchdogMs
    repeat: false
    onTriggered: {
      if (!scanProcess.running) return
      root.scanning = false
      root.scanFailed = true
      root.scanErrorText = "Scan timed out"
      scanProcess.running = false
    }
  }

  Timer {
    id: scanTimer
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.runScan()
  }

  // Re-render "Xs ago" without waiting for a new scan.
  Timer {
    interval: 5000
    running: root.opened
    repeat: true
  }

  // ------------------------------------------------------------------ export

  // exportPathField.text carries the destination directly — no separate
  // property mirroring it, since (unlike allowedCountries) it never needs
  // to round-trip through shell.json settings. It stays empty until the
  // user opens the panel for the first time (or edits it), so a default is
  // only ever suggested, never forced — once set, it's remembered for the
  // rest of the session instead of resetting on every reopen, since the
  // whole point is letting the user pick a destination.
  //
  // The field itself never carries a timestamp — exportCsv() stamps the
  // path fresh on every click (see Model.withExportTimestamp), so the
  // filename reflects when the export actually happened, not whenever the
  // panel happened to be opened or last edited.
  property string exportStatus: ""
  property bool exportFailed: false

  function ensureExportPathDefault() {
    if (exportPathField.text !== "") return
    var home = Quickshell.env("HOME") || ""
    exportPathField.text = home + "/omanetmonitor-flagged-export.csv"
  }

  // "~", "~/foo", an absolute path, or a bare filename (resolved against
  // $HOME, since a bar panel has no meaningful working directory) — no
  // native file-save dialog is used here (see README), so this expansion is
  // what lets a typed path actually reach an arbitrary destination.
  function expandExportPath(raw) {
    var p = String(raw || "").trim()
    if (p === "") return ""
    var home = Quickshell.env("HOME") || ""
    if (p === "~") return home
    if (p.indexOf("~/") === 0) return home + p.substring(1)
    if (p.indexOf("/") === 0) return p
    return home + "/" + p
  }

  function exportCsv() {
    var base = root.expandExportPath(exportPathField.text)
    if (base === "") {
      root.exportFailed = true
      root.exportStatus = "Enter a file path first"
      exportStatusClearTimer.restart()
      return
    }
    exportFileView.path = Model.withExportTimestamp(base)
    exportFileView.setText(Model.buildFlaggedCsv(root.flaggedEntries))
  }

  FileView {
    id: exportFileView
    printErrors: false
    atomicWrites: true
    onSaved: {
      root.exportFailed = false
      root.exportStatus = "Saved " + root.flaggedEntries.length + " row" + (root.flaggedEntries.length === 1 ? "" : "s") + " to " + exportFileView.path
      exportStatusClearTimer.restart()
    }
    onSaveFailed: function(error) {
      root.exportFailed = true
      root.exportStatus = "Export failed: " + error
      exportStatusClearTimer.restart()
    }
  }

  Timer {
    id: exportStatusClearTimer
    interval: 6000
    repeat: false
    onTriggered: root.exportStatus = ""
  }

  // ------------------------------------------------------------- open / close

  function open() {
    root.resetSettingsDraft()
    root.ensureExportPathDefault()
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) root.primeFocus()
    })
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function primeFocus() {
    focusRetry.restart()
  }

  Timer {
    id: focusRetry
    interval: 120
    repeat: false
    onTriggered: {
      if (root.opened && keyCatcher) keyCatcher.forceActiveFocus()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(Style.space(500))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: countriesField.activeFocus || exportPathField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
    }

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.space(16)
      spacing: Style.space(10)

      // ---------------------------------------------------------- header

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(10)

        Text {
          text: ""
          color: root.flaggedCount > 0 ? Color.urgent : root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.space(26)
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(1)

          Label {
            text: "OmaNetMonitor"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Label {
            text: root.scanFailed
              ? ("Scan error: " + root.scanErrorText)
              : (root.totalConnections + " outbound connection" + (root.totalConnections === 1 ? "" : "s") + " · "
                  + root.flaggedCount + " outside " + root.allowedCountries.join(", ")
                  + " · updated " + Model.formatRelativeTime(root.lastScanAt))
            textFormat: Text.PlainText
            color: root.scanFailed ? Color.urgent : Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            Layout.fillWidth: true
            elide: Label.ElideRight
          }
        }

        Button {
          iconText: ""
          tooltipText: "Scan now"
          enabled: !root.scanning
          foreground: root.contentForeground
          accent: Color.accent
          fontFamily: root.contentFontFamily
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(4)
          onClicked: root.runScan()
        }
      }

      PanelSeparator {
        Layout.fillWidth: true
      }

      // --------------------------------------------------------- settings

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Label {
          text: "Allowed:"
          color: Qt.darker(root.contentForeground, 1.4)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
        }

        TextField {
          id: countriesField
          Layout.fillWidth: true
          placeholderText: "US, CA, MX"
          foreground: root.contentForeground
          accent: Color.accent
          font.family: root.contentFontFamily
          // No `text:` binding on purpose — see the settingsDirty comment
          // above. Initial/external sync happens imperatively via
          // resetSettingsDraft() and onAllowedCountriesRawChanged, both of
          // which go through setCountriesFieldText() and so don't trip
          // this handler.
          onTextChanged: if (!root.syncingCountriesField) root.countriesDirty = true
          Keys.onEscapePressed: root.close()
          Keys.onReturnPressed: root.saveSettings()
        }

        NumberField {
          label: ""
          from: 10
          to: 600
          stepSize: 5
          value: root.pendingIntervalSec
          fieldWidth: Style.space(70)
          foreground: root.contentForeground
          accent: Color.accent
          fontFamily: root.contentFontFamily
          onModified: function(v) { root.pendingIntervalSec = v; root.intervalDirty = true }
        }

        Label {
          text: "sec"
          color: Qt.darker(root.contentForeground, 1.4)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Button {
          text: "Save"
          visible: root.settingsDirty
          bordered: true
          foreground: root.contentForeground
          accent: Color.accent
          fontFamily: root.contentFontFamily
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(4)
          onClicked: root.saveSettings()
        }
      }

      Label {
        text: "Comma-separated ISO country codes (e.g. US or US,CA,MX) that are never flagged."
        textFormat: Text.PlainText
        color: Qt.darker(root.contentForeground, 1.8)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Label.Wrap
        Layout.fillWidth: true
      }

      PanelSeparator {
        Layout.fillWidth: true
      }

      // ------------------------------------------------------------ list

      Label {
        text: root.flaggedCount > 0
          ? (root.flaggedEntries.length + " outside your allowed region")
          : "No outbound connections outside your allowed region"
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        Layout.fillWidth: true
      }

      RowLayout {
        Layout.fillWidth: true
        visible: root.flaggedEntries.length > 0
        spacing: Style.space(8)

        Label {
          text: "IP ADDRESS"
          color: Qt.darker(root.contentForeground, 2.0)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          Layout.preferredWidth: Style.space(150)
        }
        Label {
          text: "COUNTRY"
          color: Qt.darker(root.contentForeground, 2.0)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          Layout.fillWidth: true
        }
        Label {
          text: "PORT"
          color: Qt.darker(root.contentForeground, 2.0)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          Layout.preferredWidth: Style.space(60)
          horizontalAlignment: Text.AlignRight
        }
      }

      ListView {
        id: entryList
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        spacing: Style.space(2)
        model: root.flaggedEntries
        ScrollBar.vertical: ScrollBar {
          policy: ScrollBar.AsNeeded
          implicitWidth: Style.space(6)
          contentItem: Rectangle {
            implicitWidth: Style.space(6)
            implicitHeight: Style.space(6)
            radius: width / 2
            color: Util.alpha(root.contentForeground, 0.45)
          }
        }

        delegate: Rectangle {
          required property var modelData
          width: entryList.width
          height: Style.space(30)
          radius: Style.cornerRadius > 0 ? Style.cornerRadius : 4
          color: rowHover.hovered
            ? Style.hoverFillFor(root.contentForeground, Color.accent)
            : "transparent"

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            spacing: Style.space(8)

            Label {
              text: modelData.ip
              textFormat: Text.PlainText
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              Layout.preferredWidth: Style.space(150)
              elide: Label.ElideRight
            }
            Label {
              text: modelData.countryName + (modelData.countryCode ? " (" + modelData.countryCode + ")" : "")
              textFormat: Text.PlainText
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              Layout.fillWidth: true
              elide: Label.ElideRight
            }
            Label {
              text: String(modelData.port)
              textFormat: Text.PlainText
              color: Qt.darker(root.contentForeground, 1.4)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              Layout.preferredWidth: Style.space(60)
              horizontalAlignment: Text.AlignRight
            }
          }

          HoverHandler {
            id: rowHover
          }
        }
      }

      // ---------------------------------------------------------- export

      PanelSeparator {
        Layout.fillWidth: true
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Label {
          text: "Save to:"
          color: Qt.darker(root.contentForeground, 1.4)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
        }

        TextField {
          id: exportPathField
          Layout.fillWidth: true
          placeholderText: "~/omanetmonitor-flagged-export.csv"
          foreground: root.contentForeground
          accent: Color.accent
          font.family: root.contentFontFamily
          // No `text:` binding — see the countriesField comment above for
          // why this stays imperative-only.
          Keys.onEscapePressed: root.close()
          Keys.onReturnPressed: root.exportCsv()
        }

        Button {
          text: "Export CSV"
          tooltipText: "Save the flagged-connections list as CSV"
          bordered: true
          foreground: root.contentForeground
          accent: Color.accent
          fontFamily: root.contentFontFamily
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(4)
          onClicked: root.exportCsv()
        }
      }

      Label {
        visible: root.exportStatus !== ""
        text: root.exportStatus
        textFormat: Text.PlainText
        color: root.exportFailed ? Color.urgent : Qt.darker(root.contentForeground, 1.5)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Label.Wrap
        Layout.fillWidth: true
      }
    }
  }
}
