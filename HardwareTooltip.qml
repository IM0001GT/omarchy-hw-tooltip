import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

BarWidget {
  id: root

  readonly property string systemScript:
    Quickshell.env("HOME") + "/.config/omarchy/plugins/" + root.moduleName + "/scripts/system-usage"

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(root.fg, 1.4)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  property string cpuText: "--"
  property string cpuName: "CPU"
  property string cpuTempText: "--"
  property string gpuTempText: ""
  property var cores: []
  property string ramUsed: "--"
  property string ramTotal: "--"
  property int ramPct: 0
  property string ramInfo: ""
  property string gpuText: "n/a"
  property string gpuName: "GPU"
  property string gpuKind: "render"
  property string gpuHint: ""
  property bool ramActive: false
  property bool diskActive: false
  property var disks: []
  property bool popupOpen: false

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

  function parse(raw) {
    var lines = String(raw || "").split("\n")
    var cores = []
    var disks = []
    var cpu = "--"
    var cpuName = root.cpuName
    var cpuTemp = root.cpuTempText
    var gpuTemp = root.gpuTempText
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
      } else if (key === "cpu_temp" && parts.length > 1) {
        cpuTemp = parts[1] === "n/a" ? "--" : parts[1] + "°C"
      } else if (key === "gpu_temp" && parts.length > 1) {
        gpuTemp = parts[1] === "n/a" ? "" : parts[1] + "°C"
      } else if (key === "ram_active" && parts.length > 1) {
        ramActive = parts[1] === "1"
      } else if (key === "disk_io" && parts.length > 1) {
        diskActive = parts[1] === "1"
      } else if (key === "disk" && parts.length > 4) {
        var diskPct = Math.max(0, Math.min(100, Math.round(parseFloat(parts[4]) || 0)))
        var model = parts.length > 5 ? parts.slice(5).join(" ") : ""
        disks.push({ mount: parts[1], used: parts[2], total: parts[3], percent: diskPct, name: model })
      }
    }

    root.cpuText = cpu
    root.cpuName = cpuName
    root.cores = cores
    root.ramUsed = ramUsed
    root.ramTotal = ramTotal
    root.ramPct = ramPct
    root.ramInfo = ramInfo
    root.gpuText = gpu
    root.gpuName = gpuName
    root.gpuKind = gpuKind
    root.gpuHint = gpuHint
    root.cpuTempText = cpuTemp
    root.gpuTempText = gpuTemp
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

  function close() {
    root.popupOpen = false
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
      if (popup.open) root.startRotation()
      else rotationStop.restart()
    }
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
        implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercentBlock.implicitHeight)

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
          id: heroLabels
          anchors.left: heroIcon.right
          anchors.leftMargin: Style.space(14)
          anchors.right: heroPercentBlock.left
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            text: "CPU"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            visible: root.cpuName !== "" && root.cpuName !== "CPU"
            text: root.cpuName
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            id: heroStatus
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

        Column {
          id: heroPercentBlock
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            id: heroPercent
            text: root.cpuText
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            anchors.right: parent.right
          }

          Text {
            visible: root.cpuTempText !== "--"
            text: root.cpuTempText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
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

        SectionBlock {
          icon: "󰓅"
          title: "Memory"
          value: root.ramPct + "%"
          status: root.ramInfo !== ""
            ? root.ramInfo + " · " + root.ramUsed + " / " + root.ramTotal + " GiB"
            : root.ramUsed + " / " + root.ramTotal + " GiB"
          percent: root.ramPct
        }

        PanelSeparator {
          foreground: root.fg
        }

        SectionBlock {
          icon: "󰢮"
          title: "GPU"
          value: root.gpuText
          status: root.gpuText === "n/a"
            ? (root.gpuHint === "nvidia-utils" ? "Install nvidia-utils for GPU stats" : "GPU stats unavailable")
            : (root.gpuTempText !== "" ? root.gpuName + " · " + root.gpuTempText : root.gpuName)
          percent: root.gpuText === "n/a" ? -1 : root.gpuPct
        }

        PanelSeparator {
          foreground: root.fg
        }

        SectionBlock {
          icon: "󰋊"
          title: "Storage"
          value: ""
          status: ""
          percent: -1
        }

        Column {
          width: parent.width
          spacing: Style.spacing.sm

          Repeater {
            model: root.disks

            StatRow {
              required property var modelData

              label: modelData.name ? modelData.name : modelData.mount
              value: modelData.percent + "%"
              percent: modelData.percent
              caption: modelData.name
                ? modelData.mount + " · " + modelData.used + " / " + modelData.total + " GiB"
                : modelData.used + " / " + modelData.total + " GiB"
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
    property int percent: -1

    width: parent.width
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(secIcon.implicitHeight, secTitle.implicitHeight, secValue.implicitHeight)

      Text {
        id: secIcon
        visible: section.icon !== ""
        text: section.icon
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: secTitle
        text: section.title
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        anchors.left: secIcon.right
        anchors.leftMargin: Style.space(8)
        anchors.right: secValue.visible ? secValue.left : parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: secValue
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
    property string caption: ""

    width: parent.width

    readonly property real headerHeight: Math.max(statLabel.implicitHeight, statValue.implicitHeight)
    readonly property real barHeight: Style.space(5)
    readonly property real gap: Style.space(3)
    readonly property real barBlock: percent >= 0 ? gap + barHeight : 0

    implicitHeight: headerHeight
      + barBlock
      + (captionText.visible ? gap + captionText.implicitHeight : 0)

    Item {
      id: headerRow
      width: parent.width
      height: statRow.headerHeight

      Text {
        id: statLabel
        text: statRow.label
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: statValue.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: statValue
        text: statRow.value
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      visible: statRow.percent >= 0
      y: headerRow.height + statRow.gap
      width: parent.width
      implicitHeight: statRow.barHeight
      percent: statRow.percent
    }

    Text {
      id: captionText
      visible: statRow.caption !== ""
      y: headerRow.height + statRow.barBlock + statRow.gap
      width: parent.width
      text: statRow.caption
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.NoWrap
      elide: Text.ElideRight
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
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!systemProc.running) systemProc.running = true
  }
}
