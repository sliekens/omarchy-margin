import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire

// Margin — spike: the screen-edge gap as a spectrum ring.
//
// The ring lives in the gaps_out band: the strip of desktop between the
// bar's reserved area and the outermost tiles. Nothing else draws there, so
// it costs no screen space. It is a layer-shell surface with an empty input
// region, so it is visual only and never eats a click.
//
// Data flow:
//   bin/margin-audio  -> line-delimited JSON spectrum + beat  -> this file
//   MPRIS art URL     -> bin/margin-palette -> ring colors
Item {
  id: root

  // Injected by the shell host when the panel loads.
  property var shell: null
  property string omarchyPath: ""
  property var manifest: null

  readonly property string pluginDir: Qt.resolvedUrl(".").toString()
    .replace(/^file:\/\//, "").replace(/\/$/, "")

  // ------------------------------------------------------------------ config
  property var cfg: ({})
  readonly property bool cfgEnabled: cfg.enabled !== false
  // Contour sample points around the perimeter. Higher = smoother curve.
  readonly property int segmentCount: cfg.samples > 0 ? cfg.samples : 160
  readonly property int ringThickness: cfg.thickness > 0 ? cfg.thickness : gapsOut
  readonly property real floorRatio: cfg.floorRatio !== undefined ? cfg.floorRatio : 0.12
  // Real spectra are bass-heavy. Gamma lifts the quiet bands for COLOR only:
  // height stays linear so the ring keeps true dynamics, while brightness
  // keeps the whole perimeter alive instead of glowing only at the bottom.
  readonly property real gamma: cfg.gamma > 0 ? cfg.gamma : 1.0
  // 0 means a silent or muted desktop shows no ring at all, not even a
  // hairline. Raise it for a faint always-on ring.
  readonly property real idleOpacity: cfg.idleOpacity !== undefined ? cfg.idleOpacity : 0
  readonly property int silenceHold: cfg.silenceHold > 0 ? cfg.silenceHold : 1500
  readonly property int retractMs: cfg.retractMs > 0 ? cfg.retractMs : 800
  readonly property int expandMs: cfg.expandMs > 0 ? cfg.expandMs : 420
  readonly property bool beatShiftsPalette: cfg.beatShiftsPalette !== false
  readonly property real angleOffset: cfg.angleOffset !== undefined ? cfg.angleOffset : 90
  // false (default): ring sits against the screen edge and grows inward.
  readonly property bool anchorToWindow: cfg.anchorToWindow === true
  // Loudness alone carries the ring across the gap: at `loudFull` and above it
  // spans screen edge to window with no gap anywhere. The spectrum rides in
  // the color instead of carving the inner edge, which is what used to leave
  // a notch at every trough. `depth` > 0 brings that carving back if wanted.
  readonly property real depth: cfg.depth !== undefined ? cfg.depth : 0
  readonly property real loudFull: cfg.loudFull > 0 ? cfg.loudFull : 60
  readonly property var fallbackColors: cfg.fallbackColors && cfg.fallbackColors.length
    ? cfg.fallbackColors : ["#7aa2f7", "#bb9af7", "#7dcfff", "#9ece6a"]

  property int gapsOut: 10

  // Muting a sink does NOT silence its monitor: PipeWire taps the mix before
  // the sink's own mute/volume, so a muted desktop still produces a full
  // spectrum. The mute state has to be read explicitly.
  readonly property var outSink: Pipewire.defaultAudioSink
  readonly property bool outputMuted: outSink && outSink.audio
    ? (outSink.audio.muted || outSink.audio.volume <= 0.001) : false

  // Nothing audible: no ring, no capture.
  readonly property bool showRing: cfgEnabled && !outputMuted && !silent
  readonly property bool producerWanted: cfgEnabled && !outputMuted

  onProducerWantedChanged: reconcileProducer()

  // Span the ring should have right now, from the last published level.
  // Returns 0 rather than the floor when there is effectively no sound: the
  // floor is a minimum for *quiet* audio, not a resting state for silence.
  // Returning the floor here is what left a hairline sitting on screen until
  // the silence timer eventually fired.
  function liveFill() {
    var loud = Math.max(0, Math.min(1, renderLevel / loudFull))
    if (loud <= 0.02) return 0
    return floorRatio + (1 - floorRatio) * loud
  }

  // Per-tick smoothing for the span. Level can collapse to zero in a single
  // frame when a stream stops or an app mutes itself, and assigning that
  // straight through made the ring snap shut with no transition at all — the
  // sink-mute animation never got a chance to run. Rise is quick, release is
  // paced to land in about `retractMs`, matching the mute animation.
  readonly property real attackRate: 0.45
  readonly property real releaseRate: 1 - Math.exp(-(1000 / 30) / (retractMs / 4.6))

  onShowRingChanged: {
    fillAnim.stop()
    // With an idle ring configured, retract to the floor rather than to nothing.
    fillAnim.to = showRing ? liveFill() : (idleOpacity > 0 ? floorRatio : 0)
    fillAnim.duration = showRing ? expandMs : retractMs
    fillAnim.easing.type = showRing ? Easing.OutCubic : Easing.InOutQuint
    fillAnim.start()
  }

  function reconcileProducer() {
    if (audioProc.running === producerWanted) return
    audioProc.running = false
    if (producerWanted) audioProc.running = true
  }

  // ------------------------------------------------------------ audio state
  property var bands: []
  // Latest frame from the producer, published to `bands` on a render tick.
  // Assigning straight to `bands` would rebuild the ring contour 43x/second.
  property var pendingBands: []
  property int pendingLevel: 0
  // Snapshot of `level` taken on the render tick. Reading `level` directly
  // from the contour builder would re-trigger it at the producer's 43fps.
  property int renderLevel: 0
  property int level: 0
  property int bpm: 0
  property real beatPulse: 0
  property real paletteAngle: 0
  property real paletteTarget: 0
  property real idleBreath: 1
  // 0 = ring collapsed onto the screen edge, 1 = spanning the gap to the
  // window. Assigned per render tick while visible, and animated on the
  // show/hide transitions so muting retracts the ring rather than blinking
  // it out at full width.
  property real fillAmount: 0
  property double lastSoundMs: 0
  property bool silent: true

  // --------------------------------------------------------------- palette
  property var artColors: []
  readonly property var activeColors: artColors.length >= 2 ? artColors : fallbackColors

  readonly property var player: {
    var players = Mpris.players ? Mpris.players.values : []
    var fallback = null
    for (var i = 0; i < players.length; i++) {
      if (players[i].isPlaying) return players[i]
      if (!fallback) fallback = players[i]
    }
    return fallback
  }
  readonly property string artUrl: player ? String(player.trackArtUrl || "") : ""
  readonly property string trackTitle: player ? String(player.trackTitle || "") : ""

  onArtUrlChanged: paletteDebounce.restart()

  function refreshPalette() {
    if (!artUrl) {
      artColors = []
      return
    }
    paletteProc.command = [pluginDir + "/bin/margin-palette", artUrl]
    paletteProc.running = false
    paletteProc.running = true
  }

  function applyPalette(raw) {
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      artColors = Array.isArray(parsed.colors) ? parsed.colors : []
    } catch (e) {
      artColors = []
    }
  }

  function applyConfig(raw) {
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      cfg = (parsed && typeof parsed === "object") ? parsed : ({})
    } catch (e) {
      console.warn("margin: config.json parse failed, using defaults:", e)
      cfg = ({})
    }
  }

  function applyGaps(raw) {
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      var first = String(parsed.css || "").trim().split(/\s+/)[0]
      var n = Number(first)
      if (isFinite(n) && n > 0) gapsOut = Math.round(n)
    } catch (e) {
      // keep the default; a ring slightly off the gap is better than none
    }
  }

  // One frame of spectrum. Kept deliberately small: this runs ~43x/second.
  function onAudioFrame(line) {
    var f
    try {
      f = JSON.parse(line)
    } catch (e) {
      return
    }
    pendingBands = f.b
    pendingLevel = f.lvl
    level = f.lvl
    bpm = f.bpm
    var now = Date.now()
    if (f.lvl > 3) lastSoundMs = now
    silent = (now - lastSoundMs) > silenceHold
    if (f.beat) beat()
  }

  function beat() {
    beatPulse = 1
    beatDecay.restart()
    if (!beatShiftsPalette) return
    // Rotate the gradient one palette stop per beat: the colors sweep around
    // the ring in time with the track instead of just brightening in place.
    paletteTarget += 360 / Math.max(1, activeColors.length * 2)
    shiftAnim.to = paletteTarget
    shiftAnim.restart()
  }

  function paletteColor(u) {
    var cs = activeColors
    var n = cs.length
    if (!n) return Qt.rgba(1, 1, 1, 1)
    if (n === 1) return Qt.color(cs[0])
    var x = Math.max(0, Math.min(1, u))
    var f = x * (n - 1)
    var i0 = Math.min(n - 1, Math.floor(f))
    var i1 = Math.min(n - 1, i0 + 1)
    var t = f - Math.floor(f)
    var a = Qt.color(cs[i0])
    var b = Qt.color(cs[i1])
    return Qt.rgba(a.r + (b.r - a.r) * t,
                   a.g + (b.g - a.g) * t,
                   a.b + (b.b - a.b) * t, 1)
  }

  // Smoothly interpolated band value at ring position `u` (0 = bottom centre
  // / bass, 1 = top centre / treble). Smoothstep between bands keeps the
  // contour curved rather than faceted.
  function valueSmooth(u) {
    var b = bands
    if (!b || !b.length) return 0
    var f = Math.max(0, Math.min(1, u)) * (b.length - 1)
    var i = Math.floor(f)
    var frac = f - i
    var lo = b[Math.min(b.length - 1, i)] / 100
    var hi = b[Math.min(b.length - 1, i + 1)] / 100
    return lo + (hi - lo) * (frac * frac * (3 - 2 * frac))
  }

  // Color for a position around the conical gradient. Mapping g -> u through
  // 1-|2g-1| makes the palette symmetric about the vertical axis, which is
  // also what makes position 0 and 1 agree so the loop has no seam.
  // Min/max fill across the ring right now, as a percentage of the gap.
  // 100 means that stretch of ring is touching the window.
  function fillRange() {
    var base = fillAmount
    var lo = 2, hi = 0
    for (var i = 0; i <= 24; i++) {
      var v = Math.pow(valueSmooth(i / 24), gamma)
      var f = Math.max(0, Math.min(1, base - depth * (1 - v)))
      lo = Math.min(lo, f)
      hi = Math.max(hi, f)
    }
    return [Math.round(lo * 100), Math.round(hi * 100)]
  }

  function ringColor(g) {
    var u = 1 - Math.abs(2 * g - 1)
    var c = paletteColor(u)
    // Band energy at this point drives intensity, so the spectrum reads as
    // light travelling around a solid ring rather than as a carved edge.
    var v = Math.pow(valueSmooth(u), gamma)
    // Keep a high base: the ring is a solid band now, so dimming it toward
    // black to show the spectrum just makes the whole thing read as muddy.
    // Quiet stretches stay clearly lit, peaks saturate to the palette color.
    var lift = 0.78 + 0.42 * v
    return Qt.rgba(Math.min(1, c.r * lift), Math.min(1, c.g * lift),
                   Math.min(1, c.b * lift), 1)
  }

  // Build the ring as two closed contours, filled odd-even.
  //
  // The modulated edge is anchored at the WINDOW side of the gap and grows
  // outward toward the screen edge, so the ring always touches the tiles and
  // any slack falls on the screen-edge side. Anchoring it the other way (to
  // the screen edge, growing inward) leaves a dead strip between the ring and
  // the window that reads as a gap, which is the opposite of hugging.
  //
  // The perimeter is walked from the bottom centre so the spectrum mirrors up
  // both sides: bass at the bottom, treble meeting at the top.
  function buildContours(w, h) {
    if (w <= 0 || h <= 0) return []
    var T = ringThickness
    if (w <= 2 * T || h <= 2 * T) return []
    var per = 2 * (w + h)
    var count = Math.max(64, segmentCount)
    var base = fillAmount
    var spans = [
      { horiz: true, at: h, from: w / 2, to: w },
      { horiz: false, at: w, from: h, to: 0 },
      { horiz: true, at: 0, from: w, to: 0 },
      { horiz: false, at: 0, from: 0, to: h },
      { horiz: true, at: h, from: 0, to: w / 2 }
    ]
    var moving = []
    var walked = 0
    for (var si = 0; si < spans.length; si++) {
      var span = spans[si]
      var len = Math.abs(span.to - span.from)
      var n = Math.max(2, Math.round(count * len / per))
      for (var j = 0; j <= n; j++) {
        var f = j / n
        var c = span.from + (span.to - span.from) * f
        var p = (walked + len * f) / per
        var u = 1 - Math.abs(2 * p - 1)
        var v = Math.pow(valueSmooth(u), gamma)
        var t = T * Math.max(0, Math.min(1, base - depth * (1 - v)))
        // Distance from the screen edge: full thickness reaches it, silence
        // sits back against the window.
        var d = anchorToWindow ? T - t : t
        // Clamping into the inset rectangle handles every side with one
        // formula, and folds the corners in cleanly as the clamp saturates.
        var x = span.horiz ? c : span.at
        var y = span.horiz ? span.at : c
        moving.push(Qt.point(Math.max(d, Math.min(w - d, x)),
                             Math.max(d, Math.min(h - d, y))))
      }
      walked += len
    }
    if (moving.length) moving.push(moving[0])
    // The fixed contour is the window edge when anchored to the window, and
    // the screen edge otherwise.
    var k = anchorToWindow ? T : 0
    var fixed = [Qt.point(k, k), Qt.point(w - k, k), Qt.point(w - k, h - k),
                 Qt.point(k, h - k), Qt.point(k, k)]
    return [fixed, moving]
  }

  // ------------------------------------------------------------- processes
  Process {
    id: audioProc
    running: root.cfgEnabled
    command: [root.pluginDir + "/bin/margin-audio"]
    stdout: SplitParser {
      onRead: function(line) { root.onAudioFrame(line) }
    }
    onExited: function(exitCode, status) {
      if (exitCode !== 0) console.warn("margin: audio producer exited code=" + exitCode)
    }
  }

  // Watchdog rather than an onExited restart: Quickshell clears `running` on
  // exit, which breaks the declarative binding, and re-assigning `true` to the
  // same Process does not start it again. Toggling through false does, and a
  // periodic check also covers a producer that is alive but wedged (no frames).
  Timer {
    id: audioWatchdog
    interval: 1000
    running: true
    repeat: true
    onTriggered: {
      // `silent` is otherwise only recomputed when a frame arrives, so a dead
      // producer would leave the ring lit with whatever it last saw.
      root.silent = (Date.now() - root.lastSoundMs) > root.silenceHold
      // Reconcile the producer. Writing `running` imperatively clears the
      // declarative binding for good, so from here on this timer (plus the
      // mute handler) is the single authority on the producer's lifecycle.
      root.reconcileProducer()
    }
  }

  Process {
    id: paletteProc
    stdout: StdioCollector {
      onStreamFinished: root.applyPalette(text)
    }
  }

  Process {
    id: gapsProbe
    running: true
    command: ["hyprctl", "-j", "getoption", "general:gaps_out"]
    stdout: StdioCollector {
      onStreamFinished: root.applyGaps(text)
    }
  }

  Timer {
    id: renderTick
    interval: 33
    running: root.cfgEnabled
    repeat: true
    onTriggered: {
      if (!root.pendingBands.length) return
      root.renderLevel = root.pendingLevel
      root.bands = root.pendingBands
      // Leave the span alone while a transition animation owns it.
      if (root.showRing && !fillAnim.running) {
        var target = root.liveFill()
        var rate = target > root.fillAmount ? root.attackRate : root.releaseRate
        var next = root.fillAmount + (target - root.fillAmount) * rate
        root.fillAmount = next < 0.006 ? 0 : next
      }
    }
  }

  Timer {
    id: paletteDebounce
    interval: 250
    onTriggered: root.refreshPalette()
  }

  FileView {
    id: configFile
    path: root.pluginDir + "/config.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConfig(text())
    onLoadFailed: function(error) { root.applyConfig("") }
    onFileChanged: reload()
  }

  // ------------------------------------------------------------ animations
  NumberAnimation {
    id: fillAnim
    target: root
    property: "fillAmount"
    duration: 460
    easing.type: Easing.InOutCubic
  }

  NumberAnimation {
    id: beatDecay
    target: root
    property: "beatPulse"
    from: 1
    to: 0
    duration: 420
    easing.type: Easing.OutCubic
  }

  NumberAnimation {
    id: shiftAnim
    target: root
    property: "paletteAngle"
    duration: 380
    easing.type: Easing.OutCubic
  }

  SequentialAnimation {
    running: !root.showRing && root.cfgEnabled && root.idleOpacity > 0
    loops: Animation.Infinite
    NumberAnimation { target: root; property: "idleBreath"; to: 0.55; duration: 2600; easing.type: Easing.InOutSine }
    NumberAnimation { target: root; property: "idleBreath"; to: 1.0; duration: 2600; easing.type: Easing.InOutSine }
  }

  // Binding the node is what makes `audio` (and therefore muted/volume) valid.
  PwObjectTracker { objects: root.outSink ? [root.outSink] : [] }

  IpcHandler {
    target: "margin"

    function status(): string {
      return JSON.stringify({
        enabled: root.cfgEnabled,
        muted: root.outputMuted,
        showRing: root.showRing,
        silent: root.silent,
        level: root.level,
        bpm: root.bpm,
        bands: root.bands.length,
        thickness: root.ringThickness,
        fillPercent: root.fillRange(),
        segments: root.segmentCount,
        colors: root.activeColors,
        track: root.trackTitle,
        art: root.artUrl.substring(0, 80)
      })
    }

    function repalette(): string {
      root.refreshPalette()
      return "ok"
    }

    function ping(): string { return "ok" }
  }

  // ----------------------------------------------------------------- surface
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      screen: modelData
      visible: root.cfgEnabled
      color: "transparent"

      anchors { top: true; bottom: true; left: true; right: true }

      // Sit inside whatever the bar and other exclusive surfaces reserved, so
      // the ring lands in the actual gaps_out band rather than over the bar.
      readonly property var hyprMonitor: Hyprland.monitorFor(win.screen)
      readonly property var reserved: hyprMonitor && hyprMonitor.lastIpcObject
        && hyprMonitor.lastIpcObject.reserved
        ? hyprMonitor.lastIpcObject.reserved : [0, 0, 0, 0]

      margins {
        left: win.reserved[0]
        top: win.reserved[1]
        right: win.reserved[2]
        bottom: win.reserved[3]
      }

      WlrLayershell.namespace: "margin-ring"
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      // Visual only: an empty input region means the ring never blocks a click.
      mask: Region {}

      Item {
        id: ring
        anchors.fill: parent
        // Deliberately NOT tied to showRing: the ring stays lit all the way
        // through the retraction and disappears because its span reaches zero,
        // not because it faded. Fading in parallel hides the ease-out entirely.
        opacity: (root.idleOpacity > 0 && !root.showRing)
          ? root.idleOpacity * root.idleBreath
          : Math.min(1, (0.72 + 0.28 * Math.min(1, root.level / 60))
            * (1 + 0.35 * root.beatPulse))
        // Zero span means nothing is drawn, which also stops the contour being
        // rebuilt while muted.
        visible: root.fillAmount > 0.001
        Behavior on opacity {
          NumberAnimation { duration: 320; easing.type: Easing.InOutCubic }
        }

        // Two closed contours: the screen rect, and the spectrum-modulated
        // inner edge. Filled odd-even, that is a ribbon with no internal
        // boundaries — the whole ring is a single shape.
        readonly property var contours: visible
          ? root.buildContours(width, height) : []

        Shape {
          anchors.fill: parent
          preferredRendererType: Shape.CurveRenderer
          asynchronous: false

          ShapePath {
            fillRule: ShapePath.OddEvenFill
            strokeWidth: 0
            strokeColor: "transparent"

            // Color rides a conical gradient rather than per-segment fills, so
            // it varies continuously around the ring. Beats rotate the whole
            // gradient, which reads as the colors sweeping around the edge.
            fillGradient: ConicalGradient {
              centerX: ring.width / 2
              centerY: ring.height / 2
              // 90 puts gradient position 0 at the bottom centre, where the
              // bass sits, so the palette starts where the ring is busiest.
              angle: root.paletteAngle + root.angleOffset
              // Mirrored stops: position 0 and 1 land on the same color, so
              // the gradient closes seamlessly instead of showing a hard seam.
              GradientStop { position: 0.000; color: root.ringColor(0.000) }
              GradientStop { position: 0.125; color: root.ringColor(0.125) }
              GradientStop { position: 0.250; color: root.ringColor(0.250) }
              GradientStop { position: 0.375; color: root.ringColor(0.375) }
              GradientStop { position: 0.500; color: root.ringColor(0.500) }
              GradientStop { position: 0.625; color: root.ringColor(0.625) }
              GradientStop { position: 0.750; color: root.ringColor(0.750) }
              GradientStop { position: 0.875; color: root.ringColor(0.875) }
              GradientStop { position: 1.000; color: root.ringColor(1.000) }
            }

            PathMultiline { paths: ring.contours }
          }
        }
      }
    }
  }

  Component.onCompleted: console.log("margin: ring loaded, pluginDir=" + root.pluginDir)
}
