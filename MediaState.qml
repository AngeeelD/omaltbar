import QtQuick
import Quickshell
import Quickshell.Services.Mpris

// Single source of truth for MPRIS "now playing" inside the island.
//
// One instance lives on the bar root (NotchIslandBar.qml) and is shared by
// the collapsed-pill mini-player and the full MusicView, so both render the
// same track without duplicating player-selection rules.
//
// This reads Quickshell's MPRIS service directly rather than the first-party
// `omarchy.media` service: that service ships as a "service" plugin but is
// disabled on stock installs, so `shell.firstPartyServiceFor("omarchy.media")`
// returns null. The audio panel adds it opportunistically too
// (plugins/panels/audio/Panel.qml imports Quickshell.Services.Mpris).
Item {
  id: root

  // Pure state holder: never paints.
  visible: false

  readonly property var players: Mpris.players ? Mpris.players.values : []

  // A player with a live track wins over a merely-controlled one. Prefer a
  // playing player, then any player exposing track metadata, so the empty
  // state only appears when nothing meaningful is available.
  readonly property var activePlayer: selectPlayer()

  readonly property bool hasMedia: activePlayer !== null
  readonly property bool playing: activePlayer !== null && activePlayer.isPlaying

  readonly property string title: activePlayer ? (activePlayer.trackTitle || "") : ""
  readonly property string artist: activePlayer ? (activePlayer.trackArtist || "") : ""
  readonly property string album: activePlayer ? (activePlayer.trackAlbum || "") : ""
  readonly property string artUrl: activePlayer ? (activePlayer.trackArtUrl || "") : ""
  readonly property string identity: activePlayer ? (activePlayer.identity || activePlayer.desktopEntry || "") : ""

  function selectPlayer() {
    var playingWithTrack = null
    var playing = null
    var withTrack = null

    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p) continue
      var hasTrack = !!(p.trackTitle || p.trackArtist)
      if (hasTrack && !withTrack) withTrack = p
      if (p.isPlaying) {
        if (!playing) playing = p
        if (hasTrack && !playingWithTrack) playingWithTrack = p
      }
    }

    // Not playing and without metadata: not worth showing as "now playing".
    return playingWithTrack || playing || withTrack
  }
}
