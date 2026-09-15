import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import qs.Commons
import qs.Ui

// Native island view for "omarchy.media" — a compact now-playing card sized
// for the expanded island (~480px wide body). Reads the shared MediaState
// instance owned by the bar root, so it never re-implements player selection.
Column {
  id: root

  // Injected by DynamicIsland. The shared MPRIS state holder.
  property var mediaState: null
  // Kept for parity with the other native views; unused today.
  property var islandState: null

  readonly property var player: mediaState ? mediaState.activePlayer : null
  readonly property bool hasMedia: mediaState ? mediaState.hasMedia : false

  // Seek is only offered when the player both advertises a position and
  // lets it be written (Quickshell: position may only be set when canSeek
  // and positionSupported are true).
  readonly property bool seekable: !!player && player.canSeek && player.positionSupported && player.lengthSupported
  readonly property real trackLength: seekable ? Math.max(0, player.length) : 0

  // Drag state for the scrubber. While dragging, the local value wins over
  // the player's reported position so the thumb tracks the pointer.
  property bool dragging: false
  property real dragPosition: 0
  readonly property real shownPosition: {
    if (!player) return 0
    if (dragging) return dragPosition
    var p = player.position
    return isFinite(p) && p > 0 ? p : 0
  }

  spacing: Style.spacing.md

  // One position update per second while a track actually plays. Quickshell
  // does not push position reactively by default; the documented idiom is to
  // emit positionChanged() while monitoring it.
  Timer {
    running: !!root.player && root.player.playbackState === MprisPlaybackState.Playing
    interval: 1000
    repeat: true
    onTriggered: if (root.player) root.player.positionChanged()
  }

  function mmss(seconds) {
    var total = Math.max(0, Math.floor(Number(seconds) || 0))
    var minutes = Math.floor(total / 60)
    var secs = total % 60
    return minutes + ":" + (secs < 10 ? "0" : "") + secs
  }

  function togglePlay() {
    var p = root.player
    if (!p) return
    if (p.isPlaying && p.canPause) p.pause()
    else if (!p.isPlaying && p.canPlay) p.play()
    else if (p.canTogglePlaying) p.togglePlaying()
  }

  function updateDrag(x) {
    if (!root.seekable || trackBar.width <= 0) return
    var ratio = Math.max(0, Math.min(1, x / trackBar.width))
    root.dragPosition = ratio * root.trackLength
  }

  // --- empty state: no player at all -------------------------------------
  Column {
    id: emptyColumn
    visible: !root.hasMedia
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: Style.spacing.sm

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "󰝚"
      color: Util.alpha(Color.bar.text, 0.7)
      font.family: Style.font.family
      font.pixelSize: Style.font.display
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "No playback"
      color: Color.bar.text
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      font.weight: Font.Medium
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "Start something to see it here"
      color: Util.alpha(Color.bar.text, 0.55)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
  }

  // --- now-playing layout -------------------------------------------------
  Column {
    id: layoutColumn
    visible: root.hasMedia
    width: parent.width
    spacing: Style.spacing.sm

    Row {
      width: parent.width
      spacing: Style.spacing.md

      Rectangle {
        id: cover
        width: Style.space(88)
        height: Style.space(88)
        radius: Style.spacing.labelGap
        color: Util.alpha(Color.bar.text, 0.10)
        clip: true

        Image {
          anchors.fill: parent
          anchors.margins: Style.space(1)
          asynchronous: true
          fillMode: Image.PreserveAspectCrop
          source: root.player && root.player.trackArtUrl ? root.player.trackArtUrl : ""
          visible: status === Image.Ready
        }

        Text {
          anchors.centerIn: parent
          visible: !root.player || !root.player.trackArtUrl
          text: "󰝚"
          color: Color.bar.text
          font.family: Style.font.family
          font.pixelSize: Style.font.displayLarge
        }
      }

      Column {
        width: parent.width - cover.width - parent.spacing
        spacing: Style.spacing.xxs
        anchors.verticalCenter: parent.verticalCenter

        Text {
          width: parent.width
          text: root.player ? (root.player.trackTitle || "Unknown Title") : ""
          color: Color.bar.text
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.weight: Font.DemiBold
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: text !== ""
          text: root.player ? (root.player.trackArtist || "") : ""
          color: Util.alpha(Color.bar.text, 0.8)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: text !== ""
          text: root.player ? (root.player.identity || root.player.desktopEntry || "") : ""
          color: Util.alpha(Color.bar.text, 0.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    // Scrubber. Read-only unless the player allows both reading and writing
    // position; a click/drag outside that support does nothing.
    Item {
      width: parent.width
      height: Style.space(16)

      Rectangle {
        id: trackBar
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: Style.space(4)
        radius: height / 2
        color: Util.alpha(Color.bar.text, 0.18)
      }

      Rectangle {
        anchors.verticalCenter: trackBar.verticalCenter
        width: root.trackLength > 0 ? trackBar.width * Math.min(1, root.shownPosition / root.trackLength) : 0
        height: trackBar.height
        radius: trackBar.radius
        color: Color.accent
      }

      MouseArea {
        anchors.fill: parent
        enabled: root.seekable
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor

        onPressed: function(mouse) {
          root.dragging = true
          root.updateDrag(mouse.x)
        }
        onPositionChanged: function(mouse) {
          if (root.dragging) root.updateDrag(mouse.x)
        }
        onReleased: function(mouse) {
          if (!root.dragging) return
          root.updateDrag(mouse.x)
          if (root.player) root.player.position = root.dragPosition
          root.dragging = false
        }
        onCanceled: root.dragging = false
      }
    }

    Row {
      width: parent.width

      Text {
        id: positionText
        text: root.mmss(root.shownPosition)
        color: Util.alpha(Color.bar.text, 0.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Item {
        width: Math.max(0, parent.width - positionText.width - durationText.width)
        height: 1
      }

      Text {
        id: durationText
        text: root.trackLength > 0 ? root.mmss(root.trackLength) : "--:--"
        color: Util.alpha(Color.bar.text, 0.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.spacing.md

      Button {
        iconText: "󰒮"
        foreground: Color.bar.text
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        enabled: !!root.player && root.player.canGoPrevious
        opacity: enabled ? 1.0 : 0.4
        onClicked: if (root.player) root.player.previous()
      }

      Button {
        iconText: root.player && root.player.isPlaying ? "󰏤" : "󰐊"
        foreground: Color.bar.text
        iconSize: Style.font.iconLarge
        horizontalPadding: Style.spacing.panelGap
        verticalPadding: Style.spacing.controlPaddingY
        enabled: !!root.player && (root.player.canTogglePlaying || root.player.canPlay || root.player.canPause)
        opacity: enabled ? 1.0 : 0.4
        onClicked: root.togglePlay()
      }

      Button {
        iconText: "󰒭"
        foreground: Color.bar.text
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        enabled: !!root.player && root.player.canGoNext
        opacity: enabled ? 1.0 : 0.4
        onClicked: if (root.player) root.player.next()
      }
    }
  }
}
