import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

BarWidget {
  id: root

  readonly property string pluginRoot: decodeURIComponent(String(Qt.resolvedUrl(".")))
    .replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string systemScript: root.pluginRoot + "/scripts/system-usage"

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(root.fg, 1.4)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  property string cpuText: "--"
  property string cpuName: "CPU"
  property string cpuTempText: ""
  property string gpuTempText: ""
  property string ramTempText: ""
  property var fans: []
  property var cores: []
  property string ramUsed: "--"
  property string ramTotal: "--"
  property int ramPct: 0
  property string ramInfo: ""
  property string gpuText: "n/a"
  property string gpuName: "GPU"
  property string gpuKind: "render"
  property string gpuHint: ""
  property var gpus: []
  property bool ramActive: false
  property bool diskActive: false
  property var disks: []
  property bool popupOpen: false

  // shell.json: {
  //   "id": "im0001gt.hw-tooltip",
  //   "ignoreFans": ["it8613/fan3"],
  //   "fanNames": { "it8613/fan2": "CPU" }
  // }
  // ignoreFans: array or space/comma separated <hwmon name>/fan<N> globs.
  // fanNames: map of those keys to a label. shell.json arrays/maps arrive as
  // QVariantList / QVariantMap: check length/keys, not Array.isArray.
  readonly property var ignoreFanList: root.stringListSetting("ignoreFans")
  readonly property var fanNameMap: root.stringMapSetting("fanNames")

  property bool fanPickerOpen: false
  property string editingFanKey: ""
  property bool fanRenameCancel: false

  readonly property int cpuPct: parseInt(cpuText, 10) || 0
  readonly property int gpuPct: gpuText === "n/a" ? -1 : (parseInt(gpuText, 10) || 0)
  readonly property int coreCount: cores.length
  readonly property int coreColumns: {
    var n = coreCount
    if (n <= 1) return 1
    if (n <= 16) return 2
    return 4
  }
  readonly property int panelWidth: Style.space(coreColumns >= 4 ? 540 : 380)
  readonly property int coreLabelWidth: Style.space(coreCount >= 100 ? 32 : (coreCount >= 10 ? 26 : 20))
  readonly property int coreValueWidth: Style.space(34)
  readonly property real coresBudget: {
    var avail = popup.availableCardHeight
    var inset = popup.verticalContentInset
    var gap = Style.space(14)
    var reserved = (heroBlock.implicitHeight || 0) + (tail.implicitHeight || 0) + gap * 2 + inset
    var budget = (avail > 0 ? avail : Style.space(720)) - reserved
    return Math.max(Style.space(72), budget)
  }

  // Status lines rotate with a fade, like the Power panel.
  readonly property var idlePhrases: [
    "Sipping cycles",
    "Idling cores",
    "Loafing threads",
    "Napping ALUs",
    "Counting sheep"
  ]
  readonly property var steadyPhrases: [
    "Watching watts",
    "Herding threads",
    "Keeping score",
    "Poking silicon",
    "Weighing bytes",
    "Sampling chaos"
  ]
  readonly property var busyPhrases: [
    "Crunching numbers",
    "Melting silicon",
    "All cores in",
    "Thrashing caches",
    "Cooking the die"
  ]
  readonly property var gpuPhrases: [
    "Drawing frames",
    "Pushing pixels",
    "Painting buffers",
    "Shading triangles",
    "Filling scanlines"
  ]
  readonly property var inferPhrases: [
    "Crunching tensors",
    "Feeding the model",
    "Spinning weights",
    "Unrolling attention",
    "Chewing context"
  ]
  readonly property var ramPhrases: [
    "Hoarding pages",
    "Stuffing DIMMs",
    "Packing bytes",
    "Cramming caches",
    "Sitting on RAM"
  ]
  readonly property var storagePhrases: [
    "Cramming sectors",
    "Hoarding blocks",
    "Packing the drive",
    "Eating free space",
    "Crowding the disk"
  ]

  // Load bands, with hysteresis. The pool used to be derived straight from the
  // raw percentages, so a CPU parked on a threshold flipped it on every 2s
  // sample. Entry and exit sit apart, so a steady load holds one band.
  property bool bandIdle: true
  property bool bandCpuBusy: false
  property bool bandGpuBusy: false

  function updateBands() {
    var quiet = cpuPct <= 15 && gpuPct <= 15
    if (bandIdle) { if (cpuPct > 25 || gpuPct > 25) bandIdle = false }
    else if (quiet) bandIdle = true

    if (bandCpuBusy) { if (cpuPct < 40) bandCpuBusy = false }
    else if (cpuPct >= 50) bandCpuBusy = true

    if (bandGpuBusy) { if (gpuPct < 40) bandGpuBusy = false }
    else if (gpuPct >= 50) bandGpuBusy = true
  }

  readonly property var activePhrases: {
    var pool = []
    function add(list) {
      for (var i = 0; i < list.length; i++) pool.push(list[i])
    }
    // Ambient lines always stay in the mix so one device cannot own the rotation.
    if (bandIdle) add(idlePhrases)
    else add(steadyPhrases)
    if (bandCpuBusy) add(busyPhrases)
    if (bandGpuBusy && gpuKind === "infer") add(inferPhrases)
    else if (bandGpuBusy) add(gpuPhrases)
    // ram_active and disk_io are single-sample deltas that flicker on and off
    // between polls. The hold timers keep a burst in the pool for a few samples
    // instead of adding and dropping five phrases every 2s.
    if (ramHold.running) add(ramPhrases)
    if (diskHold.running) add(storagePhrases)
    return pool
  }

  // The visible phrase is stored, never derived. A metric sample can change
  // which phrases are eligible next; it can no longer rewrite the line that is
  // already on screen, so every change goes through the fade exactly once.
  property string heroStatusText: ""
  property var phraseDeck: []
  property string phrasePoolKey: ""

  function shuffled(list) {
    var out = list.slice()
    for (var i = out.length - 1; i > 0; i--) {
      var j = Math.floor(Math.random() * (i + 1))
      var swap = out[i]
      out[i] = out[j]
      out[j] = swap
    }
    return out
  }

  // Draw from a shuffled deck rather than stepping an index modulo the pool
  // length: the pool changes size while the panel is open, and a modular index
  // silently jumps or repeats whenever it does. A deck empties before it
  // refills, so nothing repeats inside a pass.
  function refillDeck() {
    var pool = root.activePhrases
    root.phrasePoolKey = pool.join("|")
    var deck = root.shuffled(pool)
    if (deck.length > 1 && deck[0] === root.heroStatusText) deck.push(deck.shift())
    root.phraseDeck = deck
  }

  function drawPhrase() {
    if (root.phraseDeck.length === 0) root.refillDeck()
    if (root.phraseDeck.length === 0) return root.heroStatusText
    var deck = root.phraseDeck.slice()
    var next = deck.shift()
    root.phraseDeck = deck
    return next
  }

  // Drop the deck when the pool really changed, so stale phrases (a busy line
  // on a now-idle CPU) cannot still be drawn. Identity alone is not enough:
  // the binding re-evaluates on every sample and hands back a fresh array.
  onActivePhrasesChanged: {
    if (root.activePhrases.join("|") !== root.phrasePoolKey) root.phraseDeck = []
  }

  Component.onCompleted: root.heroStatusText = root.drawPhrase()

  function restOf(line, key) {
    return String(line).slice(key.length).trim()
  }

  function joinBits(bits) {
    var out = []
    for (var i = 0; i < bits.length; i++) {
      if (bits[i]) out.push(bits[i])
    }
    return out.join(" · ")
  }

  function cpuModel() {
    return (root.cpuName && root.cpuName !== "CPU") ? root.cpuName : ""
  }

  function cpuReadings() {
    return root.cpuTempText
  }

  function stringListSetting(name) {
    var v = root.setting(name, [])
    var out = []
    if (typeof v === "string") {
      var parts = v.split(/[\s,]+/)
      for (var i = 0; i < parts.length; i++) {
        if (parts[i]) out.push(parts[i])
      }
      return out
    }
    if (!v || typeof v.length !== "number") return out
    for (var j = 0; j < v.length; j++) out.push(String(v[j]))
    return out
  }

  function stringMapSetting(name) {
    var v = root.setting(name, {})
    var out = {}
    if (!v || typeof v !== "object" || typeof v.length === "number") return out
    for (var k in v) {
      if (!k || k === "id") continue
      out[String(k)] = String(v[k])
    }
    return out
  }

  function globMatch(text, pattern) {
    var t = String(text || "").toLowerCase()
    var p = String(pattern || "").toLowerCase()
    var re = "^"
    for (var i = 0; i < p.length; i++) {
      var c = p.charAt(i)
      if (c === "*") {
        re += ".*"
      } else if (c === "?") {
        re += "."
      } else if (c === "[") {
        var j = p.indexOf("]", i + 1)
        if (j < 0) {
          re += "\\["
        } else {
          re += p.slice(i, j + 1)
          i = j
        }
      } else if ("\\.^$+(){}|".indexOf(c) >= 0) {
        re += "\\" + c
      } else {
        re += c
      }
    }
    re += "$"
    try {
      return new RegExp(re).test(t)
    } catch (e) {
      return t === p
    }
  }

  function fanIgnored(key) {
    var k = String(key || "").toLowerCase()
    var list = root.ignoreFanList
    for (var i = 0; i < list.length; i++) {
      if (root.globMatch(k, list[i])) return true
    }
    return false
  }

  function sanitizeFanName(name) {
    var s = String(name || "").replace(/[\x00-\x1f\x7f]/g, " ").replace(/\s+/g, " ").trim()
    if (s.length > 32) s = s.slice(0, 32).trim()
    return s
  }

  function fanDisplayName(fan) {
    if (!fan) return "Fan"
    var custom = root.fanNameMap[fan.key]
    if (custom) return custom
    if (fan.label) return fan.label
    var key = String(fan.key || "")
    var parts = key.split("/")
    return parts.length ? parts[parts.length - 1] : "Fan"
  }

  readonly property var visibleFans: {
    var ignored = root.ignoreFanList
    var out = []
    for (var i = 0; i < root.fans.length; i++) {
      if (!root.fanIgnored(root.fans[i].key)) out.push(root.fans[i])
    }
    return out
  }

  readonly property int fanColumns: {
    if (root.fanPickerOpen) return 1
    var n = root.visibleFans.length
    if (n <= 5) return 1
    return 2
  }
  readonly property int sectionIconWidth: Style.font.title

  function persistSettings(values) {
    var id = root.moduleName || "im0001gt.hw-tooltip"
    var entry = { id: id }
    var src = root.settings || {}
    for (var existing in src) {
      if (existing !== "id") entry[existing] = src[existing]
    }
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(id, entry)
  }

  function toggleFanHidden(key) {
    var k = String(key || "").toLowerCase()
    if (!k) return
    var next = []
    if (root.fanIgnored(k)) {
      var list = root.ignoreFanList
      for (var i = 0; i < list.length; i++) {
        if (!root.globMatch(k, list[i])) next.push(list[i])
      }
    } else {
      next = root.ignoreFanList.slice()
      var found = false
      for (var j = 0; j < next.length; j++) {
        if (String(next[j]).toLowerCase() === k) found = true
      }
      if (!found) next.push(k)
    }
    root.persistSettings({ ignoreFans: next })
  }

  function setFanName(key, name) {
    var k = String(key || "")
    if (!k) return
    var names = {}
    var src = root.fanNameMap
    var clean = root.sanitizeFanName(name)
    for (var existing in src) {
      if (clean === "" && existing === k) continue
      names[existing] = src[existing]
    }
    if (clean !== "") names[k] = clean
    root.persistSettings({ fanNames: names })
  }

  function beginFanRename(key) {
    root.fanRenameCancel = false
    root.editingFanKey = String(key || "")
  }

  function cancelFanRename() {
    root.fanRenameCancel = true
    root.editingFanKey = ""
  }

  function commitFanRename(key, name) {
    if (root.fanRenameCancel) {
      root.fanRenameCancel = false
      return
    }
    if (root.editingFanKey === key) root.editingFanKey = ""
    root.setFanName(key, name)
  }

  function ramStatus() {
    var info = root.ramInfo !== "" ? root.ramInfo : ""
    return root.joinBits([info, root.ramUsed + " / " + root.ramTotal + " GiB"])
  }

  function gpuStatus() {
    if (root.gpuText === "n/a" && root.gpuTempText === "")
      return root.gpuHint === "nvidia-utils" ? "Install nvidia-utils for GPU stats" : "GPU stats unavailable"
    return (root.gpuName && root.gpuName !== "GPU") ? root.gpuName : ""
  }

  function gpuReadings() {
    if (root.gpuText === "n/a" && root.gpuTempText === "") return ""
    return root.gpuTempText
  }

  function diskFacts(disk) {
    var mount = disk.name ? disk.mount : ""
    return root.joinBits([mount, disk.used + " / " + disk.total + " GiB"])
  }

  function parse(raw) {
    var lines = String(raw || "").split("\n")
    var cores = []
    var disks = []
    var diskTemps = {}
    var gpuDevs = {}
    var gpuOrder = []
    var cpu = "--"
    var cpuName = root.cpuName
    var cpuTemp = ""
    var gpuTemp = ""
    var ramTemp = ""
    var fans = []
    var ramUsed = "--"
    var ramTotal = "--"
    var ramPct = 0
    var ramInfo = root.ramInfo
    var gpu = "n/a"
    var gpuName = root.gpuName
    var gpuKind = root.gpuKind
    var gpuHint = ""
    var ramActive = root.ramActive
    var diskActive = root.diskActive

    for (var i = 0; i < lines.length; i++) {
      var line = String(lines[i]).trim()
      if (line === "") continue
      var parts = line.split(/\s+/)
      var key = parts[0]

      if (key === "cpu" && parts.length > 1) {
        cpu = parts[1] + "%"
      } else if (key === "cpu_name") {
        var n = root.restOf(line, key)
        if (n) cpuName = n
      } else if (key === "core" && parts.length > 2) {
        var pct = parseFloat(parts[2])
        if (isFinite(pct)) cores.push({ core: parseInt(parts[1], 10), percent: Math.max(0, Math.min(100, Math.round(pct))) })
      } else if (key === "ram" && parts.length > 3) {
        ramUsed = parts[1]
        ramTotal = parts[2]
        ramPct = Math.max(0, Math.min(100, Math.round(parseFloat(parts[3]) || 0)))
      } else if (key === "ram_info") {
        ramInfo = root.restOf(line, key)
      } else if (key === "gpu" && parts.length > 1) {
        gpu = parts[1] === "n/a" ? "n/a" : Math.max(0, Math.min(100, Math.round(parseFloat(parts[1]) || 0))) + "%"
      } else if (key === "gpu_name") {
        var gn = root.restOf(line, key)
        if (gn) gpuName = gn
      } else if (key === "gpu_kind" && parts.length > 1) {
        gpuKind = parts[1]
      } else if (key === "gpu_hint" && parts.length > 1) {
        gpuHint = parts[1]
      } else if (key === "gpu_dev" && parts.length > 2) {
        var id = parts[1]
        if (!gpuDevs[id]) { gpuDevs[id] = { pci: id, name: "", text: "n/a", percent: -1, temp: "" }; gpuOrder.push(id) }
        gpuDevs[id].text = parts[2] === "n/a" ? "n/a" : Math.max(0, Math.min(100, Math.round(parseFloat(parts[2]) || 0))) + "%"
        gpuDevs[id].percent = parts[2] === "n/a" ? -1 : Math.max(0, Math.min(100, Math.round(parseFloat(parts[2]) || 0)))
      } else if (key === "gpu_dev_name" && parts.length > 2) {
        if (!gpuDevs[parts[1]]) { gpuDevs[parts[1]] = { pci: parts[1], name: "", text: "n/a", percent: -1, temp: "" }; gpuOrder.push(parts[1]) }
        gpuDevs[parts[1]].name = parts.slice(2).join(" ")
      } else if (key === "gpu_dev_temp" && parts.length > 2) {
        if (!gpuDevs[parts[1]]) { gpuDevs[parts[1]] = { pci: parts[1], name: "", text: "n/a", percent: -1, temp: "" }; gpuOrder.push(parts[1]) }
        gpuDevs[parts[1]].temp = parts[2] === "n/a" ? "" : parts[2] + "°C"
      } else if (key === "cpu_temp" && parts.length > 1) {
        cpuTemp = parts[1] === "n/a" ? "" : parts[1] + "°C"
      } else if (key === "gpu_temp" && parts.length > 1) {
        gpuTemp = parts[1] === "n/a" ? "" : parts[1] + "°C"
      } else if (key === "fan" && parts.length > 2) {
        fans.push({ key: parts[1], rpm: parseInt(parts[2], 10) || 0, label: parts.slice(3).join(" ") })
      } else if (key === "ram_temp" && parts.length > 1) {
        ramTemp = parts[1] === "n/a" ? "" : parts[1] + "°C"
      } else if (key === "disk_temp" && parts.length > 2) {
        diskTemps[parts[1]] = parts[2] === "n/a" ? "" : parts[2] + "°C"
      } else if (key === "ram_active" && parts.length > 1) {
        ramActive = parts[1] === "1"
      } else if (key === "disk_io" && parts.length > 1) {
        diskActive = parts[1] === "1"
      } else if (key === "disk" && parts.length > 4) {
        var diskPct = Math.max(0, Math.min(100, Math.round(parseFloat(parts[4]) || 0)))
        var model = parts.length > 5 ? parts.slice(5).join(" ") : ""
        disks.push({ mount: parts[1], used: parts[2], total: parts[3], percent: diskPct, name: model, temp: "" })
      }
    }

    for (var d = 0; d < disks.length; d++) {
      disks[d] = {
        mount: disks[d].mount,
        used: disks[d].used,
        total: disks[d].total,
        percent: disks[d].percent,
        name: disks[d].name,
        temp: diskTemps[disks[d].mount] || ""
      }
    }

    root.cpuText = cpu
    root.cpuName = cpuName
    root.cpuTempText = cpuTemp
    root.gpuTempText = gpuTemp
    root.ramTempText = ramTemp
    root.fans = fans
    root.cores = cores
    root.ramUsed = ramUsed
    root.ramTotal = ramTotal
    root.ramPct = ramPct
    root.ramInfo = ramInfo
    var gpus = []
    for (var g = 0; g < gpuOrder.length; g++) gpus.push(gpuDevs[gpuOrder[g]])
    if (gpus.length === 0 && (gpu !== "n/a" || gpuTemp !== "" || (gpuName && gpuName !== "GPU"))) {
      gpus.push({
        pci: "gpu",
        name: gpuName,
        text: gpu,
        percent: gpu === "n/a" ? -1 : (parseInt(gpu, 10) || 0),
        temp: gpuTemp
      })
    }

    root.gpuText = gpu
    root.gpuName = gpuName
    root.gpuKind = gpuKind
    root.gpuHint = gpuHint
    root.gpus = gpus
    root.ramActive = ramActive
    root.diskActive = diskActive
    root.disks = disks

    if (ramActive) ramHold.restart()
    if (diskActive) diskHold.restart()
    root.updateBands()
  }

  function launch() {
    if (root.bar) root.bar.run("omarchy-launch-or-focus-tui btop")
  }

  // brittiaa.widgets calls owner.open() when it lifts this panel onto a
  // wallpaper card. Without it, the host falls back to setting PopupCard.open
  // directly, which never flips popupOpen — so the sample timer stays off and
  // the card keeps the "--" placeholders forever.
  function open() {
    root.popupOpen = true
  }

  function close() {
    root.popupOpen = false
    root.fanPickerOpen = false
    root.editingFanKey = ""
  }

  // True once the wallpaper host has reparented the panel content out of the
  // PopupCard. Sampling must keep running in that case even if focus-grab
  // dismissal clears popupOpen afterwards.
  readonly property bool desktopEmbedded: {
    if (!panel || !popup) return false
    var p = panel.parent
    while (p) {
      if (p === popup) return false
      p = p.parent
    }
    return panel.parent !== null
  }

  onPopupOpenChanged: {
    if (!root.popupOpen) {
      root.fanPickerOpen = false
      root.editingFanKey = ""
    }
  }

  ShellIpc {
    target: "im0001gt.hw-tooltip"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.popupOpen = !root.popupOpen }
    function toggleFans(): void {
      root.editingFanKey = ""
      root.fanPickerOpen = !root.fanPickerOpen
      if (!root.popupOpen) root.popupOpen = true
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍛"
    // Plain centered glyph. The bar's default optical correction shifts this icon right.
    iconComponent: Component {
      Text {
        text: "󰍛"
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        root.launch()
        root.close()
      } else {
        root.popupOpen = !root.popupOpen
      }
    }
  }

  Timer { id: ramHold; interval: 12000; repeat: false }
  Timer { id: diskHold; interval: 12000; repeat: false }

  // Rotation runs off this rather than off `popup.open` directly. The pointer
  // crosses a gap between the chip and the card, so `popup.open` dips false for
  // a frame in normal use; following it verbatim reset the interval and aborted
  // the fade mid-swap, which read as a skipped or hurried phrase.
  property bool rotationActive: false

  function startRotation() {
    rotationStop.stop()
    if (root.rotationActive) return
    root.phraseDeck = []
    root.phrasePoolKey = ""
    root.heroStatusText = root.drawPhrase()
    heroStatus.opacity = 1.0
    root.rotationActive = true
  }

  function stopRotation() {
    root.rotationActive = false
    phraseSwap.stop()
    heroStatus.opacity = 1.0
  }

  Timer {
    id: rotationStop
    interval: 250
    repeat: false
    onTriggered: root.stopRotation()
  }

  Timer {
    id: phraseTimer
    interval: 2800
    running: root.rotationActive
    repeat: true
    triggeredOnStart: false
    // Never restart a swap that is still playing. The fade owns the phrase
    // between its two halves, and restarting there dropped the commit.
    onTriggered: if (!phraseSwap.running) phraseSwap.start()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: heroStatus
      property: "opacity"
      to: 0.0
      duration: 180
      easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: root.heroStatusText = root.drawPhrase()
    }
    PropertyAnimation {
      target: heroStatus
      property: "opacity"
      to: 1.0
      duration: 260
      easing.type: Easing.InQuad
    }
  }

  Connections {
    target: popup
    function onOpenChanged() {
      if (popup.open || root.desktopEmbedded) root.startRotation()
      else rotationStop.restart()
    }
  }

  onDesktopEmbeddedChanged: {
    if (root.desktopEmbedded) root.startRotation()
    else if (!popup.open) rotationStop.restart()
  }

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    triggerMode: "click"
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(root.panelWidth)
    contentHeight: popup.fittedContentHeight(panel.implicitHeight)

    Column {
      id: panel
      width: parent.width
      spacing: Style.space(14)

      Item {
        id: heroBlock
        width: parent.width
        implicitHeight: Math.max(heroIcon.implicitHeight, heroCol.implicitHeight)

        Text {
          id: heroIcon
          text: "󰍛"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }

        Column {
          id: heroCol
          anchors.left: heroIcon.right
          anchors.leftMargin: Style.space(14)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Item {
            id: heroTitleRow
            width: parent.width
            implicitHeight: cpuTitleMetrics.height

            TextMetrics {
              id: cpuTitleMetrics
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              text: "CPU"
            }

            TextMetrics {
              id: heroPercentMetrics
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              text: root.cpuText
            }

            TextMetrics {
              id: heroReadingsMetrics
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              text: root.cpuReadings()
            }

            Text {
              id: cpuTitle
              textFormat: Text.PlainText
              text: "CPU"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              wrapMode: Text.NoWrap
              elide: Text.ElideRight
              anchors.left: parent.left
              anchors.right: heroReadings.visible ? heroReadings.left : heroPercent.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: heroReadings
              textFormat: Text.PlainText
              visible: root.cpuReadings() !== ""
              text: root.cpuReadings()
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              wrapMode: Text.NoWrap
              elide: Text.ElideLeft
              horizontalAlignment: Text.AlignRight
              anchors.right: heroPercent.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              width: {
                if (root.cpuReadings() === "") return 0
                var room = Math.max(0, parent.width - cpuTitleMetrics.width - heroPercentMetrics.width - Style.space(20))
                return Math.min(heroReadingsMetrics.width, room)
              }
            }

            Text {
              id: heroPercent
              textFormat: Text.PlainText
              text: root.cpuText
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.cpuModel() !== ""
            text: root.cpuModel()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            id: heroStatus
            textFormat: Text.PlainText
            text: root.heroStatusText.toUpperCase()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: Style.font.caption * 0.12
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            width: parent.width
          }
        }
      }

      Flickable {
        id: coresFlick
        visible: root.coreCount > 0
        width: parent.width
        height: root.coreCount > 0 ? Math.min(coresGrid.implicitHeight, root.coresBudget) : 0
        implicitHeight: height
        contentWidth: width
        contentHeight: coresGrid.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height + 1

        Grid {
          id: coresGrid
          width: coresFlick.width
          columns: root.coreColumns
          columnSpacing: Style.spacing.md
          rowSpacing: Style.spacing.sm

          Repeater {
            model: root.cores

            Row {
              required property var modelData

              width: {
                var cols = Math.max(1, coresGrid.columns)
                return (coresGrid.width - coresGrid.columnSpacing * (cols - 1)) / cols
              }
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: "C" + modelData.core
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                width: root.coreLabelWidth
                anchors.verticalCenter: parent.verticalCenter
              }

              Meter {
                width: Math.max(Style.space(16), parent.width - root.coreLabelWidth - root.coreValueWidth - Style.space(12))
                implicitHeight: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                percent: modelData.percent
              }

              Text {
                textFormat: Text.PlainText
                text: modelData.percent + "%"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                width: root.coreValueWidth
                horizontalAlignment: Text.AlignRight
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }
        }
      }

      Column {
        id: tail
        width: parent.width
        spacing: Style.space(14)

        PanelSeparator {
          foreground: root.fg
        }

        Column {
          id: fansBlock
          visible: root.fans.length > 0
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: fansTitleMetrics.height

            TextMetrics {
              id: fansTitleMetrics
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              text: "Fans"
            }

            OpticalGlyph {
              id: fansIcon
              text: "󰈐"
              color: root.fanPickerOpen ? Color.accent : root.fg
              fontFamily: root.fontFamily
              fontSize: Style.font.title
              paintedSize: Style.font.title
              width: root.sectionIconWidth
              height: root.sectionIconWidth
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter

              MouseArea {
                anchors.fill: parent
                anchors.margins: -4
                cursorShape: Qt.PointingHandCursor
                hoverEnabled: true
                onClicked: {
                  root.editingFanKey = ""
                  root.fanPickerOpen = !root.fanPickerOpen
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: "Fans"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              wrapMode: Text.NoWrap
              elide: Text.ElideRight
              anchors.left: fansIcon.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.fanPickerOpen
            width: parent.width
            text: "Click a name to rename. Toggle to show or hide."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }

          Text {
            textFormat: Text.PlainText
            visible: !root.fanPickerOpen && root.visibleFans.length === 0
            width: parent.width
            text: "All hidden — click the fan icon to show them"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }

          Column {
            visible: root.fanPickerOpen
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: root.fanPickerOpen ? root.fans : []

              FanToggleRow {
                required property var modelData
                fan: modelData
              }
            }
          }

          Grid {
            id: fansGrid
            visible: !root.fanPickerOpen && root.visibleFans.length > 0
            width: parent.width
            columns: root.fanColumns
            columnSpacing: Style.spacing.md
            rowSpacing: Style.spacing.sm

            Repeater {
              model: fansGrid.visible ? root.visibleFans : []

              FanRow {
                required property var modelData
                fan: modelData
                width: {
                  var cols = Math.max(1, fansGrid.columns)
                  return (fansGrid.width - fansGrid.columnSpacing * (cols - 1)) / cols
                }
              }
            }
          }
        }

        PanelSeparator {
          visible: fansBlock.visible
          foreground: root.fg
        }

        SectionBlock {
          icon: "󰓅"
          title: "Memory"
          value: root.ramPct + "%"
          status: root.ramStatus()
          readings: root.ramTempText
          percent: root.ramPct
        }

        PanelSeparator {
          foreground: root.fg
        }

        SectionBlock {
          icon: "󰢮"
          title: "GPU"
          value: root.gpus.length <= 1 ? root.gpuText : ""
          status: root.gpus.length <= 1 ? root.gpuStatus() : ""
          readings: root.gpus.length <= 1 ? root.gpuReadings() : ""
          percent: root.gpus.length <= 1 ? (root.gpuText === "n/a" ? -1 : root.gpuPct) : -1
        }

        Column {
          visible: root.gpus.length > 1
          width: parent.width
          spacing: Style.space(14)

          Repeater {
            model: root.gpus.length > 1 ? root.gpus : []

            StatRow {
              required property var modelData

              label: modelData.name ? modelData.name : "GPU"
              value: modelData.text
              percent: modelData.percent
              readings: modelData.temp || ""
            }
          }
        }

        PanelSeparator {
          foreground: root.fg
        }

        SectionBlock {
          icon: "󰋊"
          title: "Storage"
          value: root.disks.length === 1 ? root.disks[0].percent + "%" : ""
          status: root.disks.length === 1 ? root.diskFacts(root.disks[0]) : ""
          readings: root.disks.length === 1 ? (root.disks[0].temp || "") : ""
          percent: root.disks.length === 1 ? root.disks[0].percent : -1
        }

        Column {
          visible: root.disks.length > 1
          width: parent.width
          spacing: Style.space(14)

          Repeater {
            model: root.disks.length > 1 ? root.disks : []

            StatRow {
              required property var modelData

              label: modelData.name ? modelData.name : modelData.mount
              value: modelData.percent + "%"
              percent: modelData.percent
              readings: modelData.temp || ""
              caption: root.diskFacts(modelData)
            }
          }
        }
      }
    }
  }

  component SectionBlock: Column {
    id: section

    property string icon: ""
    property string title: ""
    property string value: ""
    property string status: ""
    property string readings: ""
    property int percent: -1

    width: parent.width
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: secTitleMetrics.height

      TextMetrics {
        id: secTitleMetrics
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        text: section.title
      }

      TextMetrics {
        id: secValueMetrics
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        text: section.value
      }

      TextMetrics {
        id: secReadingsMetrics
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        text: section.readings
      }

      OpticalGlyph {
        id: secIcon
        visible: section.icon !== ""
        text: section.icon
        color: root.fg
        fontFamily: root.fontFamily
        fontSize: Style.font.title
        paintedSize: Style.font.title
        width: root.sectionIconWidth
        height: root.sectionIconWidth
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: secTitle
        textFormat: Text.PlainText
        text: section.title
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        anchors.left: secIcon.right
        anchors.leftMargin: Style.space(8)
        anchors.right: secReadings.visible ? secReadings.left : (secValue.visible ? secValue.left : parent.right)
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: secReadings
        textFormat: Text.PlainText
        visible: section.readings !== ""
        text: section.readings
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        wrapMode: Text.NoWrap
        elide: Text.ElideLeft
        horizontalAlignment: Text.AlignRight
        anchors.right: secValue.visible ? secValue.left : parent.right
        anchors.rightMargin: secValue.visible ? Style.space(10) : 0
        anchors.verticalCenter: parent.verticalCenter
        width: {
          if (section.readings === "") return 0
          var reserve = (secIcon.visible ? secIcon.implicitWidth + Style.space(8) : 0) + secTitleMetrics.width + Style.space(8)
          if (secValue.visible) reserve += secValueMetrics.width + Style.space(10)
          var room = Math.max(0, parent.width - reserve)
          return Math.min(secReadingsMetrics.width, room)
        }
      }

      Text {
        id: secValue
        textFormat: Text.PlainText
        visible: section.value !== ""
        text: section.value
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      visible: section.percent >= 0
      width: parent.width
      implicitHeight: Style.space(6)
      percent: Math.max(0, section.percent)
    }

    Text {
      textFormat: Text.PlainText
      visible: section.status !== ""
      width: parent.width
      text: section.status
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.NoWrap
      elide: Text.ElideRight
    }
  }

  component Meter: Item {
    property int percent: 0

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: Util.alpha(root.fg, 0.12)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      height: parent.height
      radius: height / 2
      color: Util.alpha(Color.accent, 0.9)
      width: Math.max(parent.height, parent.width * Math.max(0, Math.min(100, percent)) / 100)

      Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
    }
  }

  component StatRow: Item {
    id: statRow

    required property string label
    required property string value
    required property int percent
    property string readings: ""
    property string caption: ""

    width: parent.width

    readonly property real headerHeight: headerRow.height
    readonly property real barHeight: Style.space(6)
    readonly property real gap: Style.space(6)
    readonly property real barBlock: percent >= 0 ? gap + barHeight : 0

    implicitHeight: headerHeight
      + barBlock
      + (captionText.visible ? gap + captionText.implicitHeight : 0)

    Item {
      id: headerRow
      width: parent.width
      height: statLabelMetrics.height

      TextMetrics {
        id: statLabelMetrics
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        text: statRow.label
      }

      TextMetrics {
        id: statValueMetrics
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        text: statRow.value
      }

      TextMetrics {
        id: statReadingsMetrics
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        text: statRow.readings
      }

      Text {
        id: statLabel
        textFormat: Text.PlainText
        text: statRow.label
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: statReadings.visible ? statReadings.left : statValue.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: statReadings
        textFormat: Text.PlainText
        visible: statRow.readings !== ""
        text: statRow.readings
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        wrapMode: Text.NoWrap
        elide: Text.ElideLeft
        horizontalAlignment: Text.AlignRight
        anchors.right: statValue.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        width: {
          if (statRow.readings === "") return 0
          var room = Math.max(0, parent.width - statValueMetrics.width - Style.space(10) - Style.space(48))
          return Math.min(statReadingsMetrics.width, room)
        }
      }

      Text {
        id: statValue
        textFormat: Text.PlainText
        text: statRow.value
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      visible: statRow.percent >= 0
      y: statRow.headerHeight + statRow.gap
      width: parent.width
      implicitHeight: statRow.barHeight
      percent: statRow.percent
    }

    Text {
      id: captionText
      textFormat: Text.PlainText
      visible: statRow.caption !== ""
      y: statRow.headerHeight + statRow.barBlock + statRow.gap
      width: parent.width
      text: statRow.caption
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.NoWrap
      elide: Text.ElideRight
    }
  }

  component FanRow: Item {
    id: fanRow

    property var fan: null

    readonly property bool editing: fan && root.editingFanKey === fan.key
    readonly property string rpmText: fan ? (fan.rpm + " RPM") : ""

    implicitHeight: Math.max(
      fanNameMetrics.height,
      fanRpmMetrics.height,
      fanEdit.visible ? fanEdit.implicitHeight : 0
    )

    TextMetrics {
      id: fanNameMetrics
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      text: (root.fanNameMap && fanRow.fan) ? root.fanDisplayName(fanRow.fan) : ""
    }

    TextMetrics {
      id: fanRpmMetrics
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      text: fanRow.rpmText
    }

    Text {
      id: fanName
      textFormat: Text.PlainText
      visible: !fanRow.editing
      text: (root.fanNameMap && fanRow.fan) ? root.fanDisplayName(fanRow.fan) : ""
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      wrapMode: Text.NoWrap
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.right: fanRpm.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter

      MouseArea {
        id: fanNameHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (fanRow.fan) root.beginFanRename(fanRow.fan.key)
      }
    }

    TextField {
      id: fanEdit
      visible: fanRow.editing
      anchors.left: parent.left
      anchors.right: fanRpm.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      foreground: root.fg
      accent: Color.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      verticalPadding: Style.space(2)
      maximumLength: 32
      placeholderText: "Name"
      onVisibleChanged: {
        if (visible && fanRow.fan) {
          text = root.fanDisplayName(fanRow.fan)
          selectAll()
          forceActiveFocus()
        }
      }
      onAccepted: if (fanRow.fan) root.commitFanRename(fanRow.fan.key, text)
      onEditingFinished: if (fanRow.fan) root.commitFanRename(fanRow.fan.key, text)
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.cancelFanRename()
          event.accepted = true
        }
      }
    }

    Text {
      id: fanRpm
      textFormat: Text.PlainText
      text: fanRow.rpmText
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      width: Math.max(fanRpmMetrics.width, Style.space(70))
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  component FanToggleRow: Item {
    id: fanToggle

    property var fan: null

    readonly property bool editing: fan && root.editingFanKey === fan.key

    width: parent.width
    implicitHeight: Math.max(fanToggleText.implicitHeight, fanSwitch.implicitHeight)

    Column {
      id: fanToggleText
      anchors.left: parent.left
      anchors.right: fanSwitch.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        visible: !fanToggle.editing
        width: parent.width
        text: (root.fanNameMap && fanToggle.fan) ? root.fanDisplayName(fanToggle.fan) : ""
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        wrapMode: Text.NoWrap
        elide: Text.ElideRight

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: if (fanToggle.fan) root.beginFanRename(fanToggle.fan.key)
        }
      }

      TextField {
        visible: fanToggle.editing
        width: parent.width
        foreground: root.fg
        accent: Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        verticalPadding: Style.space(2)
        maximumLength: 32
        placeholderText: "Name"
        onVisibleChanged: {
          if (visible && fanToggle.fan) {
            text = root.fanDisplayName(fanToggle.fan)
            selectAll()
            forceActiveFocus()
          }
        }
        onAccepted: if (fanToggle.fan) root.commitFanRename(fanToggle.fan.key, text)
        onEditingFinished: if (fanToggle.fan) root.commitFanRename(fanToggle.fan.key, text)
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.cancelFanRename()
            event.accepted = true
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: fanToggle.fan ? (fanToggle.fan.key + " · " + fanToggle.fan.rpm + " RPM") : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
      }
    }

    ToggleSwitch {
      id: fanSwitch
      checked: !!(fanToggle.fan && !root.fanIgnored(fanToggle.fan.key))
      foreground: root.fg
      accent: Color.accent
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      onToggled: if (fanToggle.fan) root.toggleFanHidden(fanToggle.fan.key)
    }
  }

  Process {
    id: systemProc
    command: [root.systemScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parse(text)
    }
  }

  Timer {
    interval: 2000
    running: root.popupOpen || root.desktopEmbedded
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!systemProc.running) systemProc.running = true
  }
}
