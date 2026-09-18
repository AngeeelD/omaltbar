import QtQuick
import Quickshell
import Quickshell.Networking
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import Quickshell.Services.Mpris
import Quickshell.Services.UPower
// Reuse the first-party panels' own parsers and icon maps instead of vendoring
// copies that would drift — the same absolute file-URL idiom the island's
// ClockWeatherView already uses for the weather Model.js.
import "file:///usr/share/omarchy/shell/plugins/panels/network/Model.js" as NetworkModel
import "file:///usr/share/omarchy/shell/plugins/panels/power/Model.js" as PowerModel

// Non-visual, read-only projection of the four status sources the indicator
// row's circles render: Wi-Fi (NetworkManager), battery (UPower), Bluetooth
// (BlueZ) and the music meter (MPRIS transport + PipeWire output peak). Pure
// data — PillStatusDial owns all painting — so the row stays a thin consumer
// of the same live services the quick-settings panel reads.
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

  // ------------------------------------------------------------- bluetooth
  // The singleton is reached through an untyped alias on purpose: qmllint
  // resolves `Bluetooth.defaultAdapter` / `.devices` to types it cannot find
  // (the three unresolved-type warnings QuickSettingsView already carries) and
  // the alias keeps that duplicate noise out of a new file. The dynamic-var
  // idiom is the one this plugin uses for every other service handle too.
  readonly property var btPlugin: Bluetooth
  readonly property var btAdapter: btPlugin ? btPlugin.defaultAdapter : null
  readonly property var btDevices: btPlugin && btPlugin.devices ? btPlugin.devices.values : []

  readonly property var btConnectedDevice: {
    for (var i = 0; i < btDevices.length; i++) {
      var d = btDevices[i]
      if (d && d.connected === true) return d
    }
    return null
  }

  readonly property int btConnectedCount: {
    var count = 0
    for (var i = 0; i < btDevices.length; i++)
      if (btDevices[i] && btDevices[i].connected === true) count++
    return count
  }

  // Powered radios only count as available: the circle dims when there is no
  // adapter, or when the adapter is off/blocked (see the failure table).
  readonly property bool btAvailable: !!btAdapter && btAdapter.enabled === true

  // 0..1 ring fill with no signal reading behind it: a full ring while a
  // device is connected, empty otherwise.
  readonly property real btFraction: btAvailable && btConnectedCount > 0 ? 1 : 0

  readonly property var btState: ({
    available: btAvailable,
    connected: btConnectedCount > 0,
    count: btConnectedCount,
    fraction: btFraction,
    glyph: !btAdapter || btAdapter.enabled !== true
      ? "󰂲"
      : (btConnectedCount > 0 ? "󰂱" : "󰂯")
  })

  // ----------------------------------------------------------- music meter
  // MPRIS owns "is anything playing"; PipeWire owns the output level behind it
  // (the default sink's live peak, the same reading the audio panel exposes).
  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []

  readonly property bool mediaPlaying: {
    for (var i = 0; i < mprisPlayers.length; i++) {
      var p = mprisPlayers[i]
      if (p && p.isPlaying === true) return true
    }
    return false
  }

  readonly property var audioSink: Pipewire.defaultAudioSink
  readonly property var sinkAudio: audioSink ? audioSink.audio : null

  readonly property real meterLevel: {
    if (!sinkAudio) return 0
    var peak = Number(sinkAudio.peak)
    if (!isFinite(peak)) return 0
    return Math.max(0, Math.min(1, peak))
  }

  // `playing: false` ⇒ the row omits the meter dial entirely (see
  // PillIndicatorRow). `level` is the live 0..1 peak while it is shown.
  readonly property var meterState: ({
    playing: mediaPlaying,
    level: meterLevel
  })
}
