import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Keyboard-first window switcher overlay with a live window peek.
//
// Opened with `omarchy-shell shell toggle piyush.omaswitch` (bind it to
// a key in ~/.config/hypr/bindings.lua). Lists Hyprland toplevels from the
// Quickshell Hyprland singleton, filters live as you type, and focuses the
// selection through the native Wayland toplevel API, with hyprctl as fallback.
//
// The right side shows a live preview (Windows-11-style "peek") of the
// highlighted window via a single ScreencopyView bound to that window's
// Wayland toplevel handle. One live stream, not one per window. If the
// compositor lacks the hyprland-toplevel-export protocol (or the view gets
// no frames), hasContent stays false and the list simply stays full-width —
// the same layout as the plain list version.

Item {
  id: root

  property var shell: null
  property var manifest: null

  // The plugin host hides us by calling close() after removing us from
  // openPanelIds; we must not fight it, so `opened` is only our UI state.
  property bool opened: false
  property bool cycleMode: false

  // macOS-style quick switch. A tap of the cycle key means "go back to the
  // previous window" - the user already knows where they are going, so showing
  // the overlay for 100ms just flashes the screen. The panel is still mapped
  // immediately (it must be, to hold keyboard focus and see the modifier
  // release), but it draws nothing until the reveal delay passes. Hold the
  // modifier longer than that and the switcher appears as usual.
  // Tune per binding with {"revealDelay": <ms>}; 0 shows it immediately.
  property bool revealed: false
  property int revealDelay: 180

  // Clicking a window while the switcher is up should go to that window and
  // close the switcher - without having to release the modifier first.
  //
  // Masking our input region down to the card so the compositor routes the
  // click to the window underneath does NOT work here: Hyprland then tells us
  // nothing. Nine logged sessions showed no activewindow event while this
  // layer held exclusive keyboard focus, so the overlay could not know the
  // click happened and stayed up, and the modifier release then overrode the
  // user's choice with the list selection.
  //
  // So the overlay keeps the whole screen as its input region, consumes the
  // click, resolves the window under the pointer itself, focuses it and
  // closes. The trade-off is that the click does not also press whatever was
  // under it - it selects the window, like clicking a taskbar entry.
  // ---- mouse toggles -------------------------------------------------------
  // mouseEnabled     master switch. false = the switcher never touches the
  //                  pointer: no hover, no click handling, and SUPER+left-click
  //                  is never borrowed, so it stays Omarchy's window drag.
  // hoverSelects     hovering a row moves the selection.
  // clickSelectsWindow  a click outside the card focuses the window underneath
  //                  instead of simply cancelling.
  //
  // Worth knowing when turning these on: with input:follow_mouse = 1 and
  // input:mouse_refocus = true (both Omarchy defaults), the compositor marks
  // whatever sits under the pointer as active the moment this overlay's layer
  // is torn down - so the window under the cursor can take the highlight while
  // the clicked window keeps the keyboard. Setting input:mouse_refocus = false
  // in ~/.config/hypr/input.lua stops that.
  property bool mouseEnabled: true
  property bool hoverSelects: true

  // clickSelects is OFF: clicking a row to focus it worked, but the window
  // left under the pointer takes the active highlight the moment this overlay
  // closes (input:follow_mouse + input:mouse_refocus), so the keyboard and the
  // border disagree and it reads as a bug.
  //
  // Re-enabling it: turn this true AND let the pointer follow the focused
  // window, so the window under the cursor IS the focused one and there is
  // nothing to disagree about. In ~/.config/hypr/looknfeel.lua:
  //
  //   hl.config({ cursor = { no_warps = false } })
  //
  // Hover still selects with this off - point at a row and release the
  // modifier - and SUPER+left-click is never borrowed, so it stays Omarchy's
  // window drag even while the switcher is open.
  property bool clickSelects: false
  property bool clickSelectsWindow: true
  property string filterText: ""
  property int selectedIndex: 0

  // Raw toplevels (live objects from the Hyprland singleton) + filtered rows.
  property var allWindows: []
  property var rows: []

  // The static "Switch window…" header said nothing the user did not already
  // know, so the row only exists while there is a filter to show.
  readonly property bool filtering: root.filterText !== ""
  readonly property int titleFont: Style.font.heading
  readonly property int detailFont: Style.font.body
  readonly property int headerHeight: root.filtering
    ? Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
    : 0
  readonly property int rowHeight: Math.max(Style.space(58), root.titleFont + root.detailFont + Style.spacing.rowPaddingX * 2)
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int listGap: root.filtering ? Style.space(4) : 0
  readonly property int gap: Style.space(12)

  // Guard the index: assigning a shorter rows array notifies bindings before
  // rebuildRows() gets to clamp selectedIndex.
  readonly property var selectedToplevel: selectedIndex >= 0 && selectedIndex < rows.length ? rows[selectedIndex] : null
  readonly property bool previewWanted: root.opened && root.selectedToplevel !== null && !!root.selectedToplevel.wayland
  // hasContent drops to false while ScreencopyView acquires its first frame
  // from a newly selected window. Sizing the card off it directly made the
  // preview pane collapse and the whole card snap 1080 -> 760 -> 1080 on every
  // cycle step: a visible flicker. Once the compositor has proven it can
  // export a window, keep the pane's geometry reserved for the session; a
  // compositor without hyprland-toplevel-export never latches and the list
  // stays full-width as before.
  property bool previewLatched: false
  readonly property bool previewActive: root.previewWanted && (previewView.hasContent || root.previewLatched)

  readonly property int cardWidth: Math.min(root.previewActive ? Style.space(1080) : Style.space(760), panel.width - Style.gapsOut * 2)
  readonly property int desiredListHeight: Math.max(root.rowHeight, rows.length * root.rowHeight)
  readonly property int desiredCardHeight: root.contentMargin * 2 + root.headerHeight + root.listGap + root.desiredListHeight
  readonly property int cardHeight: Math.min(
    Math.max(root.previewActive ? Style.space(400) : 0, root.desiredCardHeight),
    panel.height - Style.gapsOut * 2)
  readonly property int contentHeight: Math.max(0, root.cardHeight - root.contentMargin * 2)
  readonly property int innerWidth: Math.max(0, root.cardWidth - root.contentMargin * 2)
  readonly property int listWidth: root.previewActive ? Math.max(Style.space(300), Math.round(root.innerWidth * 0.40)) : root.innerWidth
  readonly property int previewWidth: root.previewActive ? Math.max(0, root.innerWidth - root.listWidth - root.gap) : 0
  readonly property int listHeight: Math.max(0, root.contentHeight - root.headerHeight - root.listGap)
  // Positive before the pane appears, so ScreencopyView can obtain its first
  // frame and flip hasContent without depending on a zero-sized parent.
  readonly property int previewConstraintWidth: Math.max(1, Math.min(Style.space(580), panel.width - Style.space(420)))
  readonly property int previewConstraintHeight: Math.max(1, Math.min(Style.space(360), panel.height - Style.gapsOut * 2 - root.contentMargin * 2))

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property bool showScrim: false
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily

  // Application icons. The window gives us an app id ("firefox",
  // "com.mitchellh.ghostty"); the desktop entry for it gives the icon NAME,
  // which the shell's AppLibrary then resolves to a file (it keeps an index for
  // icons installed after this process started, and falls back to a generic
  // executable icon). Both lookups are cached: this runs per delegate, per
  // repaint.
  property bool showIcons: true
  property int iconSize: Math.max(16, Math.round(root.rowHeight * 0.62) - 12)
  property var entryIndex: null
  property var iconCache: ({})

  function desktopEntryFor(id) {
    if (root.entryIndex === null) {
      var index = ({})
      try {
        var values = (DesktopEntries.applications && DesktopEntries.applications.values) || []
        for (var i = 0; i < values.length; i++) {
          var entry = values[i]
          if (!entry) continue
          var keys = [entry.id, entry.name, entry.startupClass]
          for (var k = 0; k < keys.length; k++) {
            var key = String(keys[k] || "").toLowerCase().replace(/\.desktop$/, "")
            if (key && index[key] === undefined) index[key] = entry
          }
        }
      } catch (e) {
        // A Quickshell without DesktopEntries just means no icons.
      }
      root.entryIndex = index
    }
    var want = String(id || "").toLowerCase().replace(/\.desktop$/, "")
    if (!want) return null
    return root.entryIndex[want] || root.entryIndex[want.split(".").pop()] || null
  }

  function resolveIcon(id) {
    var entry = root.desktopEntryFor(id)
    var name = entry && entry.icon ? String(entry.icon) : String(id)
    try {
      return root.shell && root.shell.appLibrary
        ? String(root.shell.appLibrary.iconSource(name) || "")
        : String(Quickshell.iconPath(name, true) || "")
    } catch (e) {
      return ""
    }
  }

  // Resolved once per refresh, never from inside a delegate binding: reading
  // and writing the cache during binding evaluation is a binding loop.
  // Delegates only ever read the finished map.
  function rebuildIcons() {
    if (!root.showIcons) { root.iconCache = ({}); return }
    var next = ({})
    var changed = false
    for (var i = 0; i < root.allWindows.length; i++) {
      var id = Model.appId(root.allWindows[i])
      if (!id || next[id] !== undefined) continue
      next[id] = root.iconCache[id] !== undefined ? root.iconCache[id] : root.resolveIcon(id)
      if (root.iconCache[id] === undefined) changed = true
    }
    for (var key in root.iconCache) if (next[key] === undefined) changed = true
    if (changed) root.iconCache = next
  }

  // keepSelection: follow the selected WINDOW across a rebuild rather than
  // holding an index. A refresh triggered by a compositor event must not slide
  // the highlight onto a different window under the user's fingers.
  // Captured when the switcher opens: the overlay taking focus does not change
  // the workspace, and a live binding would only add churn.
  property int currentWorkspaceId: -1

  function captureCurrentWorkspace() {
    var id = -1
    try {
      if (Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id !== undefined)
        id = Number(Hyprland.focusedWorkspace.id)
    } catch (e) {
      id = -1
    }
    // Fallback: rows[0] is the window you are on, so its workspace is yours.
    if (!(id > 0) && root.rows.length > 0 && root.rows[0] && root.rows[0].workspace)
      id = Number(root.rows[0].workspace.id)
    root.currentWorkspaceId = isFinite(id) ? id : -1
  }

  Component.onDestruction: if (root.opened) root.grabClickBinding(false)

  function rebuildRows(keepSelection) {
    var previous = keepSelection ? (rows[selectedIndex] || null) : null
    rows = Model.filteredWindows(allWindows, filterText)
    if (previous) {
      var at = rows.indexOf(previous)
      if (at !== -1) {
        selectedIndex = at
        return
      }
    }
    if (selectedIndex >= rows.length) selectedIndex = Math.max(0, rows.length - 1)
    if (selectedIndex < 0 && rows.length > 0) selectedIndex = 0
  }

  function setFilter(value) {
    filterText = value
    selectedIndex = 0
    rebuildRows(false)
  }

  function refresh(keepSelection) {
    var sorted = Model.sortedWindows(Hyprland.toplevels.values)
    if (!root.opened || root.allWindows.length === 0) {
      root.allWindows = sorted
    } else {
      // Most-recently-used order is only meaningful at the moment the switcher
      // opens. Hyprland emits activewindow as this overlay takes focus, and
      // re-sorting on that event reshuffles the list while the user is aiming
      // at a row. Keep the established order; take only additions and removals.
      var kept = []
      for (var i = 0; i < root.allWindows.length; i++)
        if (sorted.indexOf(root.allWindows[i]) !== -1) kept.push(root.allWindows[i])
      for (var j = 0; j < sorted.length; j++)
        if (kept.indexOf(sorted[j]) === -1) kept.push(sorted[j])
      root.allWindows = kept
    }
    rebuildIcons()
    rebuildRows(keepSelection === true)
  }

  // Focus must be applied AFTER this overlay is gone. The panel holds
  // exclusive keyboard focus while it is visible, so a focus dispatch issued
  // before it closes is undone the moment the compositor tears the layer down
  // and restores focus to the window that was active before we opened.
  // Dismiss first, then dispatch on the next tick.
  property var pendingWindow: null
  property string pendingCommand: ""

  function focusSelected() {
    var window = rows[selectedIndex]
    if (!window) return root.dismiss()
    root.pendingCommand = Model.focusCommand(window) || ""
    root.pendingWindow = window
    root.dismiss()
    focusTimer.restart()
  }

  Timer {
    id: focusTimer
    interval: 80
    repeat: false
    onTriggered: {
      var window = root.pendingWindow
      if (root.pendingCommand) {
        Quickshell.execDetached(["sh", "-c", root.pendingCommand])
      } else if (window && window.wayland && typeof window.wayland.activate === "function") {
        window.wayland.activate()
      }
      root.pendingCommand = ""
      root.pendingWindow = null
    }
  }

  Timer {
    id: revealTimer
    interval: root.revealDelay
    repeat: false
    onTriggered: if (root.opened) root.revealed = true
  }

  // A click that landed outside the card: focus whatever window is there and
  // close. Falls back to a plain cancel when the click hit no window (the bar,
  // the desktop), which is what clicking "nothing" should do anyway.
  function activateWindowAt(x, y) {
    var target = Model.windowAt(Hyprland.toplevels.values, x, y, root.currentWorkspaceId)
    if (!target) return root.dismiss()
    root.pendingCommand = Model.focusCommand(target) || ""
    root.pendingWindow = target
    root.dismiss()
    focusTimer.restart()
  }

  function select(delta) {
    if (rows.length === 0) return
    selectedIndex = (selectedIndex + delta + rows.length) % rows.length
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    var direction = Number(payload.direction) < 0 ? -1 : 1

    // Repeated Alt+Tab summons cycle instead of resetting or closing.
    if (root.opened && payload.mode === "cycle") {
      root.cycleMode = true
      root.select(direction)
      return
    }

    root.opened = true
    root.cycleMode = payload.mode === "cycle"
    var requested = Number(payload.revealDelay)
    root.revealDelay = isFinite(requested) && requested >= 0 ? requested : 180
    // Only a cycle summon is a candidate for the quick path; an explicit
    // toggle/summon of the picker should appear at once.
    root.revealed = !root.cycleMode || root.revealDelay === 0
    if (!root.revealed) revealTimer.restart()
    root.filterText = ""
    root.selectedIndex = 0
    root.allWindows = []          // a fresh summon re-sorts by MRU
    root.rows = []                // ... and does not inherit the old selection
    root.refresh(false)
    root.captureCurrentWorkspace()
    root.pointerOverList = false
    root.grabClickBinding(true)
    // rows[0] is the window you are on (sortedWindows ranks by focus history),
    // so a cycle summon always starts on the next candidate: the previous
    // window going forward, the least recent going back. Probing isCurrent()
    // here used to suppress that step whenever the compositor reported no
    // activated window - e.g. when focus had already moved to this overlay.
    if (root.cycleMode && root.rows.length > 1)
      root.selectedIndex = direction < 0 ? root.rows.length - 1 : 1
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    focusGrab.restart()
  }

  function close() {
    root.opened = false
    root.grabClickBinding(false)
    root.cycleMode = false
    root.revealed = false
    revealTimer.stop()
  }

  // User-initiated dismissal also drops the host's openPanelIds entry.
  function dismiss() {
    root.opened = false
    root.grabClickBinding(false)
    root.cycleMode = false
    root.revealed = false
    revealTimer.stop()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "piyush.omaswitch")
  }

  // Hyprland resolves its own keybinds before handing keys to a layer
  // surface, so a bound combination (e.g. Omarchy's SUPER+ESCAPE system menu)
  // never reaches this overlay while the modifier is held. A binding can call
  // this over IPC to give the switcher first refusal on the key:
  //   omarchy-shell shell call piyush.omaswitch dismissIfOpen ""
  // Answers "closed" when it consumed the key, "idle" when it was not open.
  function dismissIfOpen() {
    if (!root.opened) return "idle"
    root.dismiss()
    return "closed"
  }

  // The left mouse button is SUPER+mouse:272 ("Move window") in Omarchy, so
  // while Super is held - which is always, when the switcher is up - Hyprland
  // takes the button press and this overlay never sees it. Pointer MOTION does
  // arrive, which is why hovering worked and clicking did not.
  //
  // Rebinding that button globally is not acceptable: an exec wrapper cannot
  // start a window drag, because the compositor has to own the press for the
  // whole gesture. So the switcher borrows the button only while it is open
  // and hands it straight back on close - see grabClickBinding().
  //
  // No cursor position is passed: motion events already tell us where the
  // pointer is and whether it is over a row.
  property bool pointerOverList: false
  property real pointerX: 0
  property real pointerY: 0

  function clickAt() {
    if (!root.opened || !root.mouseEnabled || !root.clickSelects) return "idle"
    if (root.pointerOverList) {
      // Hover has already selected the row under the pointer.
      root.focusSelected()
    } else {
      var originX = panel.screen ? panel.screen.x : 0
      var originY = panel.screen ? panel.screen.y : 0
      root.activateWindowAt(originX + root.pointerX, originY + root.pointerY)
    }
    return "handled"
  }

  readonly property string clickBindTarget: "'SUPER + mouse:272'"

  // Borrow SUPER+left-click for as long as the switcher is up. Restoring binds
  // Omarchy's own dispatcher back, not a wrapper, so dragging windows behaves
  // exactly as it did before - the compositor owns the press again.
  function grabClickBinding(grab) {
    if (grab && (!root.mouseEnabled || !root.clickSelects)) return
    var lua = grab
      // NOTE: no `{ mouse = true }` here. That flag is Hyprland's bindm, which
      // only drives drag dispatchers (move/resize) - an exec bound that way
      // never fires on click. The restore below DOES need it, because the drag
      // is exactly what it is for.
      ? "hl.unbind(" + root.clickBindTarget + "); hl.bind(" + root.clickBindTarget +
        ", hl.dsp.exec_cmd([[omarchy-shell -q shell call piyush.omaswitch clickAt '']]))"
      : "hl.unbind(" + root.clickBindTarget + "); hl.bind(" + root.clickBindTarget +
        ", hl.dsp.window.drag(), { mouse = true })"
    Quickshell.execDetached(["sh", "-c", "hyprctl eval \"" + lua + "\" >/dev/null 2>&1"])
  }

  // Companion to dismissIfOpen() for keys Hyprland binds globally: the arrow
  // keys are SUPER+UP/DOWN ("focus above/below window") in Omarchy, so they
  // never reach this overlay while Super is held.
  //   omarchy-shell shell call piyush.omaswitch navigateIfOpen prev
  // Accepts "prev"/"up"/"-1" or "next"/"down"/"1". Answers "moved" when it
  // consumed the key, "idle" when the switcher was not open.
  function navigateIfOpen(arg) {
    if (!root.opened) return "idle"
    var value = String(arg === undefined || arg === null ? "" : arg).trim().toLowerCase()
    var back = value === "prev" || value === "up" || value === "-1" || Number(value) < 0
    root.select(back ? -1 : 1)
    return "moved"
  }

  Connections {
    target: DesktopEntries.applications
    ignoreUnknownSignals: true
    function onValuesChanged() {
      root.entryIndex = null
      root.iconCache = ({})
      if (root.opened) root.rebuildIcons()
    }
  }

  // Keep the list fresh while open (windows open/close/rename).
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event ? String(event.name || "") : ""
      if (name.indexOf("activewindow") === 0 || name === "openlayer")
      if (!root.opened) return

      if (name === "activewindow" || name === "closewindow" || name === "openwindow" ||
          name === "workspace" || name === "movewindow" || name.indexOf("windowtitle") === 0) {
        root.refresh(true)
      }
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "piyush-omaswitch"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore


    // A single Qt.callLater() grab races the surface being mapped: on the
    // keybinding path the window may not exist yet when it runs, leaving the
    // overlay visible but deaf (Escape, typing and the modifier release all
    // go nowhere). Re-assert focus while the panel is up until it sticks.
    onVisibleChanged: if (visible) focusGrab.restart()

    Timer {
      id: focusGrab
      interval: 25
      repeat: true
      triggeredOnStart: true
      property int attempts: 0
      onTriggered: {
        if (!root.opened) { attempts = 0; stop(); return }
        keyCatcher.forceActiveFocus()
        attempts += 1
        if (keyCatcher.activeFocus || attempts > 20) { attempts = 0; stop() }
      }
    }

    // The full-screen dim is off: darkening and un-darkening the whole desktop
    // around a switcher that may only be up for a moment reads as a flash.
    // Set showScrim to true to get it back.
    Rectangle {
      anchors.fill: parent
      color: root.scrim
      visible: root.revealed && root.showScrim
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onPositionChanged: function(mouse) {
        if (!root.mouseEnabled) return
        root.pointerOverList = false
        root.pointerX = mouse.x
        root.pointerY = mouse.y
      }
      onClicked: function(mouse) {
        if (!root.mouseEnabled || !root.clickSelects) return
        if (!root.clickSelectsWindow) return root.dismiss()
        // Panel coordinates -> compositor coordinates.
        var originX = panel.screen ? panel.screen.x : 0
        var originY = panel.screen ? panel.screen.y : 0
        root.activateWindowAt(originX + mouse.x, originY + mouse.y)
      }
    }

    BorderSurface {
      id: card
      visible: root.revealed
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec

      Row {
        anchors.fill: parent
        anchors.margins: root.contentMargin
        spacing: root.gap

        Column {
          width: root.listWidth
          height: parent.height
          spacing: root.listGap

          Text {
            visible: root.filtering
            height: root.headerHeight
            verticalAlignment: Text.AlignVCenter
            text: "Filter: " + root.filterText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            elide: Text.ElideRight
            width: parent.width
          }

          ListView {
            id: listView
            width: parent.width
            height: root.listHeight
            model: root.rows
            currentIndex: root.selectedIndex
            clip: true

            Text {
              parent: listView
              anchors.centerIn: parent
              visible: root.rows.length === 0
              text: root.filterText ? "No matching windows" : "No windows"
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: root.titleFont
            }

            delegate: Item {
              required property var modelData
              required property int index
              width: listView.width
              height: root.rowHeight

              Rectangle {
                anchors.fill: parent
                radius: root.cornerRadius
                color: index === root.selectedIndex ? root.selectedBackground : "transparent"
              }

              Image {
                id: rowIcon
                readonly property string resolved: root.iconCache[Model.appId(modelData)] || ""
                visible: resolved !== ""
                source: resolved
                width: root.iconSize
                height: root.iconSize
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                // Decode at physical pixels: a logical-size decode leaves PNG
                // icons upscaled and blurry on HiDPI displays.
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
              }

              Text {
                id: rowWorkspace
                text: Model.workspaceHint(modelData, root.currentWorkspaceId)
                visible: text !== ""
                textFormat: Text.PlainText
                color: index === root.selectedIndex ? root.selectedText : root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: root.detailFont
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                anchors.rightMargin: Style.space(12)
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: rowIcon.visible ? rowIcon.right : parent.left
                anchors.leftMargin: Style.space(10)
                width: parent.width - Style.space(20)
                  - (rowIcon.visible ? rowIcon.width + Style.space(10) : 0)
                  - (rowWorkspace.visible ? rowWorkspace.width + Style.space(10) : 0)
                spacing: 2

                Text {
                  text: Model.label(modelData)
                  textFormat: Text.PlainText
                  color: index === root.selectedIndex ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: root.titleFont
                  elide: Text.ElideRight
                  width: parent.width
                }
                Text {
                  text: Model.detail(modelData)
                  textFormat: Text.PlainText
                  color: index === root.selectedIndex ? root.selectedText : root.foreground
                  opacity: 0.6
                  font.family: root.fontFamily
                  font.pixelSize: root.detailFont
                  elide: Text.ElideRight
                  width: parent.width
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                // Hover moves the selection, so the mouse and the keyboard
                // agree on what "the selected row" means and a click is just a
                // confirmation of what is already highlighted.
                //
                // Deliberately onPositionChanged rather than onEntered: the
                // switcher often opens with the pointer already sitting over a
                // row, and onEntered would fire on open and silently steal the
                // initial selection - which is the whole point of a quick
                // Super+Tab. Only an actual mouse movement counts.
                onPositionChanged: {
                  if (!root.mouseEnabled) return
                  root.pointerOverList = true
                  if (root.hoverSelects && root.selectedIndex !== index) root.selectedIndex = index
                }
                onClicked: {
                  if (!root.mouseEnabled || !root.clickSelects) return
                  root.selectedIndex = index
                  root.focusSelected()
                }
              }
            }
          }
        }

        // Right-side peek pane. Only visible once the view actually has a
        // frame; width collapses to 0 and the list takes the whole card when
        // the compositor cannot export windows.
        BorderSurface {
          visible: root.previewActive
          width: root.previewWidth
          height: parent.height
          radius: root.cornerRadius
          color: Qt.rgba(0, 0, 0, 0.25)
          borderSpec: Border.surfaceSpec("popups", "border", root.border, Math.max(1, Style.space(1)))
          clip: true

          ScreencopyView {
            id: previewView
            anchors.centerIn: parent
            captureSource: root.previewWanted ? root.selectedToplevel.wayland : null
            live: root.previewWanted
            paintCursor: false
            constraintSize: Qt.size(root.previewConstraintWidth, root.previewConstraintHeight)
            onHasContentChanged: if (hasContent) root.previewLatched = true
          }
        }
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      z: 1
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.dismiss()
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.focusSelected()
          event.accepted = true
        } else if (event.key === Qt.Key_Backtab || event.key === Qt.Key_Up || event.key === Qt.Key_Left) {
          root.select(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Down || event.key === Qt.Key_Right) {
          root.select((event.modifiers & Qt.ShiftModifier) ? -1 : 1)
          event.accepted = true
        } else if (Util.editsFilter(event, root.filterText)) {
          root.setFilter(Util.editedFilter(event, root.filterText))
          event.accepted = true
        } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127 && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
          root.setFilter(root.filterText + event.text)
          event.accepted = true
        }
      }

      // Best-effort native Alt-Tab behavior. If the compositor delivers the
      // modifier release after granting this overlay focus, commit selection.
      Keys.onReleased: function(event) {
        if (root.cycleMode && (event.key === Qt.Key_Alt || event.key === Qt.Key_Meta)) {
          root.focusSelected()
          event.accepted = true
        }
      }
    }
  }
}
