import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
// Reuse the first-party panels' own parsers and icon maps instead of vendoring
// copies that would drift — the same absolute file-URL idiom ClockWeatherView
// already uses for the weather Model.js.
import "file:///usr/share/omarchy/shell/plugins/panels/audio/Model.js" as AudioModel
import "file:///usr/share/omarchy/shell/plugins/panels/network/Model.js" as NetworkModel
import "file:///usr/share/omarchy/shell/plugins/panels/bluetooth/Model.js" as BluetoothModel
import "file:///usr/share/omarchy/shell/plugins/panels/power/Model.js" as PowerModel

// Native island view shared by the four quick-settings widgets
// (omarchy.audio, omarchy.network, omarchy.bluetooth, omarchy.power).
//
// It is deliberately ONE combined panel: each of those bar icons only carries
// a single toggle plus a short readout, and four near-identical notch-scale
// popups would be more chrome than content. DynamicIsland registers this same
// view for all four ids, so clicking any of the four island icons opens it.
//
// Every value comes from the live Quickshell services the first-party panels
// read; a block whose backend is missing renders an honest read-only state
// instead of inventing data.
//
// The Wi-Fi and Bluetooth device lists below are wired to the exact calls
// panels/network/Panel.qml and panels/bluetooth/Panel.qml use (connect,
// connectWithPsk, disconnect, omarchy-bluetooth-power/-device), with the rows
// kept as primitive projections so NetworkManager/BlueZ churn cannot leave a
// dangling QObject wrapper in a delegate.
Column {
  id: root

  // Injected by DynamicIsland.
  property var islandState: null
  property var islandBar: null

  readonly property color fg: Color.bar.text
  readonly property color dim: Util.alpha(Color.bar.text, 0.6)

  // ------------------------------------------------- control exclusions (R5)
  // The default page's deck controls can be dragged out and restored from the
  // collapsible "Excluded (N)" header, reusing the widget grid's exact drag
  // vocabulary. The set is owned and persisted by the bar root (through the
  // shell config API, so shell.json keeps its single writer); this view only
  // reads it and asks the bar to change it. Editing is gated to the composed
  // default page: the same deck shown as a standalone system view renders every
  // control instead.
  readonly property var excludedControlIds: root.islandBar ? root.islandBar.excludedControlIds : []
  readonly property bool deckEditable: !!root.islandState
    && root.islandState.displayedContext === "island.default"
  property bool excludedOpen: false

  function controlHidden(id) {
    if (!root.deckEditable) return false
    return root.excludedControlIds.indexOf(String(id || "")) !== -1
  }

  function setControlHidden(id, hidden) {
    var host = root.islandBar
    if (host && typeof host.setControlHidden === "function")
      host.setControlHidden(String(id || ""), hidden === true)
  }

  readonly property var controlLabels: ({
    "audio": "Audio",
    "audioOutput": "Audio output",
    "brightness": "Brightness",
    "battery": "Battery",
    "powerProfile": "Power profile",
    "nightlight": "Night light",
    "stayAwake": "Stay awake",
    "microphone": "Microphone",
    "notifications": "Notifications",
    "wifiToggle": "Wi-Fi",
    "btToggle": "Bluetooth",
    "wifiList": "Wi-Fi networks",
    "btList": "Bluetooth devices"
  })

  function controlLabel(id) {
    var key = String(id || "")
    return root.controlLabels[key] !== undefined ? root.controlLabels[key] : key
  }

  // Block visibility: a block whose every control is excluded collapses, and the
  // separators between blocks key off these so no stray hairline is left behind.
  readonly property bool deckAudioVisible: !root.controlHidden("audio")
  readonly property bool deckAudioOutputVisible: !root.controlHidden("audioOutput")
  readonly property bool deckBrightnessVisible: !root.controlHidden("brightness")
  readonly property bool deckBatteryVisible: !root.controlHidden("battery")
  readonly property bool deckPowerVisible: root.profiles.length > 0 && !root.controlHidden("powerProfile")
  readonly property bool deckNightlightVisible: !root.controlHidden("nightlight")
  readonly property bool deckStayAwakeVisible: !root.controlHidden("stayAwake")
  readonly property bool deckMicVisible: !root.controlHidden("microphone")
  readonly property bool deckNotificationsVisible: !root.controlHidden("notifications")
  readonly property bool deckWifiToggleVisible: !root.controlHidden("wifiToggle")
  readonly property bool deckBtToggleVisible: !root.controlHidden("btToggle")
  readonly property bool deckWifiListVisible: !root.controlHidden("wifiList")
  readonly property bool deckBtListVisible: !root.controlHidden("btList")
  readonly property bool deckAnyToggleVisible: root.deckWifiToggleVisible || root.deckBtToggleVisible
  readonly property bool deckAnyListVisible: root.deckWifiListVisible || root.deckBtListVisible
  // The Wi-Fi + Bluetooth block (toggle row directly above the list row).
  readonly property bool deckWifiBtBlockVisible: root.deckAnyToggleVisible || root.deckAnyListVisible
  readonly property bool deckAnyStatusToggleVisible: root.deckNightlightVisible
    || root.deckStayAwakeVisible || root.deckMicVisible || root.deckNotificationsVisible

  // One drag affordance for a deck control. It reuses the widget grid's exact
  // gesture: the drag only arms past the threshold, so a plain click still
  // reaches an inner control. The drag source is deliberately a non-interactive
  // surface (a row's label, the power profile caption, a list header), and the
  // volume slider and device lists are siblings rather than children of those
  // surfaces, so the slider drag and the list scroll are never stolen.
  component ControlDrag: DragHandler {
    target: null
    dragThreshold: Style.space(4)
    grabPermissions: PointerHandler.CanTakeOverFromAnything
    required property string controlId
    property bool fromExcluded: false
    enabled: root.deckEditable

    onActiveChanged: {
      if (!root.islandBar) return
      if (active) root.islandBar.beginControlDrag(controlId, fromExcluded)
      else root.islandBar.endWidgetDrag()
    }
    onCentroidChanged: {
      if (!active || !root.islandBar) return
      root.islandBar.updateWidgetDrag(centroid.scenePosition.x, centroid.scenePosition.y)
    }
  }

  spacing: Style.spacing.md

  // ---------------------------------------------------------------- audio
  // Mirrors panels/audio/Panel.qml instead of binding raw.
  //
  // Where the selected output is a DSP filter-chain (a speaker tuning),
  // `Pipewire.defaultAudioSink` is that virtual sink: changing its volume alters
  // the level going INTO the processing, so the slider would move while the
  // speakers did not. `omarchy-audio-output-sink` resolves the current default
  // through any such sink to the physical output the volume keys use, and the
  // slider/mute below drive THAT sink. The output list switches the default
  // through the shell's own CLI, exactly like the upstream panel.
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var candidateSinks: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i]
      if (node && node.isSink && !node.isStream) list.push(node)
    }
    return list
  }
  // A tuning is fronted by a physical sink but is reported unavailable, so it
  // stays out of the switch list (same rule the upstream output switcher uses).
  property var sinkAvailability: ({})
  property bool sinkAvailabilityLoaded: false
  function sinkAvailable(node) {
    if (!node || !node.name || !root.sinkAvailabilityLoaded) return true
    return root.sinkAvailability[String(node.name)] !== false
  }
  readonly property var audioSinks: {
    var list = []
    for (var i = 0; i < root.candidateSinks.length; i++)
      if (root.sinkAvailable(root.candidateSinks[i])) list.push(root.candidateSinks[i])
    if (root.sink && list.indexOf(root.sink) < 0) list.unshift(root.sink)
    return list
  }
  // The Repeater is fed a panel-local snapshot: PipeWire can remove a node while
  // Quickshell dispatches the removal signal, and rebuilding the Repeater from
  // that signal path has crashed the PipeWire service before (see Panel.qml).
  property var displayAudioSinks: []
  // Name of the sink whose volume/mute is real (resolved through any DSP sink).
  property string volumeSinkName: ""
  readonly property var volumeSink: {
    if (root.volumeSinkName === "" || !root.sink) return root.sink
    if (root.volumeSinkName === String(root.sink.name)) return root.sink
    for (var i = 0; i < root.nodes.length; i++) {
      var node = root.nodes[i]
      if (node && node.isSink && !node.isStream
          && String(node.name) === root.volumeSinkName && node.audio) return node
    }
    return root.sink
  }
  readonly property bool hasAudio: !!(volumeSink && volumeSink.audio)
  readonly property real outputVolume: hasAudio ? volumeSink.audio.volume : 0
  readonly property bool outputMuted: hasAudio ? volumeSink.audio.muted === true : false
  readonly property int outputPercent: Math.round(outputVolume * 100)
  readonly property string volumeName: AudioModel.outputVolumeName(outputVolume, outputMuted)
  readonly property string currentSinkName: root.volumeSink ? String(root.volumeSink.name || "") : ""

  function audioIcon() {
    if (!hasAudio || outputMuted) return "󰖁"
    if (outputVolume >= 0.67) return "󰕾"
    if (outputVolume >= 0.34) return "󰖀"
    if (outputVolume > 0) return "󰕿"
    return "󰖁"
  }

  function setOutputVolume(v) {
    if (!hasAudio) return
    root.volumeSink.audio.volume = Math.max(0, Math.min(1, v))
  }

  function toggleOutputMute() {
    if (hasAudio) root.volumeSink.audio.muted = !root.volumeSink.audio.muted
  }

  // Switch the default output exactly as panels/audio/Panel.qml does: set the
  // PipeWire preference AND call the shell CLI, so the resolution above and the
  // rest of the session agree on the new default.
  function setDefaultSink(node) {
    if (!node) return
    Pipewire.preferredDefaultAudioSink = node
    if (node.id !== undefined && node.name)
      Quickshell.execDetached(["omarchy-audio-output-set-default", String(node.id), String(node.name)])
  }

  function resolveVolumeSink() {
    if (!volumeSinkProc.running) volumeSinkProc.running = true
  }

  function refreshDisplayAudioSinks() {
    root.displayAudioSinks = root.audioSinks.slice()
  }

  onSinkChanged: root.resolveVolumeSink()
  onAudioSinksChanged: audioSinkRefreshTimer.restart()

  PwObjectTracker { objects: root.candidateSinks }

  Process {
    id: volumeSinkProc
    command: ["omarchy-audio-output-sink"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.volumeSinkName = String(text).trim()
    }
  }

  Process {
    id: sinkAvailabilityProc
    command: ["omarchy-audio-sink-availability"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.sinkAvailability = AudioModel.parseSinkAvailability(text)
        root.sinkAvailabilityLoaded = true
      }
    }
  }

  Timer {
    id: audioSinkRefreshTimer
    interval: 75
    repeat: false
    onTriggered: root.refreshDisplayAudioSinks()
  }

  // Re-resolve whenever the selected output changes; the periodic tick is the
  // safety net for a tuning being applied or removed underneath us.
  Timer {
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.resolveVolumeSink()
  }

  Timer {
    interval: 5000
    running: root.deckEditable
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!sinkAvailabilityProc.running) sinkAvailabilityProc.running = true
  }

  // ----------------------------------------------------------- brightness
  // Delegated to the shared BrightnessState (the display has no reactive
  // property). The deck slider and the brightness overlay read the same value.
  readonly property var brightnessState: root.islandBar ? root.islandBar.brightnessState : null
  readonly property bool brightnessAvailable: !!brightnessState && brightnessState.available === true
  readonly property int brightnessPercent: brightnessAvailable ? brightnessState.percent : 0

  function setBrightness(value) {
    if (brightnessState) brightnessState.setBrightness(value)
  }

  // ------------------------------------------------- night light / idle / mic
  // Same first-party services the shell's own bar indicators use; the resolver
  // exposes them so the deck and the auto-context agree on one reading.
  readonly property var contextResolver: root.islandBar ? root.islandBar.contextResolverState : null
  readonly property bool nightlightEnabled:
    !!contextResolver && contextResolver.nightlightEnabled === true
  readonly property bool stayAwake:
    !!contextResolver && contextResolver.stayAwake === true
  readonly property bool doNotDisturb:
    !!contextResolver && contextResolver.doNotDisturb === true
  readonly property int notificationCount:
    contextResolver ? contextResolver.notificationCount : 0
  readonly property bool microphoneMuted:
    contextResolver ? contextResolver.microphoneMuted === true : true
  readonly property bool microphoneInUse:
    contextResolver ? contextResolver.microphoneInUse === true : false

  function toggleMicrophoneMute() {
    var src = Pipewire.defaultAudioSource
    if (src && src.audio) src.audio.muted = !src.audio.muted
  }

  function toggleNightlight() {
    if (contextResolver) contextResolver.toggleNightlight()
  }

  function toggleStayAwake() {
    if (contextResolver) contextResolver.toggleStayAwake()
  }

  function toggleDoNotDisturb() {
    if (contextResolver) contextResolver.toggleDoNotDisturb()
  }

  // ----------------------------------------------------------------- wifi
  // Same NetworkManager backend the network panel uses.
  readonly property bool networkManagerAvailable: Networking.backend === NetworkBackendType.NetworkManager
  readonly property var networkDevices: Networking.devices ? Networking.devices.values : []
  readonly property var wifiDevice: findDevice(DeviceType.Wifi)
  readonly property var wiredDevice: findDevice(DeviceType.Wired)
  readonly property var connectedWifiNetwork: findConnectedWifiNetwork()
  readonly property int wifiSignal: connectedWifiNetwork
    ? Math.round((connectedWifiNetwork.signalStrength || 0) * 100)
    : -1
  readonly property string connectionKind: {
    if (wiredDevice && wiredDevice.connected) return "ethernet"
    if (connectedWifiNetwork) return "wifi"
    return "disconnected"
  }
  readonly property string networkIcon: NetworkModel.connectionIcon(connectionKind, wifiSignal)
  readonly property bool canToggleWifi: networkManagerAvailable && !!wifiDevice
  readonly property string networkStatus: {
    if (!networkManagerAvailable) return "NetworkManager unavailable"
    if (!wifiDevice) return (wiredDevice && wiredDevice.connected) ? "Ethernet connected" : "No Wi-Fi adapter"
    if (!Networking.wifiEnabled) return "Off"
    if (connectedWifiNetwork) return connectedWifiNetwork.name + " · " + wifiSignal + "%"
    return "Not connected"
  }

  function findDevice(type) {
    var devices = networkDevices || []
    var fallback = null
    for (var i = 0; i < devices.length; i++) {
      var device = devices[i]
      if (!device || device.type !== type) continue
      if (device.connected) return device
      if (!fallback) fallback = device
    }
    return fallback
  }

  function findConnectedWifiNetwork() {
    var device = wifiDevice
    var networks = device && device.networks ? device.networks.values : []
    for (var i = 0; i < networks.length; i++)
      if (networks[i] && networks[i].connected) return networks[i]
    return null
  }

  function toggleWifi() {
    if (!canToggleWifi) return
    Networking.wifiEnabled = !Networking.wifiEnabled
  }

  // ------------------------------------------------------------- wifi list
  // Live scan results projected to primitives exactly as the network panel
  // does (Model.wifiRow/sortWifiRows). Rows become ListView model data, so a
  // live WifiNetwork here would leave a dangling wrapper in a delegate when
  // NetworkManager churns; actions resolve the object via networkForSsid().
  readonly property var wifiNetworkObjects: wifiDevice && wifiDevice.networks ? wifiDevice.networks.values : []
  property var wifiNetworks: []
  property var wifiScannerDevice: null
  // Per-row in-flight state, mirroring the panel: one action at a time so the
  // other rows disable themselves instead of silently no-oping.
  property string wifiActionSsid: ""
  property string wifiActionKind: ""  // "connect" | "disconnect"
  property string wifiFailureSsid: ""
  property string wifiFailureReason: ""
  property string wifiPasswordSsid: ""
  property string wifiPasswordText: ""
  property string wifiIdentityText: ""
  property bool wifiPasswordRevealed: false

  // ConnectionFailReason values as a plain object, so the shared Model.js
  // helpers stay pure JS.
  readonly property var connectionFailReasons: ({
    NoSecrets: ConnectionFailReason.NoSecrets,
    WifiAuthTimeout: ConnectionFailReason.WifiAuthTimeout,
    WifiNetworkLost: ConnectionFailReason.WifiNetworkLost,
    WifiClientDisconnected: ConnectionFailReason.WifiClientDisconnected,
    WifiClientFailed: ConnectionFailReason.WifiClientFailed
  })

  // The list display is gated on the radio: a powered-down device must read
  // "off" rather than serve a stale scan held from before it was switched off.
  readonly property bool wifiListVisible: Networking.wifiEnabled && wifiNetworks.length > 0

  onWifiNetworkObjectsChanged: syncWifiNetworks()
  onWifiDeviceChanged: {
    setWifiScannerEnabled(true)
    syncWifiNetworks()
  }

  function setWifiScannerEnabled(enabled) {
    var nextDevice = root.wifiDevice
    if (wifiScannerDevice && wifiScannerDevice !== nextDevice)
      wifiScannerDevice.scannerEnabled = false
    wifiScannerDevice = nextDevice
    if (wifiScannerDevice) wifiScannerDevice.scannerEnabled = enabled
  }

  function syncWifiNetworks() {
    var nets = []
    var networks = wifiNetworkObjects || []
    for (var i = 0; i < networks.length; i++) {
      var network = networks[i]
      if (!network) continue
      checkWifiActionCompletion(network)
      var row = NetworkModel.wifiRow(network)
      if (row) nets.push(row)
    }
    wifiNetworks = NetworkModel.sortWifiRows(nets)
  }

  function networkForSsid(ssid) {
    var networks = wifiNetworkObjects || []
    for (var i = 0; i < networks.length; i++)
      if (networks[i] && networks[i].name === ssid) return networks[i]
    return null
  }

  function requiresWifiCredentials(security) {
    return NetworkModel.requiresCredentials(security, WifiSecurityType.Open, WifiSecurityType.Owe)
  }

  function isEnterpriseSecurity(security) {
    return security === WifiSecurityType.Wpa2Eap || security === WifiSecurityType.WpaEap
  }

  function runWifiAction(kind, network, callback) {
    if (wifiActionKind !== "" || !network) return
    wifiActionSsid = network.name || ""
    wifiActionKind = kind
    wifiFailureSsid = ""
    wifiFailureReason = ""
    callback(network)
    wifiActionTimeout.restart()
  }

  function clearWifiAction() {
    wifiActionTimeout.stop()
    if (wifiActionKind === "connect") wifiPasswordSsid = ""
    wifiFailureSsid = ""
    wifiFailureReason = ""
    wifiActionSsid = ""
    wifiActionKind = ""
    syncWifiNetworks()
  }

  function failWifiAction(network, reason) {
    if (!network || wifiActionKind === "" || wifiActionSsid !== (network.name || "")) return
    wifiActionTimeout.stop()
    wifiFailureSsid = wifiActionSsid
    wifiFailureReason = NetworkModel.networkFailureReason(reason, requiresWifiCredentials(network.security), connectionFailReasons)
    wifiActionSsid = ""
    wifiActionKind = ""
    syncWifiNetworks()
  }

  function checkWifiActionCompletion(network) {
    if (!network || wifiActionKind === "" || wifiActionSsid !== (network.name || "")) return
    if (wifiActionKind === "connect" && network.connected) clearWifiAction()
    else if (wifiActionKind === "disconnect" && !network.connected && !network.stateChanging) clearWifiAction()
  }

  function connectWifiDirectly(ssid) {
    runWifiAction("connect", networkForSsid(ssid), function(network) { network.connect() })
  }

  function connectWifiWithPassphrase(ssid, passphrase) {
    runWifiAction("connect", networkForSsid(ssid), function(network) { network.connectWithPsk(passphrase) })
  }

  function connectWifiEnterprise(ssid, identity, passphrase) {
    runWifiAction("connect", networkForSsid(ssid), function(network) {
      enterpriseConnect.secret = passphrase
      enterpriseConnect.command = ["bash", "-c", NetworkModel.enterpriseConnectScript, "nmcli-eap", ssid, identity]
      enterpriseConnect.running = true
    })
  }

  function disconnectWifiRow(ssid) {
    var network = networkForSsid(ssid)
    if (network && network.connected)
      runWifiAction("disconnect", network, function(net) { net.disconnect() })
  }

  function openWifiPasswordPrompt(ssid) {
    if (wifiPasswordSsid !== ssid) {
      wifiPasswordText = ""
      wifiIdentityText = ""
      wifiPasswordRevealed = false
    }
    wifiPasswordSsid = ssid
  }

  function cancelWifiPasswordPrompt() {
    wifiPasswordSsid = ""
    wifiPasswordText = ""
    wifiIdentityText = ""
    wifiPasswordRevealed = false
  }

  function shouldRepromptWifiPassphrase(reason, needsCredentials) {
    return NetworkModel.shouldRepromptPassphrase(reason, needsCredentials, connectionFailReasons)
  }

  // Creates and activates the 802.1X profile (see Model.enterpriseConnectScript).
  // The password goes over stdin, never argv.
  Process {
    id: enterpriseConnect
    property string secret: ""
    stdinEnabled: true
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
  }

  Timer {
    id: wifiActionTimeout
    // Must outlast NetworkManager's 25s supplicant timeout so a wrong saved
    // PSK still lands while the action is tracked.
    interval: 30000
    repeat: false
    onTriggered: {
      if (!root.wifiActionKind) return
      root.wifiFailureSsid = root.wifiActionSsid
      root.wifiFailureReason = root.wifiActionKind === "connect" ? "Timed out connecting" : "Timed out disconnecting"
      root.wifiActionSsid = ""
      root.wifiActionKind = ""
      root.syncWifiNetworks()
    }
  }

  // ------------------------------------------------------------ bluetooth
  readonly property var adapter: Bluetooth.defaultAdapter
  readonly property var bluetoothDevices: Bluetooth.devices ? Bluetooth.devices.values : []
  readonly property var connectedBtDevice: findConnectedBtDevice()
  readonly property bool canToggleBluetooth: !!adapter
  // BlueZ reports the rfkill soft block as the adapter's Blocked state, which
  // is the honest "blocked" signal — omarchy-bluetooth-power drives the block.
  readonly property bool bluetoothBlocked: !!adapter && adapter.state === BluetoothAdapterState.Blocked
  readonly property string bluetoothIcon: {
    if (!adapter || !adapter.enabled) return "󰂲"
    return connectedBtDevice ? "󰂱" : "󰂯"
  }
  readonly property string bluetoothStatus: {
    if (!adapter) return "No Bluetooth adapter"
    if (bluetoothBlocked) return "Blocked (rfkill)"
    if (!adapter.enabled) return "Off"
    if (connectedBtDevice) return BluetoothModel.deviceLabel(connectedBtDevice)
    return "On · no device connected"
  }

  function findConnectedBtDevice() {
    var devices = bluetoothDevices || []
    for (var i = 0; i < devices.length; i++) {
      var device = devices[i]
      if (device && device.connected && BluetoothModel.hasHumanName(device)) return device
    }
    return null
  }

  // Mirrors panels/bluetooth/Panel.qml: the rfkill soft block is what persists
  // across reboots, so the helper owns the toggle direction.
  function toggleBluetooth() {
    if (!adapter) return
    Quickshell.execDetached(["omarchy-bluetooth-power", adapter.enabled ? "off" : "on"])
  }

  // ------------------------------------------------------- bluetooth list
  // Same grouping the panel uses: connected / known(paared) / discovered,
  // with deviceLists() doing the hasHumanName + sort filtering.
  readonly property var btDeviceGroups: BluetoothModel.deviceLists(bluetoothDevices)
  readonly property var connectedBtDevices: btDeviceGroups.connected || []
  readonly property var knownBtDevices: btDeviceGroups.known || []
  readonly property var discoveredBtDevices: btDeviceGroups.discovered || []
  // Address -> "connecting" | "disconnecting". The real sequencing lives in
  // bin/omarchy-bluetooth-device; this only keeps rows responsive meanwhile.
  property var btPendingActions: ({})
  // Ownership flag for the discovery session this view starts, so closing the
  // view ends the scan instead of leaving the radio in inquiry.
  property bool btOwesDiscoveryStop: false

  readonly property var btRows: {
    var rows = []
    for (var c = 0; c < connectedBtDevices.length; c++)
      rows.push({ dev: BluetoothModel.deviceRow(connectedBtDevices[c]), section: "connected" })
    for (var k = 0; k < knownBtDevices.length; k++)
      rows.push({ dev: BluetoothModel.deviceRow(knownBtDevices[k]), section: "known" })
    if (adapter && adapter.discovering)
      for (var d = 0; d < discoveredBtDevices.length; d++)
        rows.push({ dev: BluetoothModel.deviceRow(discoveredBtDevices[d]), section: "discovered" })
    return rows
  }

  onConnectedBtDevicesChanged: syncBtPendingActions()
  onKnownBtDevicesChanged: syncBtPendingActions()
  onDiscoveredBtDevicesChanged: syncBtPendingActions()
  onBluetoothDevicesChanged: syncBtPendingActions()

  function btDeviceFor(row) {
    if (!row || !row.dev) return null
    var address = row.dev.address || ""
    var devices = bluetoothDevices || []
    for (var i = 0; i < devices.length; i++)
      if ((devices[i].address || "") === address) return devices[i]
    return null
  }

  function setBtPendingAction(address, action) {
    if (!address) return
    btPendingActions = BluetoothModel.withPendingAction(btPendingActions, address, action)
    if (action) btPendingTimeout.restart()
  }

  function btPendingAction(address) {
    return BluetoothModel.pendingAction(btPendingActions, address)
  }

  function runBtDeviceAction(device, action, pending) {
    if (!device || !device.address) return
    setBtPendingAction(device.address, pending)
    Quickshell.execDetached(["omarchy-bluetooth-device", action, device.address])
  }

  function connectBtDevice(device) {
    if (!device || device.connected) return
    if (device.paired || device.bonded || device.trusted) runBtDeviceAction(device, "connect", "connecting")
    else runBtDeviceAction(device, "pair", "connecting")
  }

  function disconnectBtDevice(device) {
    if (!device || !device.address || !device.connected) return
    setBtPendingAction(device.address, "disconnecting")
    if (device.disconnect) device.disconnect()
    Quickshell.execDetached(["omarchy-bluetooth-device", "disconnect", device.address])
  }

  function syncBtPendingActions() {
    var next = BluetoothModel.cloneMap(btPendingActions)
    var changed = false
    for (var address in next) {
      var action = next[address]
      var found = null
      var devices = bluetoothDevices || []
      for (var i = 0; i < devices.length; i++) {
        if (devices[i] && devices[i].address === address) { found = devices[i]; break }
      }
      if ((action === "connecting" && found && found.connected)
          || (action === "disconnecting" && found && !found.connected)) {
        delete next[address]
        changed = true
      }
    }
    if (changed) btPendingActions = next
  }

  // Keep an enabled adapter scanning while this view is alive: BlueZ rejects
  // StartDiscovery while it is still powering up, and discovery can time out.
  Timer {
    id: btDiscoveryRetry
    interval: 1000
    repeat: true
    triggeredOnStart: true
    running: root.adapter !== null && root.adapter.enabled && !root.adapter.discovering
    onTriggered: {
      root.btOwesDiscoveryStop = true
      root.adapter.discovering = true
    }
  }

  Connections {
    target: root.adapter
    // Discovery is confirmed down (by our stop or by BlueZ timing out), so a
    // stale claim never touches a scan another client starts later.
    function onDiscoveringChanged() {
      if (!root.adapter.discovering) root.btOwesDiscoveryStop = false
    }
  }

  Timer {
    id: btPendingTimeout
    interval: 20000
    repeat: false
    onTriggered: root.btPendingActions = ({})
  }

  // ---------------------------------------------------------------- power
  readonly property var battery: UPower.displayDevice
  readonly property bool batteryPresent: !!(battery && battery.isPresent)
  readonly property bool discharging: !!(batteryPresent && UPower.onBattery)
  readonly property real batteryFraction: PowerModel.batteryFraction(battery)
  readonly property int batteryPercent: Math.round(batteryFraction * 100)
  readonly property string batteryIcon: PowerModel.batteryIcon(battery, discharging, upowerStates())
  readonly property string batteryMode: PowerModel.modeLabel(battery, discharging, upowerStates())

  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0

  function upowerStates() {
    return {
      Charging: UPowerDeviceState.Charging,
      Discharging: UPowerDeviceState.Discharging,
      FullyCharged: UPowerDeviceState.FullyCharged,
      PendingCharge: UPowerDeviceState.PendingCharge
    }
  }

  function updateProfiles(raw) {
    var parsed = PowerModel.parseProfiles(raw, profileIndex)
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
    var idx = profiles.indexOf(activeProfile)
    profileIndex = idx >= 0 ? idx : 0
  }

  function setProfile(profile) {
    if (!profile || actionProc.running) return
    actionProc.command = ["omarchy-powerprofiles-set", discharging ? "battery" : "ac", profile]
    actionProc.running = true
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfiles(text) }
  }

  Process {
    id: actionProc
    // Re-read the active profile once the setter settles.
    onExited: if (!profilesProc.running) profilesProc.running = true
  }

  // This deck owns the volume and brightness sliders, so the island must not
  // swap it for the transient overlay while it is mounted. Suspension is
  // claimed on completion and released on destruction — never a plain Binding,
  // which would latch after the view dies (see IslandState.transientSuspended).
  readonly property string transientSuspendToken: "quick-settings-" + Math.random()
  Component.onCompleted: {
    if (root.islandState) root.islandState.suspendTransient(transientSuspendToken)
    profilesProc.running = true
    // Resolve the real default output (through any DSP sink) right away: the
    // 15s timer would otherwise leave the slider on the raw default until the
    // first tick, which is the tuning sink on machines that have one.
    root.resolveVolumeSink()
    root.refreshDisplayAudioSinks()
    if (!sinkAvailabilityProc.running) sinkAvailabilityProc.running = true
    // Claim the shared scan only while this view is mounted; released on
    // destruction below so a collapsed island never keeps the radio busy.
    setWifiScannerEnabled(true)
    syncWifiNetworks()
  }

  Component.onDestruction: {
    if (root.islandState) root.islandState.releaseTransient(transientSuspendToken)
    if (wifiScannerDevice) wifiScannerDevice.scannerEnabled = false
    // Hand the discovery session back down. Bound to the last confirmed state,
    // so a BlueZ confirmation landing late cannot resurrect the scan.
    if (btOwesDiscoveryStop && adapter !== null && adapter.discovering) adapter.discovering = false
  }

  // ================================================================ layout
  // Two-column deck for the compact controls, then the device lists below.
  // Order: audio + battery, the volume scrubber, the power profile picker, the
  // radio toggles, and finally the Wi-Fi/Bluetooth device lists. The lists are
  // capped and scroll, so the body stays within the island budget even in a
  // busy Wi-Fi neighbourhood or with many paired devices.
  RowLayout {
    width: parent.width
    spacing: Style.spacing.md

    QuickSettingRow {
      Layout.fillWidth: true
      visible: root.deckAudioVisible
      iconText: root.audioIcon()
      iconOpacity: root.hasAudio ? (root.outputMuted ? 0.5 : 1.0) : 0.4
      title: "Audio"
      subtitle: root.hasAudio
        ? (root.outputMuted ? "Muted" : root.volumeName + " · " + root.outputPercent + "%")
        : "No output device"
      showSwitch: true
      switchEnabled: root.hasAudio
      switchChecked: root.hasAudio && !root.outputMuted
      onToggled: root.toggleOutputMute()

      ControlDrag { controlId: "audio" }
    }

    QuickSettingRow {
      Layout.fillWidth: true
      visible: root.deckBatteryVisible
      iconText: root.batteryPresent ? root.batteryIcon : "󰂑"
      iconOpacity: root.batteryPresent ? 1.0 : 0.5
      title: "Battery"
      subtitle: root.batteryPresent ? root.batteryMode : "No battery"
      trailingText: root.batteryPresent ? root.batteryPercent + "%" : "--"

      ControlDrag { controlId: "battery" }
    }
  }

  // Audio volume stays full width: a half-width scrubber is too cramped.
  PanelSlider {
    width: parent.width
    // The volume slider belongs to the audio control: hiding audio retires the
    // scrubber with it, so the deck never keeps an orphan slider.
    visible: root.deckAudioVisible
    bar: root.islandBar
    enabled: root.hasAudio
    opacity: root.hasAudio ? 1.0 : 0.4
    minimum: 0
    maximum: 1
    step: 0.05
    value: root.outputVolume
    onMoved: function(v) { root.setOutputVolume(v) }
    onRightClicked: root.toggleOutputMute()
  }

  // Brightness: same full-width treatment as volume, with its own caption so
  // the two sliders never read as one. Writes through the shared
  // BrightnessState, so the deck and the brightness overlay stay in sync.
  Column {
    width: parent.width
    visible: root.deckBrightnessVisible
    spacing: Style.spacing.sm

    Text {
      text: "BRIGHTNESS"
      color: root.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2

      // The slider keeps its own drag; the block is grabbed by its caption.
      ControlDrag { controlId: "brightness" }
    }

    PanelSlider {
      width: parent.width
      bar: root.islandBar
      enabled: root.brightnessAvailable
      opacity: root.brightnessAvailable ? 1.0 : 0.4
      minimum: 0
      maximum: 100
      step: 1
      value: root.brightnessPercent
      onMoved: function(v) { root.setBrightness(v) }
    }
  }

  // Output picker: the island's own switch for the default sink, mirroring the
  // upstream audio panel. The current output is highlighted; a click switches
  // the default through the shell CLI. The list is a snapshot, never the live
  // PipeWire model (see the note above).
  Column {
    width: parent.width
    visible: root.deckAudioOutputVisible
    spacing: Style.spacing.sm

    Text {
      text: "OUTPUT"
      color: root.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2

      ControlDrag { controlId: "audioOutput" }
    }

    Column {
      width: parent.width
      spacing: Style.space(4)

      Repeater {
        model: root.displayAudioSinks

        delegate: Rectangle {
          id: sinkRow
          required property var modelData
          readonly property bool current: String(modelData.name || "") === root.currentSinkName

          width: parent.width
          height: Style.space(32)
          radius: Style.cornerRadius
          color: sinkRow.current ? Util.alpha(Color.accent, 0.20) : Util.alpha(root.fg, 0.05)
          border.width: 1
          border.color: sinkRow.current ? Util.alpha(Color.accent, 0.60) : Util.alpha(root.fg, 0.10)
          Behavior on color { ColorAnimation { duration: 120; easing.type: Easing.OutCubic } }

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.spacing.controlPaddingX
            anchors.rightMargin: Style.spacing.controlPaddingX
            spacing: Style.spacing.sm

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: AudioModel.sinkGlyph(sinkRow.modelData)
              color: sinkRow.current ? Color.accent : Util.alpha(root.fg, 0.65)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: Math.max(0, parent.width - Style.space(40))
              anchors.verticalCenter: parent.verticalCenter
              text: AudioModel.nodeLabel(sinkRow.modelData)
              color: root.fg
              elide: Text.ElideRight
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: sinkRow.current
              text: "✓"
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.setDefaultSink(sinkRow.modelData)
          }
        }
      }
    }
  }

  Rectangle {
    width: parent.width
    height: Style.spacing.hairline
    color: Util.alpha(root.fg, 0.12)
    // Only separates two blocks that both still render.
    visible: (root.deckAudioVisible || root.deckBatteryVisible) && root.deckPowerVisible
  }

  // Power profile picker: only shown when the daemon actually lists profiles,
  // otherwise the battery block above stays a read-only readout.
  Column {
    width: parent.width
    visible: root.deckPowerVisible
    spacing: Style.spacing.md

    Text {
      text: "POWER PROFILE"
      color: root.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2

      // The profile buttons keep their own click; the block is grabbed here.
      ControlDrag { controlId: "powerProfile" }
    }

    Row {
      id: profileRow
      width: parent.width
      spacing: Style.spacing.sm

      readonly property real cellWidth: root.profiles.length > 0
        ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length
        : 0

      Repeater {
        model: root.profiles

        Button {
          required property var modelData
          required property int index
          width: profileRow.cellWidth
          iconText: PowerModel.profileIcon(String(modelData))
          iconSize: Style.font.title
          text: String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
          fontSize: Style.font.bodySmall
          foreground: root.fg
          fontFamily: Style.font.family
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          bordered: true
          active: root.activeProfile === modelData
          onClicked: root.setProfile(modelData)
        }
      }
    }
  }

  Rectangle {
    width: parent.width
    height: Style.spacing.hairline
    color: Util.alpha(root.fg, 0.12)
    visible: root.deckPowerVisible && root.deckWifiBtBlockVisible
  }

  // Ambient system state, in ONE reflowing row pair: hiding a control (the
  // Excluded drag) collapses its cell and the remaining cells slide up, so no
  // hole is left behind. Night light and idle hold read the same first-party
  // services the shell's bar indicators use; microphone and notifications read
  // the resolver.
  Flow {
    id: ambientToggles
    width: parent.width
    spacing: Style.spacing.md

    // Strict two columns. Flow skips invisible children, so hiding a control
    // collapses its cell and the rest slide up into a trailing empty slot
    // instead of a hole in the middle of the grid. Cells keep half width even
    // when the visible count is odd — a stretched row would push its switch to
    // the card edge and break the column rhythm.
    readonly property real cellWidth: Math.max(0, (width - spacing) / 2)

    QuickSettingRow {
      width: ambientToggles.cellWidth
      height: implicitHeight
      visible: root.deckNightlightVisible
      iconText: "󰔎"
      iconOpacity: root.nightlightEnabled ? 1.0 : 0.5
      title: "Night light"
      subtitle: root.nightlightEnabled ? "On" : "Off"
      showSwitch: true
      switchChecked: root.nightlightEnabled
      onToggled: root.toggleNightlight()

      ControlDrag { controlId: "nightlight" }
    }

    QuickSettingRow {
      width: ambientToggles.cellWidth
      height: implicitHeight
      visible: root.deckStayAwakeVisible
      iconText: "󰅶"
      iconOpacity: root.stayAwake ? 1.0 : 0.5
      title: "Stay awake"
      subtitle: root.stayAwake ? "Idle blocked" : "Idle allowed"
      showSwitch: true
      switchChecked: root.stayAwake
      onToggled: root.toggleStayAwake()

      ControlDrag { controlId: "stayAwake" }
    }

    // The switch reads "is the feature on": unmuted for the mic, notifications
    // allowed when DND is off.
    QuickSettingRow {
      width: ambientToggles.cellWidth
      height: implicitHeight
      visible: root.deckMicVisible
      iconText: root.microphoneMuted ? "󰍭" : "󰍬"
      iconOpacity: root.microphoneMuted ? 0.5 : 1.0
      title: "Microphone"
      subtitle: root.microphoneMuted ? "Muted"
        : (root.microphoneInUse ? "In use" : "Live")
      showSwitch: true
      switchChecked: !root.microphoneMuted
      onToggled: root.toggleMicrophoneMute()

      ControlDrag { controlId: "microphone" }
    }

    QuickSettingRow {
      width: ambientToggles.cellWidth
      height: implicitHeight
      visible: root.deckNotificationsVisible
      iconText: root.doNotDisturb ? "󰂛" : "󰂚"
      iconOpacity: root.doNotDisturb ? 0.5 : 1.0
      title: "Notifications"
      subtitle: root.doNotDisturb ? "Silenced"
        : (root.notificationCount > 0 ? root.notificationCount + " new" : "On")
      showSwitch: true
      switchChecked: !root.doNotDisturb
      onToggled: root.toggleDoNotDisturb()

      ControlDrag { controlId: "notifications" }
    }
  }

  Rectangle {
    width: parent.width
    height: Style.spacing.hairline
    color: Util.alpha(root.fg, 0.12)
    visible: root.deckWifiBtBlockVisible && root.deckAnyStatusToggleVisible
  }

  // Wi-Fi and Bluetooth radios, kept immediately above their device lists so
  // each column always reads toggle-over-list and the pair is contiguous.
  RowLayout {
    width: parent.width
    spacing: Style.spacing.md

    QuickSettingRow {
      Layout.fillWidth: true
      visible: root.deckWifiToggleVisible
      iconText: root.networkIcon
      title: "Wi-Fi"
      subtitle: root.networkStatus
      showSwitch: root.canToggleWifi
      switchChecked: Networking.wifiEnabled
      onToggled: root.toggleWifi()

      ControlDrag { controlId: "wifiToggle" }
    }

    QuickSettingRow {
      Layout.fillWidth: true
      visible: root.deckBtToggleVisible
      iconText: root.bluetoothIcon
      iconOpacity: root.adapter && root.adapter.enabled ? 1.0 : 0.5
      title: "Bluetooth"
      subtitle: root.bluetoothStatus
      showSwitch: root.canToggleBluetooth
      switchChecked: root.adapter && root.adapter.enabled
      onToggled: root.toggleBluetooth()

      ControlDrag { controlId: "btToggle" }
    }
  }

  // ------------------------------------------------------------ device lists
  // Wi-Fi on the left, Bluetooth on the right. Two capped columns keep both
  // real lists on screen without letting either one grow the body past the
  // island budget; each list scrolls once there is more than it can show.
  RowLayout {
    width: parent.width
    spacing: Style.spacing.md

    // ----------------------------------------------------------------- Wi-Fi
    Column {
      Layout.fillWidth: true
      Layout.preferredWidth: 1
      visible: root.deckWifiListVisible
      spacing: Style.spacing.sm

      Item {
        width: parent.width
        implicitHeight: Math.max(wifiHeader.implicitHeight, wifiMeta.implicitHeight)

        // Grab the list by its header; the rows below keep their own scroll.
        ControlDrag { controlId: "wifiList" }

        Text {
          id: wifiHeader
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "WI-FI"
          color: root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
        }

        Text {
          id: wifiMeta
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: root.wifiNetworks.length > 0 ? root.wifiNetworks.length + " FOUND" : ""
          color: root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      ListView {
        id: wifiList
        width: parent.width
        // Cap the viewport so a busy neighbourhood does not push the body
        // past the island budget; the list scrolls for the rest.
        height: root.wifiListVisible ? Math.min(contentHeight, Style.space(92)) : 0
        visible: root.wifiListVisible
        clip: true
        spacing: Style.space(2)
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        model: root.wifiListVisible ? root.wifiNetworks : []
        // Wrapper takes the required props from ListView's delegate context and
        // passes them down explicitly, the same shape the network panel uses.
        delegate: Item {
          required property var modelData
          required property int index
          width: ListView.view.width
          height: wifiDelegateRow.implicitHeight

          WifiNetworkRow {
            id: wifiDelegateRow
            width: parent.width
            net: modelData
          }
        }
      }

      Text {
        width: parent.width
        visible: !root.wifiListVisible
        text: !root.networkManagerAvailable ? "NetworkManager unavailable"
            : !root.wifiDevice ? "No Wi-Fi adapter"
            : !Networking.wifiEnabled ? "Wi-Fi is off"
            : "No networks found"
        color: root.dim
        wrapMode: Text.WordWrap
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    // ------------------------------------------------------------- Bluetooth
    Column {
      Layout.fillWidth: true
      Layout.preferredWidth: 1
      visible: root.deckBtListVisible
      spacing: Style.spacing.sm

      Item {
        width: parent.width
        implicitHeight: Math.max(btHeader.implicitHeight, btMeta.implicitHeight)

        // Grab the list by its header; the rows below keep their own scroll.
        ControlDrag { controlId: "btList" }

        Text {
          id: btHeader
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "BLUETOOTH"
          color: root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
        }

        Text {
          id: btMeta
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: {
            if (!root.adapter) return "NONE"
            if (root.bluetoothBlocked) return "BLOCKED"
            if (!root.adapter.enabled) return "OFF"
            return root.adapter.discovering ? "SCANNING" : "ON"
          }
          color: root.bluetoothBlocked ? Color.urgent : root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      ListView {
        id: btList
        width: parent.width
        height: root.btRows.length > 0 ? Math.min(contentHeight, Style.space(92)) : 0
        visible: root.btRows.length > 0
        clip: true
        spacing: Style.space(2)
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        model: root.btRows
        // No section headers. Each row states its own status on the second
        // line ("Connected", "100% · Connected", "Paired"), exactly like the
        // Wi-Fi list; the model order still groups connected first. The
        // CONNECTED/PAIRED/AVAILABLE headers duplicated what the rows now say.
        delegate: Item {
          required property var modelData
          width: ListView.view.width
          height: btDelegateColumn.implicitHeight

          Column {
            id: btDelegateColumn
            width: parent.width
            spacing: Style.space(2)

            BtDeviceRow {
              width: parent.width
              dev: modelData.dev
              section: modelData.section
            }
          }
        }
      }

      Text {
        width: parent.width
        visible: root.btRows.length === 0
        text: !root.adapter ? "No Bluetooth adapter"
            : root.bluetoothBlocked ? "Blocked by rfkill"
            : !root.adapter.enabled ? "Turn Bluetooth on to scan"
            : "Scanning for devices…"
        color: root.bluetoothBlocked ? Color.urgent : root.dim
        wrapMode: Text.WordWrap
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  // --------------------------------------------------- excluded controls (R5)
  // Same vocabulary as the widget grid's exclusion panel: an always-visible
  // header showing the count, collapsing into a row of chips that drag back into
  // the deck. Only on the composed default page; the standalone system views
  // render every control and never show this panel.
  Item {
    id: excludedControlsHeader
    width: parent.width
    height: root.deckEditable ? Style.space(30) : 0
    visible: root.deckEditable

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.excludedOpen = !root.excludedOpen
    }

    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "Excluded (" + root.excludedControlIds.length + ")"
        color: Util.alpha(Color.bar.text, root.excludedOpen ? 0.90 : 0.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.excludedOpen ? "▾" : "▸"
        color: Util.alpha(Color.bar.text, root.excludedOpen ? 0.90 : 0.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  Flow {
    id: excludedControlsGrid
    width: parent.width
    spacing: Style.space(6)
    visible: root.deckEditable && root.excludedOpen

    Repeater {
      model: root.deckEditable ? root.excludedControlIds : []

      delegate: Rectangle {
        id: chip
        required property var modelData
        readonly property string chipId: String(modelData || "")
        width: Math.max(Style.space(72),
          Math.floor((root.width - Style.space(6) * 2) / 3))
        height: Style.space(38)
        radius: Style.cornerRadius
        color: Util.alpha(Color.bar.text, 0.06)
        border.width: 1
        border.color: Util.alpha(Color.bar.text, 0.10)
        clip: true
        opacity: (root.islandBar && root.islandBar.dragWidgetId === chip.chipId) ? 0.35 : 1.0

        Column {
          anchors.centerIn: parent
          width: Math.max(0, parent.width - Style.space(8))
          spacing: Style.space(1)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            // md-cancel (U+F073A): the same "disabled" mark the widget chips use.
            text: "󰜺"
            color: Util.alpha(Color.bar.text, 0.85)
            font.family: Style.font.family
            font.pixelSize: Style.font.title
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            text: root.controlLabel(chip.chipId)
            color: Util.alpha(Color.bar.text, 0.65)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }

        ControlDrag {
          controlId: chip.chipId
          fromExcluded: true
        }
      }
    }
  }

  // One setting row: leading glyph, title/subtitle, and either a toggle switch
  // or a trailing readout. Extracted from the four near-identical blocks this
  // view used to stack, so the two-column arrangement cannot drift between
  // them and spacing/typography stay in one place.
  component QuickSettingRow: Item {
    id: settingRow

    property string iconText: ""
    property real iconOpacity: 1.0
    property string title: ""
    property string subtitle: ""
    property bool showSwitch: false
    property bool switchEnabled: true
    property bool switchChecked: false
    property string trailingText: ""

    signal toggled()

    implicitHeight: Math.max(iconLabel.implicitHeight, labels.implicitHeight,
      switchItem.implicitHeight, trailingItem.implicitHeight)

    Text {
      id: iconLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: settingRow.iconText
      color: root.fg
      opacity: settingRow.iconOpacity
      font.family: Style.font.family
      font.pixelSize: Style.font.title
    }

    ToggleSwitch {
      id: switchItem
      visible: settingRow.showSwitch
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      enabled: settingRow.switchEnabled
      checked: settingRow.switchChecked
      foreground: root.fg
      onToggled: settingRow.toggled()
    }

    Text {
      id: trailingItem
      visible: settingRow.trailingText !== ""
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: settingRow.trailingText
      color: root.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
      font.weight: Font.DemiBold
    }

    Column {
      id: labels
      anchors.left: iconLabel.right
      anchors.leftMargin: Style.space(12)
      // Anchor to whichever trailing control is actually shown, matching the
      // hand-written blocks this component replaces.
      anchors.right: settingRow.showSwitch
        ? switchItem.left
        : (settingRow.trailingText !== "" ? trailingItem.left : parent.right)
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xxs

      Text {
        width: parent.width
        text: settingRow.title
        color: root.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.weight: Font.DemiBold
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: settingRow.subtitle
        color: root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
    }
  }

  // One Wi-Fi network row. Collapses to a single line normally; expands inline
  // to a passphrase (or 802.1X identity + passphrase) prompt when the user
  // picks a protected network with no saved credentials.
  component WifiNetworkRow: CursorSurface {
    id: wifiRow
    required property var net

    readonly property bool isConnected: !!(net && net.connected)
    readonly property bool isKnown: !!(net && net.known)
    readonly property bool needsCredentials: net ? root.requiresWifiCredentials(net.security) : false
    readonly property bool isEnterprise: net ? root.isEnterpriseSecurity(net.security) : false
    readonly property bool isBusy: root.wifiActionKind !== "" && root.wifiActionSsid === (net ? net.ssid : "")
    readonly property bool isFailed: root.wifiFailureReason !== "" && root.wifiFailureSsid === (net ? net.ssid : "")
    readonly property bool isPasswordOpen: root.wifiPasswordSsid !== "" && root.wifiPasswordSsid === (net ? net.ssid : "")

    hasCursor: wifiRowMouse.containsMouse
    current: isConnected
    foreground: root.fg
    fill: Style.hoverFillFor(root.fg, Color.accent)
    currentFill: Style.selectedFillFor(root.fg, Color.accent)

    implicitHeight: body.implicitHeight + (isPasswordOpen ? passwordPanel.implicitHeight + Style.spacing.sm : 0)

    function submitCredentials() {
      if (!net || root.wifiActionKind !== "" || root.wifiPasswordText.length === 0) return
      if (!isEnterprise) return root.connectWifiWithPassphrase(net.ssid, root.wifiPasswordText)
      if (root.wifiIdentityText.length > 0)
        root.connectWifiEnterprise(net.ssid, root.wifiIdentityText, root.wifiPasswordText)
    }

    Connections {
      target: wifiRow.net ? root.networkForSsid(wifiRow.net.ssid) : null
      function onConnectionFailed(reason) {
        // Background auto-connect retries fire this too; only reprompt for the
        // connect started from this view. Checked before failWifiAction, which
        // clears the action state.
        var ours = root.wifiActionKind === "connect" && root.wifiActionSsid === (wifiRow.net.ssid || "")
        root.failWifiAction(root.networkForSsid(wifiRow.net.ssid), reason)
        if (ours && root.shouldRepromptWifiPassphrase(reason, wifiRow.needsCredentials))
          root.openWifiPasswordPrompt(wifiRow.net.ssid)
      }
      function onConnectedChanged() {
        if (wifiRow.net) root.checkWifiActionCompletion(root.networkForSsid(wifiRow.net.ssid))
      }
      function onKnownChanged() {
        if (wifiRow.net) root.checkWifiActionCompletion(root.networkForSsid(wifiRow.net.ssid))
      }
      function onStateChangingChanged() {
        if (wifiRow.net) root.checkWifiActionCompletion(root.networkForSsid(wifiRow.net.ssid))
      }
    }

    readonly property string statusText: {
      if (!net) return ""
      if (isPasswordOpen) return ""
      if (isBusy && root.wifiActionKind === "connect") return "Connecting…"
      if (isBusy && root.wifiActionKind === "disconnect") return "Disconnecting…"
      if (isFailed) return root.wifiFailureReason || "Failed"
      if (isConnected) return "Connected"
      if (isKnown) return "Saved"
      return ""
    }
    readonly property color statusColor: isFailed ? Color.urgent : (isConnected ? root.fg : root.dim)

    MouseArea {
      id: wifiRowMouse
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: body.implicitHeight
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.PointingHandCursor
      enabled: root.wifiActionKind === ""
      onClicked: {
        if (!wifiRow.net) return
        if (wifiRow.isConnected) { root.disconnectWifiRow(wifiRow.net.ssid); return }
        if (wifiRow.needsCredentials && !wifiRow.isKnown) {
          root.openWifiPasswordPrompt(wifiRow.net.ssid)
          return
        }
        root.connectWifiDirectly(wifiRow.net.ssid)
      }
    }

    Item {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      implicitHeight: Math.max(signalIcon.implicitHeight, labels.implicitHeight) + Style.spacing.sm

      Text {
        id: signalIcon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: wifiRow.net ? NetworkModel.wifiIconFor(wifiRow.net.signal) : ""
        color: wifiRow.statusColor
        font.family: Style.font.family
        font.pixelSize: Style.font.title
      }

      Text {
        id: trailingGlyph
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: wifiRow.isConnected ? "󰅖" : (wifiRow.needsCredentials ? "󰌾" : "")
        color: wifiRow.isConnected ? root.fg : root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Column {
        id: labels
        anchors.left: signalIcon.right
        anchors.leftMargin: Style.space(8)
        anchors.right: trailingGlyph.text !== "" ? trailingGlyph.left : parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xxs

        Text {
          width: parent.width
          text: wifiRow.net ? (wifiRow.net.ssid || "Hidden") : ""
          color: root.fg
          elide: Text.ElideRight
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          width: parent.width
          visible: wifiRow.statusText !== ""
          text: wifiRow.statusText
          color: wifiRow.statusColor
          elide: Text.ElideRight
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }

    // A failed connect reopens the prompt for a retry; after a beat the error
    // clears so the input is usable again.
    Timer {
      interval: 2500
      running: wifiRow.isFailed && wifiRow.isPasswordOpen
      onTriggered: {
        root.wifiFailureSsid = ""
        root.wifiFailureReason = ""
        passwordField.forceActiveFocus()
      }
    }

    // Inline credential prompt. Submitting (Enter or the check button) fires
    // connect; Esc cancels back to the row.
    Item {
      id: passwordPanel
      visible: wifiRow.isPasswordOpen
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: body.bottom
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      anchors.topMargin: Style.spacing.sm
      implicitHeight: (identityField.visible ? identityField.implicitHeight + Style.spacing.xxs : 0)
        + (passwordField.visible ? passwordField.implicitHeight : 0)
        + (statusBox.visible ? Style.spacing.controlHeight : 0)
      height: implicitHeight

      TextField {
        id: identityField
        visible: wifiRow.isEnterprise && !wifiRow.isBusy && !wifiRow.isFailed
        anchors.left: parent.left
        anchors.right: revealBtn.left
        anchors.top: parent.top
        anchors.rightMargin: Style.spacing.xs
        placeholderText: "Identity (user@domain)"
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        foreground: root.fg
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        text: wifiRow.isPasswordOpen ? root.wifiIdentityText : ""
        onAccepted: passwordField.forceActiveFocus()
        onTextChanged: if (wifiRow.isPasswordOpen && text !== root.wifiIdentityText) root.wifiIdentityText = text
        Keys.onEscapePressed: root.cancelWifiPasswordPrompt()
      }

      TextField {
        id: passwordField
        visible: !wifiRow.isBusy && !wifiRow.isFailed
        anchors.left: parent.left
        anchors.right: revealBtn.left
        anchors.bottom: parent.bottom
        anchors.rightMargin: Style.spacing.xs
        password: !root.wifiPasswordRevealed
        placeholderText: "Passphrase"
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        foreground: root.fg
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        text: wifiRow.isPasswordOpen ? root.wifiPasswordText : ""
        onAccepted: wifiRow.submitCredentials()
        onTextChanged: if (wifiRow.isPasswordOpen && text !== root.wifiPasswordText) root.wifiPasswordText = text
        Keys.onEscapePressed: root.cancelWifiPasswordPrompt()
        onVisibleChanged: if (visible && !wifiRow.isEnterprise) Qt.callLater(forceActiveFocus)
        Component.onCompleted: if (visible && !wifiRow.isEnterprise) Qt.callLater(forceActiveFocus)
      }

      Button {
        id: revealBtn
        anchors.right: submitBtn.left
        anchors.bottom: parent.bottom
        anchors.rightMargin: Style.spacing.xs
        iconText: root.wifiPasswordRevealed ? "󰈈" : "󰈉"
        foreground: root.fg
        iconSize: Style.font.bodySmall
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        tooltipText: root.wifiPasswordRevealed ? "Hide passphrase" : "Show passphrase"
        onClicked: root.wifiPasswordRevealed = !root.wifiPasswordRevealed
      }

      Button {
        id: submitBtn
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        iconText: "󰄬"
        foreground: root.fg
        iconSize: Style.font.bodySmall
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        enabled: passwordField.text.length > 0 && (!wifiRow.isEnterprise || identityField.text.length > 0)
        opacity: enabled ? 1.0 : 0.4
        tooltipText: "Connect"
        onClicked: wifiRow.submitCredentials()
      }

      BorderSurface {
        id: statusBox
        visible: wifiRow.isBusy || wifiRow.isFailed
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: Style.spacing.controlHeight
        color: Style.normalFillFor(root.fg, Color.accent)
        borderSpec: Border.controlSpec("normal", root.fg, Color.accent)
        radius: Style.cornerRadius

        Text {
          anchors.fill: parent
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          text: wifiRow.isFailed ? (root.wifiFailureReason || "Failed") : "Connecting..."
          color: wifiRow.isFailed ? Color.urgent : root.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // One Bluetooth device row: type glyph, name, and live status. Pending state
  // is owned by the view so it survives rows moving between sections.
  component BtDeviceRow: CursorSurface {
    id: btRow
    required property var dev
    required property string section

    readonly property bool isConnected: !!(dev && dev.connected)
    readonly property string action: root.btPendingAction(dev && dev.address ? dev.address : "")
    readonly property bool isBusy: action !== ""
    readonly property int devState: dev && dev.state !== undefined ? dev.state : -1

    readonly property string statusText: {
      if (!dev) return ""
      if (action === "connecting" || devState === BluetoothDeviceState.Connecting || dev.pairing === true) return "Connecting…"
      if (action === "disconnecting" || devState === BluetoothDeviceState.Disconnecting) return "Disconnecting…"
      // Connected rows carry the state inline (there is no CONNECTED header
      // anymore): battery first when BlueZ reports it, then the state.
      if (isConnected) return dev.batteryAvailable ? Math.round(dev.battery * 100) + "% · Connected" : "Connected"
      if (section === "known") return "Paired"
      return ""
    }
    readonly property color statusColor: isConnected ? root.fg : root.dim

    hasCursor: btRowMouse.containsMouse
    current: isConnected
    foreground: root.fg
    fill: Style.hoverFillFor(root.fg, Color.accent)
    currentFill: Style.selectedFillFor(root.fg, Color.accent)

    // The row model is the panel's primitives-only projection, which drops the
    // BlueZ Icon class; resolve it from the live device (a string read only, no
    // wrapper is retained) and fall back to the plain Bluetooth mark.
    readonly property var liveDevice: root.btDeviceFor(btRow)

    function typeIcon() {
      var device = liveDevice
      if (!device) return "󰂯"
      var kind = String(device.icon || "").toLowerCase()
      if (kind.indexOf("head") !== -1 || kind.indexOf("audio") !== -1) return "󰋋"
      if (kind.indexOf("keyboard") !== -1) return "󰌌"
      if (kind.indexOf("mouse") !== -1 || kind.indexOf("pointer") !== -1) return "󰍽"
      if (kind.indexOf("phone") !== -1) return "󰏲"
      if (kind.indexOf("computer") !== -1) return "󰟀"
      if (kind.indexOf("game") !== -1 || kind.indexOf("joystick") !== -1) return "󰊴"
      return "󰂯"
    }

    implicitHeight: btContent.implicitHeight + Style.spacing.sm

    MouseArea {
      id: btRowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        var device = root.btDeviceFor(btRow)
        if (!device) return
        if (device.connected) root.disconnectBtDevice(device)
        else root.connectBtDevice(device)
      }
    }

    Item {
      id: btContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      implicitHeight: Math.max(btIcon.implicitHeight, btLabels.implicitHeight)

      Text {
        id: btIcon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: btRow.typeIcon()
        color: btRow.statusColor
        font.family: Style.font.family
        font.pixelSize: Style.font.title
      }

      Column {
        id: btLabels
        anchors.left: btIcon.right
        anchors.leftMargin: Style.space(8)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xxs

        Text {
          width: parent.width
          text: {
            if (!btRow.dev) return ""
            var label = BluetoothModel.deviceLabel(btRow.dev)
            return label !== "" ? label : (btRow.dev.address || "Device")
          }
          color: root.fg
          elide: Text.ElideRight
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          width: parent.width
          visible: btRow.statusText !== ""
          text: btRow.statusText
          color: btRow.statusColor
          elide: Text.ElideRight
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
