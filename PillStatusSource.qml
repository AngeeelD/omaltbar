import QtQuick
import Quickshell
import Quickshell.Networking
import Quickshell.Services.UPower
// Reuse the first-party panels' own parsers and icon maps instead of vendoring
// copies that would drift — the same absolute file-URL idiom the island's
// ClockWeatherView already uses for the weather Model.js.
import "file:///usr/share/omarchy/shell/plugins/panels/network/Model.js" as NetworkModel
import "file:///usr/share/omarchy/shell/plugins/panels/power/Model.js" as PowerModel

// Non-visual, read-only projection of the two status sources the pill's
// right-click template renders: Wi-Fi (NetworkManager) and battery (UPower).
// Pure data — PillStatusDial owns all painting — so the pill stays a thin
// consumer of the same live services the quick-settings panel reads.
Item {
  id: root

  // ------------------------------------------------------------------ wifi
  readonly property bool networkManagerAvailable: Networking.backend === NetworkBackendType.NetworkManager
  readonly property var devices: Networking.devices ? Networking.devices.values : []

  readonly property var wifiDevice: {
    var fallback = null
    for (var i = 0; i < devices.length; i++) {
      var d = devices[i]
      if (!d || d.type !== DeviceType.Wifi) continue
      if (d.connected) return d
      if (!fallback) fallback = d
    }
    return fallback
  }

  readonly property var connectedWifi: {
    var nets = wifiDevice && wifiDevice.networks ? wifiDevice.networks.values : []
    for (var i = 0; i < nets.length; i++)
      if (nets[i] && nets[i].connected) return nets[i]
    return null
  }

  // -1 when there is no live Wi-Fi reading (radio off / not connected).
  readonly property int wifiSignal: connectedWifi
    ? Math.round((connectedWifi.signalStrength || 0) * 100)
    : -1

  readonly property string wifiKind: {
    for (var i = 0; i < devices.length; i++) {
      var d = devices[i]
      if (d && d.type === DeviceType.Wired && d.connected) return "ethernet"
    }
    if (connectedWifi) return "wifi"
    return "disconnected"
  }

  readonly property string wifiGlyph: NetworkModel.connectionIcon(wifiKind, wifiSignal)
  // 0..1 ring fill for the dial.
  readonly property real wifiFraction: wifiSignal >= 0 ? wifiSignal / 100 : 0

  // --------------------------------------------------------------- battery
  readonly property var battery: UPower.displayDevice
  readonly property bool batteryPresent: !!(battery && battery.isPresent)
  readonly property real batteryFraction: PowerModel.batteryFraction(battery)
  readonly property int batteryPercent: Math.round(batteryFraction * 100)
  readonly property bool onBattery: UPower.onBattery === true

  // ConnectionFailReason-style plain object: PowerModel stays pure JS.
  readonly property var upowerStates: ({
    Charging: UPowerDeviceState.Charging,
    Discharging: UPowerDeviceState.Discharging,
    FullyCharged: UPowerDeviceState.FullyCharged,
    PendingCharge: UPowerDeviceState.PendingCharge
  })

  readonly property string batteryGlyph: PowerModel.batteryIcon(battery, onBattery, upowerStates)
}
