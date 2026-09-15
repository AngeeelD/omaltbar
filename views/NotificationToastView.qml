import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import qs.Commons
import qs.Ui
// The shell's own argv validator, imported rather than vendored: it is the
// exact function the notification service runs before executing a toast's
// click action, so a malformed/hostile execArgv is rejected here identically.
import "file:///usr/share/omarchy/shell/plugins/notifications/NotificationLogic.js" as NotificationLogic

// Minimal bespoke view for the auto-toast.
// Shows ONLY snapshots captured for island (ContextResolver.toastSnapshots) -
// no history files, no archive mixing. Falls back to live popupModel only
// when the resolver is unavailable (tests). Top-right overlay is cleared via
// ContextResolver.captureToast -> clearPopups, while island keeps snapshot.
//
// Clicking a card body runs the notification's default action (round 9):
// execArgv -> live "default" action -> focus the sending app. See
// invokeDefault below; execArgv is the path that survives the archive.
//
// Display duration is 10000ms (tweak 5000-10000) controlled via
// ContextResolver.notificationToastDuration and NotchIslandBar
// notificationToastDuration, with per-notification prune. View does not own
// its own lifetime. Empty state removed: views shows nothing when empty so the
// island collapses immediately without "No new notification" frame.
//
Item {
  id: root

  property var islandState: null
  property var islandBar: null

  readonly property color fg: Color.bar.text
  readonly property color dim: Util.alpha(Color.bar.text, 0.6)

  readonly property var notificationService: {
    var host = root.islandBar ? root.islandBar.shell : null
    if (!host || typeof host.firstPartyServiceFor !== "function") return null
    return host.firstPartyServiceFor("omarchy.notifications")
  }
  readonly property bool hasService: notificationService !== null

  // Prefer resolver snapshots; fallback to live model for tests
  // Bar exposes it as contextResolverState (id is not a property)
  readonly property var sourceSnapshots: {
    var cr = null
    if (root.islandBar) {
      cr = root.islandBar.contextResolverState || root.islandBar.contextResolver || null
    }
    return (cr && cr.toastSnapshots !== undefined) ? cr.toastSnapshots : null
  }

  property var entries: []
  property string entriesSignature: ""
  property double now: Date.now()

  // Mirrors NotificationsView budget so the card height never exceeds the island
  // body's ~420px budget. Two cards fit comfortably; excess is clipped via cap.
  readonly property int maxListHeight: Style.space(200)
  readonly property int scrollLane: Style.space(10)

  implicitHeight: content.implicitHeight

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.now = Date.now()
  }

  // --- live helpers (same shapes as NotificationsView, without history) ------
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
        liveRef: liveRefFor(row.originalId),
        actions: liveActionsFor(row.originalId)
      })
    }
    // Newest first so the freshest toast sits on top. Slice to max 2.
    out.sort(function(a, b) { return Number(b.timestamp) - Number(a.timestamp) })
    if (out.length > 2) out = out.slice(0, 2)
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

  function rebuild() {
    var live = []
    if (root.sourceSnapshots !== null) {
      var snaps = root.sourceSnapshots || []
      // snaps already newest first (capture pushes front); sort to be safe and cap at 2
      var sorted = snaps.slice()
      sorted.sort(function(a, b) { return Number(b.timestamp) - Number(a.timestamp) })
      if (sorted.length > 2) sorted = sorted.slice(0, 2)
      live = sorted
    } else {
      live = root.liveEntries()
    }
    var signature = live.length + "|"
      + (live.length > 0 ? live[0].key : "") + "|"
      + (live.length > 1 ? live[1].key : "")
    if (signature === root.entriesSignature) return
    root.entriesSignature = signature
    root.entries = live
  }

  function invokeAction(entry, identifier) {
    var ref = entry ? entry.liveRef : null
    if (!ref || !ref.actions) return
    for (var i = 0; i < ref.actions.length; i++) {
      var action = ref.actions[i]
      if (action && action.identifier === identifier) {
        try { action.invoke() } catch (e) {}
        return
      }
    }
  }

  // Whether a body tap can do anything: a persisted argv, a live "default"
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

  // The click action, in the shell's own order (Service.qml
  // invokePopupDefault) and then dismissed, exactly like the stock popup:
  //
  //   1. the persisted execArgv -> run it detached and dismiss. Omarchy's own
  //      toasts (screenshots, installer prompts) carry their action here, and
  //      it is the ONLY path that survives this island: captureToast clears the
  //      popup model, which kills the live ref and its libnotify actions.
  //   2. a live "default" action (third-party senders), while the ref is alive.
  //   3. focus the sending app by class (chat apps register no action at all).
  //
  // Pointer only, and only from an explicit click — a stored argv is never run
  // on its own (parseExecArgv is a structural check, not a trust decision: any
  // same-uid process can set the hint, so the user's click is the consent).
  function invokeDefault(entry) {
    if (!entry) return
    var argv = NotificationLogic.parseExecArgv(entry.execArgv)
    if (argv) {
      try { Util.execArgv(argv) } catch (e) {}
      root.dismissToast(entry)
      return
    }
    if (!root.invokeLiveDefault(entry)) root.focusApp(entry)
    root.dismissToast(entry)
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
  // place. It only reads `app`, so a snapshot entry is a valid argument.
  function focusApp(entry) {
    var svc = root.notificationService
    if (!svc || typeof svc.focusApp !== "function") return
    if (!entry || !String(entry.app || "")) return
    try { svc.focusApp({ app: String(entry.app) }) } catch (e) {}
  }

  function dismissLive(entry) {
    var svc = root.notificationService
    var model = svc ? svc.popupModel : null
    if (model) {
      for (var i = 0; i < model.count; i++) {
        var row = model.get(i)
        if (row && Number(row.originalId) === entry.originalId && Number(row.timestamp) === entry.timestamp) {
          if (typeof svc.dismissPopup === "function") {
            svc.dismissPopup(i)
            root.rebuild()
            return
          }
        }
      }
    }
    root.rebuild()
  }

  function dismissToast(entry) {
    if (!entry) return
    // Dismiss from the service first (only matches while the row is live).
    var svc = root.notificationService
    var model = svc ? svc.popupModel : null
    if (model) {
      for (var j = 0; j < model.count; j++) {
        var row = model.get(j)
        if (row && Number(row.originalId) === entry.originalId && Number(row.timestamp) === entry.timestamp) {
          if (typeof svc.dismissPopup === "function") {
            try { svc.dismissPopup(j) } catch(e) {}
            break
          }
        }
      }
    }
    // The snapshot write goes LAST and is followed by nothing. Dropping the
    // final snapshot ends the toast context, and the island collapsing can
    // unload this view synchronously — so any `root.` access after the write
    // would be a call on a destroyed object ("Property 'rebuild' ... is not a
    // function"). The resolver's change signal re-enters rebuild() on the way;
    // the explicit rebuild below only serves the service-less fallback, where
    // no snapshot was written and nothing was torn down.
    var cr = null
    if (root.islandBar) cr = root.islandBar.contextResolverState || root.islandBar.contextResolver || null
    if (cr && cr.toastSnapshots !== undefined) {
      var filtered = []
      for (var i = 0; i < cr.toastSnapshots.length; i++) if (cr.toastSnapshots[i].key !== entry.key) filtered.push(cr.toastSnapshots[i])
      cr.toastSnapshots = filtered
      return
    }
    root.rebuild()
  }

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

  Component.onCompleted: root.rebuild()

  Connections {
    target: root.notificationService ? root.notificationService.popupModel : null
    function onCountChanged() { root.rebuild() }
    function onDataChanged() { root.rebuild() }
  }

  Connections {
    target: root.islandBar ? (root.islandBar.contextResolverState || root.islandBar.contextResolver) : null
    function onToastSnapshotsChanged() { root.rebuild() }
  }

  Column {
    id: content
    width: root.width
    spacing: Style.spacing.sm

    // Live cards ------------------------------------------------------------
    Column {
      width: parent.width
      spacing: Style.space(4)
      visible: root.entries.length > 0

      Repeater {
        model: root.entries
        delegate: Rectangle {
          id: card
          required property var modelData
          width: parent.width - root.scrollLane
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
            onClicked: root.invokeDefault(card.modelData)
          }

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

            Row {
              // Snapshot entries carry no `actions` at all, so the `!!` keeps
              // an undefined from being assigned to `visible` (a bool).
              visible: !!(modelData.actions && modelData.actions.length > 0)
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
                  onClicked: root.invokeAction(card.modelData, modelData.identifier)
                }
              }
            }
          }

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
              onClicked: root.dismissToast(card.modelData)
            }
          }
        }
      }
    }

  }
}
