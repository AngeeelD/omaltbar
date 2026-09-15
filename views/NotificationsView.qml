import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import qs.Commons
import qs.Ui
// Reuse the shell's own persistence parser instead of vendoring a copy that
// would drift — the same absolute file-URL idiom ClockWeatherView already uses
// for the weather Model.js.
import "file:///usr/share/omarchy/shell/plugins/notifications/NotificationLogic.js" as NotificationLogic

// Native island view for the notification bar widget (registered for
// jankeesvw.notification-center in DynamicIsland.qml).
//
// SOURCE OF TRUTH (verified on Quickshell 0.3.1): the shell's own
// omarchy.notifications service owns the single org.freedesktop.Notifications
// server. This view never creates a second NotificationServer; a second one
// would lose the D-Bus name to the running shell. It reads the two stores that
// service already maintains:
//
//   - service.popupModel: the notifications currently on screen. Each row is
//     backed by a live Notification object (service.liveRefs[originalId]), so
//     the declared per-app actions can be listed and invoked. Dismissal is
//     delegated to the service's own dismissPopup(), which also archives the
//     row into history (that is the shell's designed behavior).
//   - ~/.local/state/omarchy/notifications/history/*.json: the archived
//     notifications, read exactly like the service's own history replay
//     (concatenate the files, parse with NotificationLogic.parsePopupFiles)
//     and deleted one file at a time on demand.
//
// Nothing is fabricated. With no live service and an empty archive the view
// renders an explicit empty state instead of inventing rows. An archived
// notification carries no declared live actions (those die with the sender),
// but it DOES keep the default `execArgv`, so a row tap can still run the
// notification's click action — see invokeDefault. Action buttons appear only
// for the live rows.
Item {
  id: root

  // Injected by DynamicIsland.
  property var islandState: null
  property var islandBar: null

  readonly property color fg: Color.bar.text
  readonly property color dim: Util.alpha(Color.bar.text, 0.6)

  readonly property string home: Quickshell.env("HOME")
  readonly property string historyDir: home + "/.local/state/omarchy/notifications/history"
  readonly property string imagesDir: home + "/.local/state/omarchy/notifications/images"
  // Our own read marker. Kept out of the shell's notification tree so the
  // service's history trimming never touches it.
  readonly property string stateDir: home + "/.local/state/notch-island"
  readonly property string seenPath: stateDir + "/notifications-seen.json"

  // The live notification service (same resolution Dnd.qml uses). Null is a
  // legitimate state: the service may be disabled or not yet loaded.
  readonly property var notificationService: {
    var host = root.islandBar ? root.islandBar.shell : null
    if (!host || typeof host.firstPartyServiceFor !== "function") return null
    return host.firstPartyServiceFor("omarchy.notifications")
  }
  readonly property bool hasService: notificationService !== null
  readonly property bool dnd: notificationService ? notificationService.doNotDisturb === true : false

  // Newest first, mixed sections: "live" rows come from popupModel, "archive"
  // rows from the history files. Both are JS arrays (never a ListModel) so a
  // Notification object that dies with the sender degrades to a catchable
  // error instead of a dangling C++ pointer.
  property var entries: []
  property var historyEntries: []
  property bool historyLoaded: false
  property string entriesSignature: ""

  // Read marker. `readMark` is the value captured at the moment this view
  // opened, so the unread dots stay up for the whole visit; `lastSeen` is the
  // updated value persisted for the next opening.
  property double readMark: 0
  property double lastSeen: 0
  property bool seenLoaded: false
  property double _pendingSeen: 0

  property double now: Date.now()

  readonly property int unreadCount: {
    var count = 0
    for (var i = 0; i < entries.length; i++)
      if (Number(entries[i].timestamp) > root.readMark) count++
    return count
  }

  readonly property int sectionCount: {
    var hasLive = false
    var hasArchive = false
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].section === "live") hasLive = true
      else hasArchive = true
    }
    return (hasLive ? 1 : 0) + (hasArchive ? 1 : 0)
  }

  implicitHeight: content.implicitHeight
  // Capped at ~20 rows worth: the list scrolls instead of growing the island
  // body past the ~420px budget (Style.space(300)=450px was the whole body).
  readonly property int maxListHeight: Style.space(200)
  readonly property int scrollLane: Style.space(10)
  readonly property int listHeight: entries.length === 0
    ? 0
    : Math.max(Style.space(40), Math.min(list.contentHeight, maxListHeight))

  // ------------------------------------------------------------------ timers
  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.now = Date.now()
  }

  // The archive is written whenever a toast leaves the screen. Watch the
  // history directory instead of polling it: each write (the service's atomic
  // rename into the directory) is one event -> one read, so no timer loops
  // while this view is open.
  FileView {
    path: root.historyDir
    watchChanges: true
    printErrors: false
    onFileChanged: root.readHistory()
  }

  // ------------------------------------------------------------------ reads
  Process {
    id: historyProc
    command: ["bash", "-c", "awk 1 \"$1\"/*.json 2>/dev/null || true", "--", root.historyDir]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyHistory(text)
    }
  }

  function readHistory() {
    if (historyProc.running) return
    historyProc.running = true
  }

  function applyHistory(raw) {
    root.historyEntries = NotificationLogic.parsePopupFiles(raw, NotificationUrgency.Normal)
    root.historyLoaded = true
    root.rebuild()
  }

  // Live rows come straight off the service's popupModel, joined to the live
  // Notification object so the row can carry real actions.
  function liveEntries() {
    var out = []
    var svc = root.notificationService
    var model = svc ? svc.popupModel : null
    if (!model) return out
    for (var i = 0; i < model.count; i++) {
      var row = model.get(i)
      if (!row || Number(row.originalId) < 0) continue
      out.push({
        key: entryKey(row),
        originalId: Number(row.originalId || 0),
        timestamp: Number(row.timestamp || 0),
        app: String(row.app || ""),
        appIcon: String(row.appIcon || ""),
        summary: String(row.summary || ""),
        body: String(row.body || ""),
        image: String(row.image || ""),
        glyph: String(row.glyph || ""),
        urgency: Number(row.urgency || 0),
        execArgv: String(row.execArgv || ""),
        section: "live",
        live: true,
        liveRef: liveRefFor(row.originalId),
        actions: liveActionsFor(row.originalId)
      })
    }
    return out
  }

  function liveRefFor(originalId) {
    var svc = root.notificationService
    if (!svc || !svc.liveRefs) return null
    return svc.liveRefs[Number(originalId)] || null
  }

  function liveActionsFor(originalId) {
    var out = []
    var ref = root.liveRefFor(originalId)
    if (!ref || !ref.actions) return out
    for (var i = 0; i < ref.actions.length; i++) {
      var action = ref.actions[i]
      if (!action || !action.identifier) continue
      out.push({
        identifier: String(action.identifier),
        text: String(action.text || action.identifier)
      })
    }
    return out
  }

  function entryKey(entry) {
    return String(entry.timestamp || 0) + "-" + String(entry.originalId || 0)
  }

  function archiveEntry(entry, key) {
    return {
      key: key,
      originalId: Number(entry.originalId || 0),
      timestamp: Number(entry.timestamp || 0),
      app: String(entry.app || ""),
      appIcon: String(entry.appIcon || ""),
      summary: String(entry.summary || ""),
      body: String(entry.body || ""),
      image: String(entry.image || ""),
      glyph: String(entry.glyph || ""),
      urgency: Number(entry.urgency || 0),
      // The archive DOES keep the default execArgv (NotificationLogic
      // historyEntry), which is what makes a restored/screenshot toast still
      // clickable — the live actions are the only part that does not survive.
      execArgv: String(entry.execArgv || ""),
      section: "archive",
      live: false,
      liveRef: null,
      actions: []
    }
  }

  // Rebuild only when the shape actually changed, so the poll above never
  // throws away the scroll position or every delegate for nothing.
  function rebuild() {
    var out = []
    var seen = ({})
    var live = root.liveEntries()
    for (var i = 0; i < live.length; i++) {
      out.push(live[i])
      seen[live[i].key] = true
    }
    var archive = root.historyEntries || []
    for (var j = 0; j < archive.length; j++) {
      var key = root.entryKey(archive[j])
      if (seen[key]) continue
      seen[key] = true
      out.push(root.archiveEntry(archive[j], key))
    }
    for (var k = 0; k < out.length; k++)
      out[k].showHeader = k === 0 || out[k - 1].section !== out[k].section

    var signature = out.length + "|"
      + (out.length > 0 ? out[0].key + "@" + out[0].section : "") + "|"
      + (out.length > 0 ? out[out.length - 1].key : "") + "|"
      + root.readMark
    if (signature === root.entriesSignature) return
    root.entriesSignature = signature
    root.entries = out
  }

  // ----------------------------------------------------------- read marker
  FileView {
    id: seenFile
    path: root.seenPath
    watchChanges: false
    printErrors: false
    atomicWrites: true
    onLoaded: root.applySeen(text())
    onLoadFailed: root.applySeen("")
  }

  Process {
    id: ensureStateDir
    command: ["mkdir", "-p", root.stateDir]
    onExited: root.writeSeen()
  }

  function applySeen(raw) {
    if (root.seenLoaded) return
    root.seenLoaded = true
    var value = 0
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (parsed && isFinite(Number(parsed.lastSeen))) value = Number(parsed.lastSeen)
    } catch (e) {
      // No marker yet (first run) or a torn file: everything counts as unread.
    }
    root.readMark = value
    root.lastSeen = value
    root.rebuild()
    root.markSeen()
  }

  function markSeen() {
    var stamp = Date.now()
    root.lastSeen = stamp
    root._pendingSeen = stamp
    if (!ensureStateDir.running) root.writeSeen()
  }

  function writeSeen() {
    if (root._pendingSeen <= 0) return
    seenFile.setText(JSON.stringify({ lastSeen: root._pendingSeen }))
    root._pendingSeen = 0
  }

  // ----------------------------------------------------------------- actions
  function toggleDnd() {
    var svc = root.notificationService
    if (svc) svc.setDoNotDisturb(!svc.doNotDisturb)
  }

  function invokeAction(entry, identifier) {
    var ref = entry ? entry.liveRef : null
    if (!ref || !ref.actions) return
    for (var i = 0; i < ref.actions.length; i++) {
      var action = ref.actions[i]
      if (action && action.identifier === identifier) {
        try {
          action.invoke()
        } catch (e) {
          // Notification torn down by the sender between rebuild and click.
        }
        return
      }
    }
  }

  // Whether a row-body tap can do anything: a persisted argv, a live "default"
  // action, or at least an app to focus. Drives the pointing cursor.
  function entryActionable(entry) {
    if (!entry) return false
    if (NotificationLogic.parseExecArgv(entry.execArgv)) return true
    var ref = entry.liveRef
    if (ref && ref.actions) {
      for (var i = 0; i < ref.actions.length; i++) {
        if (ref.actions[i] && ref.actions[i].identifier === "default") return true
      }
    }
    return String(entry.app || "") !== ""
  }

  // Body tap: the same cascade the stock card runs and the toast view runs
  // (execArgv -> live "default" -> focus the sender), so a row behaves the same
  // whether it is still on screen or was read back from history. Archived rows
  // only ever have the first path; the archive keeps the argv and drops the
  // live actions. A stored argv runs only from this explicit click.
  function invokeDefault(entry) {
    if (!entry) return
    var argv = NotificationLogic.parseExecArgv(entry.execArgv)
    if (argv) {
      try { Util.execArgv(argv) } catch (e) {}
      root.afterInvoke(entry)
      return
    }
    if (!root.invokeLiveDefault(entry)) root.focusApp(entry)
    root.afterInvoke(entry)
  }

  function invokeLiveDefault(entry) {
    var ref = entry ? entry.liveRef : null
    if (!ref || !ref.actions) return false
    for (var i = 0; i < ref.actions.length; i++) {
      var action = ref.actions[i]
      if (action && action.identifier === "default") {
        try {
          action.invoke()
          return true
        } catch (e) {
          return false
        }
      }
    }
    return false
  }

  // Reuse the service's own focus helper so the class matching stays in one
  // place. It only reads `app`, so a row entry is a valid argument.
  function focusApp(entry) {
    var svc = root.notificationService
    if (!svc || typeof svc.focusApp !== "function") return
    if (!entry || !String(entry.app || "")) return
    try { svc.focusApp({ app: String(entry.app) }) } catch (e) {}
  }

  // A live row IS the on-screen toast, so running its action dismisses it —
  // exactly what the stock popup does. An archived row is a history record:
  // its action runs, the record stays until the ✕ or Clear all removes it.
  function afterInvoke(entry) {
    if (entry && entry.live) root.dismissLive(entry)
  }

  // Live rows go through the service so restored rows (no live object) and the
  // archive-on-leave behavior are handled exactly as a toast dismissal is.
  function dismissLive(entry) {
    var svc = root.notificationService
    var model = svc ? svc.popupModel : null
    if (model) {
      for (var i = 0; i < model.count; i++) {
        var row = model.get(i)
        if (row && Number(row.originalId) === entry.originalId && Number(row.timestamp) === entry.timestamp) {
          if (typeof svc.dismissPopup === "function") {
            // The model change re-enters through the Connections below, which
            // rebuilds this view. Nothing may touch `root` after this call:
            // dismissing the last live row can end the notifications context
            // and unload this view synchronously.
            svc.dismissPopup(i)
            return
          }
        }
      }
    }
    root.rebuild()
  }

  // Archived rows are plain files, so a per-row delete is a file delete. Same
  // two paths the service's own deletePopupFileFor uses, pointed at history/.
  function deleteArchived(entry) {
    Quickshell.execDetached([
      "bash", "-c", "rm -f \"$1/$2.json\" \"$3/$2\"-*", "--",
      root.historyDir, entry.key, root.imagesDir
    ])
    var next = []
    for (var i = 0; i < root.historyEntries.length; i++)
      if (root.entryKey(root.historyEntries[i]) !== entry.key) next.push(root.historyEntries[i])
    root.historyEntries = next
    root.rebuild()
  }

  property bool clearArmed: false

  function clearAll() {
    var svc = root.notificationService
    if (svc) {
      // Dismiss the on-screen toasts first — that archives them into history —
      // and only then clear history, so the just-dismissed toasts cannot be
      // left behind. Both are public service methods and both run through the
      // service's serialized file queue, so this order is preserved on disk.
      if (typeof svc.clearPopups === "function") svc.clearPopups()
      if (typeof svc.clearHistory === "function") svc.clearHistory()
    }
    root.historyEntries = []
    root.rebuild()
  }

  // ------------------------------------------------------------------- icons
  function resolveIcon(value) {
    var icon = String(value || "")
    if (icon === "") return ""
    if (icon.indexOf("file://") === 0 || icon.indexOf("image://") === 0) return icon
    if (icon.charAt(0) === "/") return Util.fileUrl(icon)
    return Quickshell.iconPath(icon, true)
  }

  function entryIcon(entry) {
    return root.resolveIcon(entry.image !== "" ? entry.image : entry.appIcon)
  }

  function entryGlyph(entry) {
    if (entry.glyph !== "") return entry.glyph
    var app = String(entry.app || "")
    return app === "" ? "󰂚" : app.charAt(0).toUpperCase()
  }

  function relativeTime(timestamp) {
    var age = Math.max(0, root.now - Number(timestamp || 0))
    if (age < 60000) return "now"
    if (age < 3600000) return Math.round(age / 60000) + "m"
    if (age < 86400000) return Math.round(age / 3600000) + "h"
    return Qt.formatDateTime(new Date(Number(timestamp)), "d MMM")
  }

  function cleanText(value) {
    return String(value || "")
      .replace(/<img[^>]*>/gi, "")
      .replace(/<[^>]+>/g, " ")
      .replace(/\s+/g, " ")
      .trim()
  }

  // --------------------------------------------------------------- lifecycle
  Component.onCompleted: {
    ensureStateDir.running = true
    root.readHistory()
  }

  Connections {
    target: root.notificationService ? root.notificationService.popupModel : null
    // A dismissal both empties the live model and (just after) writes the
    // archive file, so re-read history here as well as on the directory watch.
    function onCountChanged() { root.readHistory(); root.rebuild() }
    function onDataChanged() { root.rebuild() }
  }

  // ------------------------------------------------------------------ layout
  Column {
    id: content
    width: root.width
    spacing: Style.spacing.sm

    // header: title + unread badge on the left, controls on the right --------
    Item {
      id: header
      width: parent.width
      implicitHeight: Math.max(titleRow.implicitHeight, controls.implicitHeight)

      Row {
        id: titleRow
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.sm

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "Notifications"
          color: root.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.weight: Font.DemiBold
        }

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          visible: root.unreadCount > 0
          width: badgeText.implicitWidth + Style.space(10)
          height: Style.space(15)
          radius: height / 2
          color: Color.accent

          Text {
            id: badgeText
            anchors.centerIn: parent
            text: root.unreadCount > 99 ? "99+" : String(root.unreadCount)
            color: Color.background
            font.family: Style.font.family
            font.pixelSize: Math.max(8, Style.font.caption - Style.space(2))
            font.bold: true
          }
        }
      }

      Row {
        id: controls
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.controlGap

        Button {
          // A bell, and a bell-off while silenced. Same glyphs the shell's own
          // DND indicator and the notification widget use.
          iconText: root.dnd ? "󰂛" : "󰂚"
          selected: root.dnd
          foreground: root.fg
          enabled: root.hasService
          opacity: root.hasService ? 1.0 : 0.4
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          tooltipText: root.dnd ? "Allow notifications" : "Silence notifications"
          onClicked: root.toggleDnd()
        }

        Button {
          text: root.clearArmed ? "Sure?" : "Clear"
          foreground: root.clearArmed ? Color.urgent : root.fg
          fontSize: Style.font.caption
          enabled: root.entries.length > 0
          opacity: enabled ? 1.0 : 0.4
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          tooltipText: "Delete every notification kept here"
          onClicked: {
            if (root.clearArmed) {
              root.clearArmed = false
              disarm.stop()
              root.clearAll()
            } else {
              root.clearArmed = true
              disarm.restart()
            }
          }
        }
      }

      Timer {
        id: disarm
        interval: 4000
        onTriggered: root.clearArmed = false
      }
    }

    // list ------------------------------------------------------------------
    ListView {
      id: list
      width: parent.width
      implicitHeight: root.listHeight
      height: implicitHeight
      visible: root.entries.length > 0
      clip: true
      model: root.entries
      spacing: Style.space(4)
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      delegate: Column {
        id: rowItem
        required property var modelData
        width: list.width
        spacing: Style.space(4)

        Text {
          visible: modelData.showHeader && root.sectionCount > 1
          text: modelData.section === "live" ? "ON SCREEN" : "RECENT"
          color: root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
        }

        Rectangle {
          id: card
          width: rowItem.width - root.scrollLane
          implicitHeight: Math.max(iconSlot.height, contentColumn.implicitHeight) + Style.space(12)
          radius: Style.space(10)
          color: cardHover.hovered ? Util.alpha(root.fg, 0.11) : Util.alpha(root.fg, 0.06)

          Behavior on color { ColorAnimation { duration: 90 } }
          HoverHandler { id: cardHover }

          // Body tap: run the default action (see invokeDefault). Declared
          // before the content so the action buttons and the ✕ — later siblings
          // inside this card — take their own clicks first.
          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            hoverEnabled: true
            cursorShape: root.entryActionable(modelData) ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.invokeDefault(rowItem.modelData)
          }

          // Critical urgency keeps the one piece of colour on the card.
          Rectangle {
            visible: modelData.urgency === 2
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(6)
            width: Style.space(3)
            radius: width / 2
            color: Color.urgent
          }

          // Unread marker: a dot on the leading edge, gone on the next open.
          Rectangle {
            visible: modelData.timestamp > root.readMark && modelData.urgency !== 2
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(5)
            height: width
            radius: width / 2
            color: Color.accent
          }

          Item {
            id: iconSlot
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10) + Style.space(4)
            anchors.top: parent.top
            anchors.topMargin: Style.space(8)
            width: Style.space(26)
            height: Style.space(26)

            Rectangle {
              anchors.fill: parent
              radius: Style.space(8)
              visible: iconImage.status !== Image.Ready
              color: Util.alpha(root.fg, 0.12)
            }

            Text {
              anchors.centerIn: parent
              visible: iconImage.status !== Image.Ready
              text: root.entryGlyph(modelData)
              color: root.fg
              opacity: 0.8
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Image {
              id: iconImage
              anchors.fill: parent
              source: root.entryIcon(modelData)
              sourceSize.width: width * 2
              sourceSize.height: height * 2
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              smooth: true
              visible: status === Image.Ready
            }
          }

          Column {
            id: contentColumn
            anchors.left: iconSlot.right
            anchors.leftMargin: Style.space(10)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.top: parent.top
            anchors.topMargin: Style.space(8)
            spacing: Style.space(1)

            // app + when. A row, not a filled Row, because the app name and
            // time are anchored to opposite edges.
            Item {
              width: parent.width
              height: Math.max(appText.implicitHeight, whenText.implicitHeight)

              Text {
                id: appText
                anchors.left: parent.left
                width: Math.max(0, parent.width - whenText.width - Style.space(8))
                text: modelData.app
                color: root.dim
                elide: Text.ElideRight
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Text {
                id: whenText
                anchors.right: parent.right
                text: root.relativeTime(modelData.timestamp)
                color: root.dim
                opacity: 0.8
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              width: parent.width
              visible: text !== ""
              text: root.cleanText(modelData.summary)
              color: root.fg
              elide: Text.ElideRight
              maximumLineCount: 1
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Text {
              width: parent.width
              visible: text !== ""
              text: root.cleanText(modelData.body)
              color: root.fg
              opacity: 0.75
              wrapMode: Text.WordWrap
              elide: Text.ElideRight
              maximumLineCount: 2
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            // Declared actions. Only live rows carry them (they die with the
            // sender). The archive keeps just the default argv, which a tap on
            // the row body runs — buttons would be redundant with invokeDefault,
            // so they stay live-only.
            Row {
              visible: modelData.actions && modelData.actions.length > 0
              spacing: Style.spacing.controlGap

              Repeater {
                model: modelData.actions

                Button {
                  required property var modelData
                  text: modelData.text
                  foreground: root.fg
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY
                  bordered: true
                  onClicked: root.invokeAction(rowItem.modelData, modelData.identifier)
                }
              }
            }
          }

          // Dismiss. Live rows hand the toast to the service; archived rows
          // delete the history file outright.
          Item {
            id: dismiss
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: Style.space(3)
            anchors.rightMargin: Style.space(3)
            width: Style.space(18)
            height: Style.space(18)
            z: 2

            Rectangle {
              anchors.fill: parent
              radius: width / 2
              color: Util.alpha(root.fg, dismissMouse.containsMouse ? 0.28 : 0.16)
            }

            Text {
              anchors.centerIn: parent
              text: "✕"
              color: root.fg
              opacity: 0.85
              font.family: Style.font.family
              font.pixelSize: Math.max(8, Style.font.caption - Style.space(2))
            }

            MouseArea {
              id: dismissMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (rowItem.modelData.live) root.dismissLive(rowItem.modelData)
                else root.deleteArchived(rowItem.modelData)
              }
            }
          }
        }
      }
    }

    // empty / unavailable ---------------------------------------------------
    Column {
      width: parent.width
      visible: root.entries.length === 0
      spacing: Style.spacing.sm
      topPadding: Style.space(18)
      bottomPadding: Style.space(18)

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "󰂚"
        color: root.fg
        opacity: 0.6
        font.family: Style.font.family
        font.pixelSize: Style.font.display
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: !root.historyLoaded ? "Reading notifications…"
          : !root.hasService ? "Notification service unavailable"
          : "No notifications"
        color: root.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.weight: Font.Medium
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(implicitWidth, root.width - Style.space(24))
        visible: root.historyLoaded
        text: !root.hasService
          ? "The shell's notification service is not running."
          : "Nothing has been received yet."
        color: root.dim
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}
