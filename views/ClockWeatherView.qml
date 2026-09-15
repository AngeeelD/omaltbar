import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "file:///usr/share/omarchy/shell/plugins/panels/weather/Model.js" as Weather

// Native island view for "omarchy.clock" — a large clock with the full date,
// plus live current conditions when a weather location is configured.
//
// Weather reuses the shell's own weather Model.js (the same parser/icon
// mapping the omarchy.weather panel uses) and queries Open-Meteo with the
// stored coordinates. With no location or a failed fetch there is simply no
// weather line: nothing is fabricated.
Column {
  id: root

  // Injected by DynamicIsland so views can react to island state later, and so
  // the °C/°F toggle can persist the choice through the bar's shell config API.
  property var islandState: null
  property var islandBar: null

  spacing: Style.spacing.sm

  // The clock is the hero of this view; larger than the shared display-large
  // token but still derived from it, so themes keep scaling it.
  readonly property int clockSize: Math.round(Style.font.displayLarge * 1.5)

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
  }

  readonly property string clockText: Qt.formatDateTime(clock.date, "HH:mm")
  readonly property string dateText: Qt.formatDateTime(clock.date, "dddd, d MMMM yyyy")

  // --- live weather -------------------------------------------------------
  property var weatherLocation: ({ name: "", latitude: null, longitude: null })
  property var weatherCurrent: null

  readonly property bool hasWeather: weatherCurrent !== null
  // Unit preference: "" follows the locale (the upstream panel's own default).
  // The click toggle persists "metric"/"imperial" in the bar config, so the
  // choice survives a restart without this view owning any file.
  readonly property string unitSetting:
    root.islandBar ? String(root.islandBar.weatherUnit || "") : ""
  readonly property bool useImperial:
    Weather.shouldUseImperial(unitSetting, Qt.locale().name, "")
  readonly property string unitLetter: root.useImperial ? "F" : "C"
  readonly property string weatherTemp: weatherCurrent
    ? Weather.formatTemp(useImperial ? weatherCurrent.temp_F : weatherCurrent.temp_C, useImperial)
    : ""
  readonly property string weatherIcon: weatherCurrent ? Weather.currentIcon(weatherCurrent) : ""
  // Same slot the loaded reading fills, so the lazy fetch never reflows the
  // view: the placeholder reserves the line and shows which unit is active.
  readonly property string placeholderTemp: "--°" + root.unitLetter

  function toggleUnit() {
    var host = root.islandBar
    if (!host || typeof host.setWeatherUnit !== "function") return
    host.setWeatherUnit(root.useImperial ? "metric" : "imperial")
  }

  function refreshWeather() {
    var lat = parseFloat(String(weatherLocation.latitude))
    var lon = parseFloat(String(weatherLocation.longitude))
    if (isNaN(lat) || isNaN(lon)) return

    var url = "https://api.open-meteo.com/v1/forecast"
      + "?latitude=" + encodeURIComponent(String(lat))
      + "&longitude=" + encodeURIComponent(String(lon))
      + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"
      + "&timezone=auto"
    weatherProc.command = ["curl", "-fsS", "--max-time", "5", url]
    weatherProc.running = true
  }

  function applyWeather(raw) {
    try {
      var report = JSON.parse(String(raw || ""))
      var current = Weather.openMeteoCurrentCondition(report)
      // Keep the previous reading on a failed/partial response.
      if (current) root.weatherCurrent = current
    } catch (e) {
    }
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.weatherLocation = Weather.parseLocationFile(text())
      root.refreshWeather()
    }
    onFileChanged: {
      root.weatherLocation = Weather.parseLocationFile(text())
      root.refreshWeather()
    }
    onLoadFailed: root.weatherLocation = Weather.parseLocationFile("")
  }

  Process {
    id: weatherProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyWeather(text)
    }
  }

  Timer {
    interval: 15 * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.refreshWeather()
  }

  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    text: root.clockText
    color: Color.bar.text
    font.family: Style.font.family
    font.pixelSize: root.clockSize
    font.weight: Font.DemiBold
  }

  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    text: root.dateText
    color: Util.alpha(Color.bar.text, 0.7)
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  // Fixed slot, never visibility-gated: the weather arrives lazily (FileView +
  // curl), and hiding this row until then would push the separator and deck
  // below it down the moment data lands. The row is present from the first
  // frame with a dimmed placeholder, so the layout above and below it is
  // static. Clicking toggles °C/°F.
  //
  // The click target is a SIBLING of the Row, not a child: a MouseArea with
  // anchors.fill inside a positioner is an anchor on the axis the Row manages,
  // which disables the Row and collapsed the whole line.
  Item {
    id: weatherSlot
    anchors.horizontalCenter: parent.horizontalCenter
    // A plain Item's width/height default to 0: implicitWidth alone sizes
    // nothing, so the click target (and the centering) must be explicit or the
    // MouseArea ends up a few pixels wide and the toggle never fires.
    implicitWidth: weatherRow.implicitWidth
    implicitHeight: weatherRow.implicitHeight
    width: weatherRow.implicitWidth
    height: weatherRow.implicitHeight

    Row {
      id: weatherRow
      spacing: Style.space(6)

      Text {
        id: weatherIconText
        anchors.verticalCenter: parent.verticalCenter
        text: root.hasWeather ? root.weatherIcon : "󰖐"
        opacity: root.hasWeather ? 1.0 : 0.4
        color: Color.bar.text
        font.family: Style.font.family
        font.pixelSize: Style.font.title
      }

      Text {
        id: weatherTempText
        anchors.verticalCenter: parent.verticalCenter
        text: root.hasWeather ? root.weatherTemp : root.placeholderTemp
        opacity: root.hasWeather ? 1.0 : 0.55
        color: Util.alpha(Color.bar.text, 0.85)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    MouseArea {
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleUnit()
    }
  }
}
