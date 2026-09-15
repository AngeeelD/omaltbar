import QtQuick
import qs.Commons

// Native island view for "island.mediaPeek" — the slim now-playing strip the
// island peeks open when playback changes on its own: play/pause, a new track,
// or a video/ad swapping the metadata.
//
// Deliberately one row, no transport, no seek bar. It appears over content the
// user is already watching, so it must not cover anything or invite
// interaction. The full MusicView remains the reward for asking: it is what the
// resolved "omarchy.media" page shows when the user reaches for the pill.
Row {
  id: root

  // Injected by DynamicIsland, like every other native view.
  property var mediaState: null
  property var islandState: null
  property var islandBar: null

  readonly property color foreground: islandBar ? islandBar.foreground : Color.foreground
  readonly property string fontFamily: islandBar ? islandBar.fontFamily : Style.font.family
  readonly property string title: mediaState ? String(mediaState.title || "") : ""
  readonly property string artist: mediaState ? String(mediaState.artist || "") : ""
  readonly property string artUrl: mediaState ? String(mediaState.artUrl || "") : ""
  readonly property bool playing: mediaState ? mediaState.playing === true : false

  spacing: Style.space(10)

  Item {
    width: Math.round(Style.space(34))
    height: width
    visible: root.artUrl !== ""

    Image {
      anchors.fill: parent
      source: root.artUrl
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      sourceSize.width: Math.round(parent.width * 2)
      sourceSize.height: Math.round(parent.height * 2)
    }
  }

  Item {
    width: Math.min(Style.space(240), Math.max(titleText.implicitWidth, artistText.implicitWidth))
    height: Math.round(Style.space(34))

    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      spacing: 0

      Text {
        id: titleText
        width: parent.width
        text: root.title !== "" ? root.title : "Now playing"
        color: root.foreground
        elide: Text.ElideRight
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        id: artistText
        width: parent.width
        text: root.artist
        color: root.foreground
        opacity: 0.6
        visible: text !== ""
        elide: Text.ElideRight
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  Item {
    width: Style.font.icon
    height: Math.round(Style.space(34))

    Text {
      anchors.centerIn: parent
      text: root.playing ? "󰏤" : "󰐊"
      color: root.foreground
      opacity: 0.8
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }
  }
}
