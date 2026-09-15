import QtQuick
import Quickshell
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Cliamp bar surface. The pill shows the transport state (music glyph + a tiny
// EQ readout when the daemon is actually decoding frames), left-click toggles,
// wheel steps track, and right-click opens the full panel: now-playing header,
// seek, transport, repeat/shuffle/mono, volume, and your cliamp favourites.
//
// All state comes from the shared davidjm.cliamp service instance (bar.shell.
// serviceFor) — see Service.qml for the IPC engine.
BarWidget {
  id: root
  moduleName: "davidjm.cliamp"

  // ------------------------------------------------------------------- svc --

  readonly property var svc: bar && bar.shell
    ? bar.shell.serviceFor(root.moduleName) : null

  readonly property var snap: root.svc && root.svc.connected
    ? root.svc.snapshot : Model.blankSnapshot()
  readonly property bool down: !root.svc || !root.svc.connected
  readonly property bool connecting: root.svc && root.svc.connecting
  readonly property bool playing: Model.playing(root.snap)
  readonly property bool paused: Model.paused(root.snap)
  readonly property bool hasTrack: root.playing || root.paused
  readonly property real seekEnd: root.snap.duration > 0 && root.snap.seekable
    ? root.snap.duration : 0
  readonly property real position: root.playing
    ? Math.min(root.svc.displayPosition, root.seekEnd)
    : Math.min(root.snap.position, root.seekEnd)

  readonly property color fg: root.bar ? root.bar.barForeground : Color.foreground
  readonly property string fam: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property color glyphColor: root.down
    ? (root.bar ? root.bar.urgent : Color.urgent)
    : root.playing ? Color.accent : Qt.darker(root.fg, 1.5)

  property bool popupOpen: false

  readonly property string iconTooltip: {
    var tip = root.down
      ? "Cliamp is not running"
      : root.hasTrack ? Model.statusLine(root.snap) + "  ·  " + Model.timeRange(root.snap, root.position)
      : "Cliamp"
    tip += root.down
      ? "   ·   click to start the daemon"
      : "   ·   click play/pause · middle stop · right-click panel · wheel prev/next"
    return tip
  }

  function iconClick() {
    if (root.down) { root.startDaemon(); return }
    if (root.svc) root.svc.run(["toggle"])
  }

  readonly property var favoriteRows: root.svc && root.svc.favorites
    ? root.svc.favorites : []

  function open() { popupOpen = true }
  function close() { popupOpen = false }
  function refresh() { if (root.svc) root.svc.refreshFavorites() }
  function togglePanel() { root.popupOpen = !root.popupOpen }

  function startDaemon() {
    if (!root.svc) return
    Quickshell.execDetached([root.svc.cliampPath, "--daemon", "--log-level", "error"])
  }
  function stopDaemon() {
    // The v2 IPC API has no shutdown operation, so stop the daemon process
    // itself. The bracket trick keeps the pattern from matching its own pkill.
    Quickshell.execDetached(["pkill", "-TERM", "-f", "[c]liamp --daemon"])
  }
  function toggleDaemon() {
    if (root.down) root.startDaemon()
    else root.stopDaemon()
  }
  function openTui() {
    if (!root.svc) return
    Quickshell.execDetached(["omarchy-launch-terminal", root.svc.cliampPath])
  }

  // Keep the service in lockstep with this widget's effective settings.
  Component.onCompleted: if (root.svc) root.svc.applySettings(root.settings)
  onSettingsChanged: if (root.svc) root.svc.applySettings(root.settings)

  // --------------------------------------------------------------- pill -----

  implicitHeight: button.implicitHeight
  implicitWidth: button.implicitWidth

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf001"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.body
    foreground: root.glyphColor
    active: root.playing
    useActiveColor: !root.down
    activeColor: Color.accent
    dimmed: root.down
    tooltipText: root.iconTooltip
    onPressed: function(b) {
      if (b === Qt.LeftButton) { root.iconClick(); return }
      if (b === Qt.MiddleButton) {
        if (!root.down && root.svc) root.svc.run(["stop"])
        return
      }
      if (b === Qt.RightButton) { root.togglePanel(); return }
    }
    onWheelMoved: function(delta) {
      if (!root.down && root.svc) {
        if (delta > 0) root.svc.run(["prev"])
        else if (delta < 0) root.svc.run(["next"])
      }
    }
  }

  // -------------------------------------------------------------- panel -----

  KeyboardPanel {
    id: panel
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    padding: Style.spacing.popupPadding
    contentWidth: panel.fittedContentWidth(Style.space(560), Style.space(760))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)
    focusTarget: catcher

    PanelKeyCatcher {
      id: catcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) { contentScroll.flick(0, dy * 240) }

      Flickable {
        id: contentScroll
        anchors.fill: parent
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(10)

          // ---------------------------------------------------- daemon banner
          Column {
            width: parent.width
            visible: root.down
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(8)

              OpticalGlyph {
                anchors.verticalCenter: parent.verticalCenter
                fontFamily: root.fam
                fontSize: Style.font.iconLarge
                text: "\uf071"
                color: root.bar ? root.bar.urgent : Color.urgent
              }

              Column {
                width: parent.width - Style.space(26)
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: "Cliamp is not running"
                  color: root.fg
                  font.family: root.fam
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.svc ? root.svc.lastError : "no service loaded"
                  color: Qt.darker(root.fg, 1.4)
                  font.family: root.fam
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  visible: text !== ""
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.spacing.controlGap

              Button {
                iconText: "\uf011"
                text: "Start daemon"
                foreground: root.fg
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.startDaemon()
              }
              Button {
                text: "Open cliamp"
                foreground: root.fg
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.openTui()
              }
            }

            PanelSeparator {
              foreground: root.fg
            }
          }

          // -------------------------------------------------- now-playing head
          Row {
            width: parent.width
            spacing: Style.space(10)
            visible: !root.down && root.hasTrack

            BorderSurface {
              width: Style.space(56)
              height: Style.space(56)
              radius: Style.spacing.labelGap
              color: Style.normalFillFor(root.fg, Color.accent)
              borderSpec: Border.controlSpec("normal", root.fg, Color.accent)

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: Model.trackGlyph(root.snap)
                color: root.fg
                font.family: root.fam
                font.pixelSize: Style.font.displayLarge
              }
            }

            Column {
              width: parent.width - Style.space(66)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.snap.track.title || (Model.isStream(root.snap) ? "Radio stream" : "Unknown track")
                color: root.fg
                font.family: root.fam
                font.pixelSize: Style.font.subtitle
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.snap.track.artist
                color: Qt.darker(root.fg, 1.3)
                font.family: root.fam
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                visible: text !== ""
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: Model.subtitleLine(root.snap)
                color: Qt.darker(root.fg, 1.6)
                font.family: root.fam
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                visible: text !== ""
              }
            }
          }

          // --------------------------------------------------- progress group
          Row {
            width: parent.width
            spacing: Style.spacing.labelGap * 2
            visible: !root.down && root.hasTrack

            Text {
              id: timeNow
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: Model.formatTime(root.position)
              color: root.fg
              font.family: root.fam
              font.pixelSize: Style.font.caption
              width: Style.space(46)
            }

            PanelSlider {
              id: seekSlider
              bar: root.bar
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - timeNow.width - timeEnd.width - Style.spacing.labelGap * 4
              minimum: 0
              maximum: Math.max(1, root.seekEnd)
              step: 1
              integer: true
              value: root.position
              visible: root.seekEnd > 0 && !Model.isStream(root.snap)
              onReleased: function(v) {
                if (root.down || !root.hasTrack) return
                root.svc.run(["remote", "call", "seek.absolute", "--params",
                  JSON.stringify({ value: Math.max(0, Math.min(v, root.seekEnd)) })])
              }
            }

            // No scrubber for live streams: animated bands stand in for the
            // impossibly-onward progress bar.
            Item {
              id: liveVis
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - timeNow.width - timeEnd.width - Style.spacing.labelGap * 4
              height: Math.max(10, Style.space(14))
              visible: root.seekEnd <= 0 || Model.isStream(root.snap)

              Row {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)
                Repeater {
                  model: 14
                  delegate: Rectangle {
                    required property int index
                    width: (liveVis.width - Style.space(2) * 13) / 14
                    height: liveVis.height * (index % 3 === 0 ? 0.4 : 1.0)
                    radius: 1
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.glyphColor
                    opacity: root.playing ? 0.9 : 0.45

                    SequentialAnimation on height {
                      running: root.playing
                      loops: Animation.Infinite
                      NumberAnimation { to: liveVis.height * (0.35 + (index % 5) * 0.16); duration: 170 + index * 30; easing.type: Easing.OutQuad }
                      NumberAnimation { to: liveVis.height * (0.16 + (index % 4) * 0.12); duration: 170 + index * 30; easing.type: Easing.InQuad }
                    }
                  }
                }
              }
            }

            Text {
              id: timeEnd
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.seekEnd > 0 ? Model.formatTime(root.seekEnd) : "LIVE"
              color: Qt.darker(root.fg, 1.4)
              font.family: root.fam
              font.pixelSize: Style.font.caption
              width: Style.space(46)
              horizontalAlignment: Text.AlignRight
            }
          }

          // ------------------------------------------------------- transport
          Item {
            width: parent.width
            implicitHeight: Math.max(transportRow.implicitHeight, modesRow.implicitHeight)
            visible: !root.down && root.hasTrack

            Row {
              id: transportRow
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.controlGap

              Button {
                id: prevB
                iconText: "󰒮"
                foreground: root.fg
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: if (root.svc) root.svc.run(["prev"])
              }
              Button {
                id: playB
                iconText: root.playing ? "󰏤" : "󰐊"
                foreground: root.fg
                horizontalPadding: Style.spacing.panelGap
                verticalPadding: Style.spacing.controlPaddingY
                iconSize: Style.font.iconLarge
                onClicked: if (root.svc) root.svc.run(["toggle"])
              }
              Button {
                id: stopB
                iconText: "\uf04d"
                foreground: root.fg
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: if (root.svc) root.svc.run(["stop"])
              }
              Button {
                id: nextB
                iconText: "󰒭"
                foreground: root.fg
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: if (root.svc) root.svc.run(["next"])
              }
            }

            Row {
              id: modesRow
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.controlGap

              Button {
                iconText: "\uf074"
                foreground: root.fg
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                selected: root.snap.shuffle
                tooltipText: "Shuffle"
                onClicked: if (root.svc) root.svc.run(["shuffle", "toggle"])
              }
              Button {
                iconText: "\uf01e"
                text: root.snap.repeat === "One" ? "1" : "All"
                foreground: root.fg
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                selected: root.snap.repeat !== "Off"
                tooltipText: "Repeat: " + root.snap.repeat
                onClicked: root.cycleRepeat()
              }
              Button {
                text: "Mono"
                foreground: root.fg
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                selected: root.snap.mono
                tooltipText: "Mono output"
                onClicked: if (root.svc) root.svc.run(["mono", "toggle"])
              }
            }
          }

          // ---------------------------------------------------------- volume
          Row {
            width: parent.width
            spacing: Style.spacing.controlGap
            visible: !root.down && root.hasTrack

            OpticalGlyph {
              anchors.verticalCenter: parent.verticalCenter
              fontFamily: root.fam
              fontSize: Style.font.body
              text: "\uf028"
              color: root.fg
              width: Style.space(20)
            }

            PanelSlider {
              id: volSlider
              bar: root.bar
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(20) - volLabel.width - Style.spacing.controlGap * 2
              minimum: Model.VOL_MIN
              maximum: Model.VOL_MAX
              step: 1
              integer: true
              tickCount: 0
              value: root.snap.volume
              onReleased: function(v) {
                if (root.svc) root.svc.run(["volume", String(v)])
              }
              onRightClicked: if (root.svc) root.svc.run(["volume", String(Model.VOL_MIN)])
            }

            Text {
              id: volLabel
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: Model.volumeLabel(root.snap.volume)
              color: Qt.darker(root.fg, 1.4)
              font.family: root.fam
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator {
            foreground: root.fg
            visible: !root.down
          }

          // -------------------------------------------------------- playlist
          Column {
            width: parent.width
            visible: !root.down
            spacing: Style.spacing.labelGap * 2

            Item {
              width: parent.width
              implicitHeight: refreshBtn.implicitHeight

              PanelSectionHeader {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                foreground: root.fg
                text: "Favourites"
                width: refreshBtn.x - Style.space(8)
                elide: Text.ElideRight
              }

              Button {
                id: refreshBtn
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: "\uf021"
                foreground: root.fg
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: 2
                tooltipText: "Refresh favourites"
                onClicked: root.refresh()
              }
            }

            Flickable {
              id: queueFlick
              width: parent.width
              height: Math.min(root.favoriteRows.length * Style.space(30) + (root.favoriteRows.length > 0 ? Style.space(2) : 0), Style.space(300))
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              contentHeight: root.favoriteRows.length * Style.space(30)

              Column {
                width: parent.width
                spacing: 0

                Repeater {
                  model: root.favoriteRows

                  BorderSurface {
                    id: trackRow
                    required property var modelData
                    required property int index

                    readonly property var track: modelData
                    readonly property bool current: root.hasTrack &&
                      track.path !== "" && track.path === root.snap.track.path

                    width: queueFlick.width
                    height: Style.space(30)
                    radius: Style.spacing.labelGap
                    color: current ? Style.selectedFillFor(root.fg, Color.accent) : "transparent"
                    borderSpec: current ? Border.controlSpec("normal", root.fg, Color.accent) : Border.none()

                    Row {
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.leftMargin: Style.space(8)
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.spacing.controlGap

                      Text {
                        width: Style.space(18)
                        textFormat: Text.PlainText
                        text: trackRow.current ? "󰐊" : (trackRow.track.index + 1)
                        color: trackRow.current ? Color.accent : Qt.darker(root.fg, 1.4)
                        font.family: root.fam
                        font.pixelSize: Style.font.bodySmall
                        horizontalAlignment: Text.AlignHCenter
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Column {
                        width: parent.width - Style.space(18) - durationLabel.width - Style.spacing.controlGap * 2
                        spacing: Style.space(1)
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                          width: parent.width
                          textFormat: Text.PlainText
                          text: trackRow.track.title
                          color: root.fg
                          font.family: root.fam
                          font.pixelSize: Style.font.bodySmall
                          font.bold: trackRow.current
                          elide: Text.ElideRight
                        }
                        Text {
                          width: parent.width
                          textFormat: Text.PlainText
                          text: trackRow.track.stream ? "favourite stream" : "favourite"
                          color: Qt.darker(root.fg, 1.5)
                          font.family: root.fam
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideRight
                        }
                      }

                      Text {
                        id: durationLabel
                        anchors.verticalCenter: parent.verticalCenter
                        textFormat: Text.PlainText
                        text: trackRow.track.stream ? "LIVE" : ""
                        color: Qt.darker(root.fg, 1.6)
                        font.family: root.fam
                        font.pixelSize: Style.font.caption
                        width: Style.space(40)
                        horizontalAlignment: Text.AlignRight
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        if (!root.svc) return
                        root.svc.run(["remote", "call", "url.load", "--params",
                          JSON.stringify({ path: trackRow.track.path, play: true })])
                      }
                    }
                  }
                }
              }
            }

            Text {
              width: parent.width
              visible: root.favoriteRows.length === 0
              textFormat: Text.PlainText
              text: "No favourites yet — favourite a track in cliamp"
              color: Qt.darker(root.fg, 1.5)
              font.family: root.fam
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }

          PanelSeparator {
            foreground: root.fg
            visible: !root.down
          }

          // ------------------------------------------------------------ footer
          Item {
            width: parent.width
            implicitHeight: Math.max(footerCol.implicitHeight, buttonsRow.implicitHeight)

            Column {
              id: footerCol
              anchors.left: parent.left
              anchors.right: buttonsRow.left
              anchors.rightMargin: Style.spacing.controlGap
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Row {
                spacing: Style.space(3)
                Repeater {
                  model: root.snap.eqBands.length
                  delegate: Rectangle {
                    required property int index
                    width: Style.space(3)
                    height: Math.max(2, Math.min(12, Math.abs(root.snap.eqBands[index] || 0) * 0.9))
                    radius: 1
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.fg
                    opacity: root.down ? 0.35 : 0.85
                  }
                }
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.down ? "Cliamp daemon offline"
                  : "EQ " + root.snap.eqPreset + " · speed " + root.snap.speed.toFixed(2) + "x · " + root.favoriteRows.length + " favourites"
                color: Qt.darker(root.fg, 1.5)
                font.family: root.fam
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Row {
              id: buttonsRow
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.controlGap

              Button {
                id: stopDaemonB
                iconText: "\uf011"
                text: "Stop daemon"
                visible: !root.down
                foreground: root.bar ? root.bar.urgent : Color.urgent
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                tooltipText: "Stop the cliamp daemon"
                onClicked: root.stopDaemon()
              }
              Button {
                iconText: "\uf120"
                text: "Open cliamp"
                foreground: root.fg
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.openTui()
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------------ utils

  function cycleRepeat() {
    if (!root.svc) return
    var r = root.snap.repeat
    var n = r === "Off" ? "All" : (r === "All" ? "One" : "Off")
    root.svc.run(["repeat", n])
  }
}