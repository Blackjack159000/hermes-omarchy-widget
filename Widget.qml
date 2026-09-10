import QtQuick
import QtQuick.Controls
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.giulio.hermes-hub"
  ipcTarget: "io.github.giulio.hermes-hub"
  manageIpc: true

  implicitWidth: Style.bar.iconSlot
  implicitHeight: Style.bar.iconSlot

  // ------------------------------------------------------------------ theme
  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  readonly property color fill: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.05)
  readonly property color fillStrong: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  readonly property color line: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------------ state
  property var hubState: null
  property bool refreshing: false
  property bool bridgeReady: false
  property bool chatMode: false
  property string chatActiveAgent: ""
  property var chatMessages: []
  property bool chatBusy: false
  property bool polling: false
  property string runId: ""

  readonly property string bridgeScript: String(Qt.resolvedUrl("bridge.py")).replace(/^file:\/\//, "")
  readonly property string bridgeUrl: "http://127.0.0.1:8650"
  readonly property var agents: hubState && hubState.agents ? hubState.agents : []
  readonly property var usage: hubState && hubState.usage ? hubState.usage : null
  readonly property var byDay: usage && usage.byDay ? usage.byDay : []
  readonly property var byAgent: usage && usage.byAgent ? usage.byAgent : []
  readonly property var allTime: usage && usage.allTime ? usage.allTime : ({ tokens: 0, cost: 0, sessions: 0 })
  readonly property var week: usage && usage.week ? usage.week : ({ tokens: 0, cost: 0, sessions: 0 })
  readonly property string defaultAgent: hubState && hubState.defaultAgent ? String(hubState.defaultAgent) : (agents.length ? agents[0].name : "")
  readonly property string hermesCommand: String(root.setting("hermesCommand", "hermes-desktop"))
  readonly property int refreshMs: Math.max(30, Number(root.setting("refreshIntervalSec", 120))) * 1000
  readonly property int maxDayTokens: {
    var max = 1
    for (var i = 0; i < byDay.length; i++) {
      var t = Number(byDay[i].tokens) || 0
      if (t > max) max = t
    }
    return max
  }

  // -------------------------------------------------------------- lifecycle
  onOpenedChanged: {
    if (opened) {
      root.refresh()
      if (root.chatMode) chatInputForce.restart()
    }
  }

  Component.onCompleted: root.refresh()

  Timer {
    id: refreshTimer
    interval: root.refreshMs
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  // Keeps polling every 1.5s until the bridge has produced a real state
  // (the bridge answers /state with {ok:false,loading:true} while it warms
  // up). This is what makes the widget recover cleanly after a reboot or a
  // resume from sleep, when the bridge and/or Tailscale are not up yet.
  Timer {
    id: bootTimer
    interval: 1500
    repeat: true
    running: !(root.hubState && root.hubState.ok)
    onTriggered: root.refresh()
  }

  Timer {
    id: chatInputForce
    interval: 60
    repeat: false
    onTriggered: if (chatInput) chatInput.forceActiveFocus()
  }

  Timer {
    id: pollTimer
    interval: 120
    repeat: true
    running: root.chatBusy && root.runId !== ""
    onTriggered: root.pollChat()
  }

  Process {
    id: bridgeProc
    command: ["python3", root.bridgeScript]
    running: true
    onExited: bridgeRetry.restart()
  }

  Timer {
    id: bridgeRetry
    interval: 3000
    repeat: false
    onTriggered: bridgeProc.running = true
  }

  // ---------------------------------------------------------------- helpers
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function textOn(c) {
    var lum = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    return lum > 0.55 ? "#101315" : "#ffffff"
  }

  function fmtTokens(n) {
    n = Number(n) || 0
    if (n >= 1e9) return (n / 1e9).toFixed(2) + "B"
    if (n >= 1e6) return (n / 1e6).toFixed(2) + "M"
    if (n >= 1e3) return (n / 1e3).toFixed(0) + "K"
    return String(Math.round(n))
  }

  function fmtMoney(v) {
    var n = Number(v) || 0
    if (n >= 100) return "$" + n.toFixed(0)
    if (n >= 1) return "$" + n.toFixed(2)
    if (n >= 0.01) return "$" + n.toFixed(3)
    return "$" + n.toFixed(4)
  }

  function fmtTime(ts) {
    if (!ts) return "—"
    var d = new Date(Number(ts) * 1000)
    var h = d.getHours()
    var m = d.getMinutes()
    return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
  }

  function fetchJson(url, onOk, onErr, method, body, timeout) {
    var req = new XMLHttpRequest()
    var finished = false
    function fail() { if (!finished) { finished = true; if (onErr) onErr() } }
    req.timeout = timeout || 9000
    req.onreadystatechange = function() {
      if (req.readyState !== XMLHttpRequest.DONE || finished) return
      if (req.status !== 200) { fail(); return }
      var parsed = null
      try { parsed = JSON.parse(req.responseText) } catch (e) { fail(); return }
      finished = true
      onOk(parsed)
    }
    req.onerror = fail
    req.ontimeout = fail
    try {
      req.open(method || "GET", url)
      if (body !== undefined) req.setRequestHeader("Content-Type", "application/json")
      req.send(body === undefined ? null : JSON.stringify(body))
    } catch (e) { fail() }
  }

  function refresh() {
    if (root.refreshing) return
    root.refreshing = true
    fetchJson(root.bridgeUrl + "/state", function(data) {
      root.hubState = data
      root.bridgeReady = true
      root.refreshing = false
      if (!root.chatActiveAgent && data.defaultAgent) root.chatActiveAgent = String(data.defaultAgent)
    }, function() {
      root.refreshing = false
      root.bridgeReady = false
    })
  }

  function openChat(name) {
    var agent = name && String(name).length ? String(name) : root.defaultAgent
    if (agent) root.chatActiveAgent = agent
    root.chatMode = true
    if (!root.opened) root.open()
    else chatInputForce.restart()
  }

  function sendChat() {
    if (root.chatBusy) { root.stopChat(); return }
    var text = chatInput.text.trim()
    if (!text) return
    var agent = root.chatActiveAgent || root.defaultAgent
    root.chatMessages = root.chatMessages.concat([
      { role: "user", text: text },
      { role: "assistant", text: "" }
    ])
    chatInput.text = ""
    root.chatBusy = true
    fetchJson(root.bridgeUrl + "/chat", function(data) {
      root.runId = String(data.run_id || "")
      if (root.runId === "") { root.chatBusy = false; root.appendSystem("Could not start the run.") }
    }, function() {
      root.chatBusy = false
      root.appendSystem("Bridge unreachable — is the Hermes gateway up?")
    }, "POST", { agent: agent, message: text }, 20000)
  }

  function pollChat() {
    if (!root.runId || root.polling) return
    root.polling = true
    fetchJson(root.bridgeUrl + "/chat/poll?run_id=" + encodeURIComponent(root.runId), function(data) {
      root.polling = false
      var msgs = root.chatMessages.slice()
      if (msgs.length && msgs[msgs.length - 1].role === "assistant") {
        msgs[msgs.length - 1] = { role: "assistant", text: String(data.text || "") }
        root.chatMessages = msgs
      }
      if (data.done) {
        root.runId = ""
        root.chatBusy = false
        if (data.error) root.appendSystem(String(data.error))
        root.refresh()
      }
    }, function() { root.polling = false }, "GET", undefined, 9000)
  }

  function stopChat() {
    if (!root.runId) return
    fetchJson(root.bridgeUrl + "/chat/stop", function() {}, function() {}, "POST", { run_id: root.runId })
    root.runId = ""
    root.chatBusy = false
  }

  function resetChat() {
    var agent = root.chatActiveAgent || root.defaultAgent
    root.stopChat()
    root.chatMessages = []
    fetchJson(root.bridgeUrl + "/chat/reset", function() {
      root.appendSystem("New " + agent + " session.")
    }, function() {
      root.appendSystem("Could not reset session.")
    }, "POST", { agent: agent })
  }

  function appendSystem(text) {
    root.chatMessages = root.chatMessages.concat([{ role: "system", text: text }])
  }

  function openHermes() {
    if (root.bar) root.bar.run(root.hermesCommand)
    root.close()
  }

  function healthColor(agent) {
    if (!agent || !agent.health) return root.faint
    return agent.health.ok ? root.accent : root.urgent
  }

  // --------------------------------------------------------------- bar icon
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "Hermes Hub"
    active: root.chatBusy
    iconComponent: Component {
      Item {
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        Image {
          id: barImage
          anchors.fill: parent
          source: Qt.resolvedUrl("assets/hermes-icon.png")
          sourceSize: Qt.size(128, 128)
          fillMode: Image.PreserveAspectFit
          smooth: true
        }
        ColorOverlay {
          anchors.fill: barImage
          source: barImage
          color: root.bar ? root.bar.barForeground : Color.foreground
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        root.openChat(root.chatActiveAgent || root.defaultAgent)
      } else if (buttonCode === Qt.MiddleButton) {
        root.refresh()
      } else if (root.opened) {
        root.close()
      } else {
        root.chatMode = false
        root.open()
      }
    }
  }

  // --------------------------------------------------------------- overview
  PopupCard {
    id: overview
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && !root.chatMode
    contentWidth: overview.fittedContentWidth(Style.space(392))
    contentHeight: overview.fittedContentHeight(contentColumn.implicitHeight)

    Column {
      id: contentColumn
      width: parent.width
      spacing: Style.space(10)

      PanelHero {
        width: parent.width
        title: "Hermes Hub"
        meta: (root.agents.length || 0) + " agents · updated " + root.fmtTime(root.hubState ? root.hubState.updated : 0)
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconComponent: Component {
          Item {
            width: Style.font.display
            height: Style.font.display
            Image {
              id: heroImage
              anchors.fill: parent
              source: Qt.resolvedUrl("assets/hermes-icon.png")
              sourceSize: Qt.size(128, 128)
              fillMode: Image.PreserveAspectFit
              smooth: true
            }
            ColorOverlay {
              anchors.fill: heroImage
              source: heroImage
              color: root.accent
            }
          }
        }
        trailingControl: Component {
          Item {
            width: refreshGlyph.implicitWidth + Style.space(8)
            height: Style.font.title + Style.space(8)
            Text {
              id: refreshGlyph
              anchors.centerIn: parent
              text: "↻"
              color: refreshHover.hovered ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              rotation: root.refreshing ? 180 : 0
              Behavior on rotation { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
            }
            HoverHandler { id: refreshHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.refresh() }
          }
        }
      }

      Text {
        width: parent.width
        visible: !root.hubState || !root.hubState.ok
        text: root.bridgeReady ? "Connecting to agents…" : "Bridge starting…"
        color: root.faint
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
      }

      // Empty panel means NO AGENTS WERE FOUND, which is a configuration state,
      // not a failure. Say which and how to fix it — a silent blank panel is the
      // difference between "broken" and "not set up yet".
      Text {
        width: parent.width
        visible: root.hubState && root.hubState.ok && root.agents.length === 0
        text: (root.hubState && root.hubState.discovery && root.hubState.discovery.hint)
              ? String(root.hubState.discovery.hint)
              : "No Hermes agents found."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
      }

      Row {
        width: parent.width
        spacing: Style.space(10)

        StatCard {
          width: (parent.width - Style.space(10)) / 2
          title: "TOTAL SPENT"
          value: root.fmtMoney(root.allTime.cost)
          caption: root.fmtTokens(root.allTime.tokens) + " tokens · " + root.allTime.sessions + " sessions"
          highlight: true
        }

        StatCard {
          width: (parent.width - Style.space(10)) / 2
          title: "LAST 7 DAYS"
          value: root.fmtMoney(root.week.cost)
          caption: root.fmtTokens(root.week.tokens) + " tokens · " + root.week.sessions + " sessions"
        }
      }

      PanelSeparator { width: parent.width }

      PanelSectionHeader { text: "TOKENS · LAST 7 DAYS" }

      Row {
        id: chartRow
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: root.byDay
          delegate: DayColumn {
            width: (chartRow.width - Style.space(4) * 6) / 7
            dayData: modelData
            maxTokens: root.maxDayTokens
            isToday: index === root.byDay.length - 1
          }
        }
      }

      PanelSeparator { width: parent.width }

      PanelSectionHeader { text: "BY AGENT" }

      Grid {
        width: parent.width
        columns: 2
        columnSpacing: Style.space(6)
        rowSpacing: Style.space(2)
        Repeater {
          model: root.byAgent
          delegate: AgentRow {
            width: (parent.width - parent.columnSpacing) / 2
            agentData: modelData
            onClicked: root.openChat(modelData.name)
          }
        }
      }

      PanelSeparator { width: parent.width }

      Row {
        width: parent.width
        spacing: Style.space(8)

        HubButton {
          width: (parent.width - Style.space(8)) * 0.58
          label: "Open Hermes"
          primary: true
          onClicked: root.openHermes()
        }

        HubButton {
          width: (parent.width - Style.space(8)) * 0.42
          label: "Quick Chat"
          onClicked: root.openChat(root.chatActiveAgent || root.defaultAgent)
        }
      }

      Text {
        width: parent.width
        text: "left-click panel · right-click chat · middle-click refresh"
        color: root.faint
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }

  // ------------------------------------------------------------------- chat
  KeyboardPanel {
    id: chatPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.chatMode
    focusTarget: chatInput
    contentWidth: chatPanel.fittedContentWidth(Style.space(392))
    contentHeight: chatPanel.fittedContentHeight(Style.space(548), Style.space(660))

    Item {
      id: chatLayout
      anchors.fill: parent

      // header
      Item {
        id: chatHeader
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(30)

        Text {
          id: backGlyph
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "←"
          color: backHover.hovered ? root.accent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          HoverHandler { id: backHover; cursorShape: Qt.PointingHandCursor }
          TapHandler { onTapped: root.chatMode = false }
        }

        Text {
          anchors.left: backGlyph.right
          anchors.leftMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          text: "Quick Chat"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(12)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "✎"
            color: newHover.hovered ? root.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            HoverHandler { id: newHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.resetChat() }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Open Hermes"
            color: deskHover.hovered ? root.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            HoverHandler { id: deskHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.openHermes() }
          }
        }
      }

      // agent chips
      Flickable {
        id: chipsFlick
        anchors.top: chatHeader.bottom
        anchors.topMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(28)
        contentWidth: chipsRow.width
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.HorizontalFlick

        Row {
          id: chipsRow
          height: parent.height
          spacing: Style.space(6)
          Repeater {
            model: root.agents
            delegate: AgentChip {
              height: chipsRow.height
              label: modelData.name
              selected: root.chatActiveAgent === modelData.name
              dotColor: root.healthColor(modelData)
              onClicked: {
                root.chatActiveAgent = modelData.name
                chatInput.forceActiveFocus()
              }
            }
          }
        }
      }

      PanelSeparator {
        id: chatSep
        anchors.top: chipsFlick.bottom
        anchors.topMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
      }

      // messages
      Flickable {
        id: msgFlick
        anchors.top: chatSep.bottom
        anchors.topMargin: Style.space(10)
        anchors.bottom: inputShell.top
        anchors.bottomMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        contentWidth: width
        contentHeight: msgColumn.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        onContentHeightChanged: contentY = Math.max(0, contentHeight - height)
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: msgColumn
          width: msgFlick.width
          spacing: Style.space(8)

          Text {
            width: parent.width
            visible: root.chatMessages.length === 0
            text: "Ask " + (root.chatActiveAgent || "an agent") + " anything."
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            topPadding: Style.space(24)
          }

          Repeater {
            model: root.chatMessages
            delegate: MessageBubble {
              width: msgColumn.width
              role: modelData.role
              text: modelData.text
              streaming: root.chatBusy && index === root.chatMessages.length - 1 && modelData.role === "assistant"
            }
          }

          Text {
            width: parent.width
            visible: root.chatBusy && root.chatMessages.length > 0 &&
                     root.chatMessages[root.chatMessages.length - 1].text === "" &&
                     root.chatMessages[root.chatMessages.length - 1].role === "assistant"
            text: (root.chatActiveAgent || "Agent") + " is thinking…"
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }

      // input
      Rectangle {
        id: inputShell
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(36)
        radius: Style.cornerRadius
        color: root.fill
        border.width: 1
        border.color: chatInput.activeFocus ? root.alpha(root.accent, 0.7) : root.line

        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(12)
          anchors.right: sendGlyph.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: "Message " + (root.chatActiveAgent || "agent") + "…"
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          visible: chatInput.text.length === 0
        }

        TextInput {
          id: chatInput
          anchors.left: parent.left
          anchors.leftMargin: Style.space(12)
          anchors.right: sendGlyph.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          selectionColor: root.accent
          selectedTextColor: root.textOn(root.accent)
          clip: true
          Keys.onEscapePressed: root.close()
          Keys.onReturnPressed: root.sendChat()
          Keys.onEnterPressed: root.sendChat()
        }

        Text {
          id: sendGlyph
          anchors.right: parent.right
          anchors.rightMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          text: root.chatBusy ? "■" : "→"
          color: root.chatBusy ? root.urgent : root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          opacity: root.chatBusy || chatInput.text.length > 0 ? 1 : 0.4
          HoverHandler { cursorShape: Qt.PointingHandCursor }
          TapHandler { onTapped: root.sendChat() }
        }
      }
    }
  }

  // --------------------------------------------------------------- components
  component HubButton: Rectangle {
    id: hubBtn
    property string label: ""
    property bool primary: false
    signal clicked()

    implicitHeight: Style.space(30)
    radius: Style.cornerRadius
    color: {
      if (hubBtn.primary) return hubHover.hovered ? Qt.lighter(root.accent, 1.12) : root.accent
      return hubHover.hovered ? root.alpha(root.foreground, 0.12) : root.alpha(root.foreground, 0.06)
    }
    border.width: hubBtn.primary ? 0 : 1
    border.color: root.alpha(root.foreground, 0.16)

    Text {
      anchors.centerIn: parent
      text: hubBtn.label
      color: hubBtn.primary ? root.textOn(root.accent) : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: hubBtn.primary
    }

    HoverHandler { id: hubHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: hubBtn.clicked() }
  }

  component StatCard: Rectangle {
    id: statCard
    property string title: ""
    property string value: ""
    property string caption: ""
    property bool highlight: false

    implicitHeight: Style.space(56)
    radius: Style.cornerRadius
    color: root.fill
    border.width: 1
    border.color: statCard.highlight ? root.alpha(root.accent, 0.35) : root.line

    Column {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      spacing: Style.space(2)

      Text {
        text: statCard.title
        color: root.faint
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.0
      }
      Text {
        text: statCard.value
        color: statCard.highlight ? root.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        text: statCard.caption
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: parent.width
      }
    }
  }

  component DayColumn: Column {
    id: dayColumn
    property var dayData: null
    property int maxTokens: 1
    property bool isToday: false

    spacing: Style.space(4)

    Text {
      width: parent.width
      text: root.fmtTokens(dayColumn.dayData ? dayColumn.dayData.tokens : 0)
      color: dayColumn.isToday ? root.accent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
    }

    Item {
      width: parent.width
      height: Style.space(44)

      Rectangle {
        id: bar
        width: Math.max(Style.space(6), Math.round(parent.width * 0.6))
        height: Math.max(Style.space(3), Math.round(parent.height * ((dayColumn.dayData ? Number(dayColumn.dayData.tokens) : 0) / Math.max(1, dayColumn.maxTokens))))
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        radius: width / 2
        color: dayColumn.isToday ? root.accent : root.alpha(root.foreground, 0.32)

        Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
      }
    }

    Text {
      width: parent.width
      text: dayColumn.dayData ? dayColumn.dayData.label : ""
      color: dayColumn.isToday ? root.foreground : root.faint
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayColumn.isToday
      horizontalAlignment: Text.AlignHCenter
    }
  }

  component AgentRow: Rectangle {
    id: agentRow
    property var agentData: null
    signal clicked()

    implicitHeight: Style.space(34)
    radius: Style.cornerRadius
    color: agentHover.hovered ? root.fill : "transparent"

    Rectangle {
      id: agentDot
      width: Style.space(8)
      height: Style.space(8)
      radius: width / 2
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      color: root.healthColor(agentRow.agentData)
    }

    Text {
      id: agentName
      anchors.left: agentDot.right
      anchors.leftMargin: Style.space(7)
      anchors.right: agentCost.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: agentRow.agentData ? agentRow.agentData.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      elide: Text.ElideRight
    }

    Column {
      id: agentCost
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0

      Text {
        anchors.right: parent.right
        text: root.fmtMoney(agentRow.agentData ? agentRow.agentData.weekCost : 0)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        horizontalAlignment: Text.AlignRight
      }
      Text {
        anchors.right: parent.right
        text: root.fmtMoney(agentRow.agentData ? agentRow.agentData.cost : 0) + " all-time"
        color: root.faint
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignRight
      }
    }

    HoverHandler { id: agentHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: agentRow.clicked() }
  }

  component AgentChip: Rectangle {
    id: chip
    property string label: ""
    property bool selected: false
    property color dotColor: root.faint
    signal clicked()

    implicitWidth: chipRow.implicitWidth + Style.space(20)
    radius: height / 2
    color: chip.selected ? root.alpha(root.accent, 0.18) : (chipHover.hovered ? root.fillStrong : root.fill)
    border.width: 1
    border.color: chip.selected ? root.alpha(root.accent, 0.6) : root.line

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(6)
      Rectangle {
        width: Style.space(6)
        height: Style.space(6)
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: chip.dotColor
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: chip.label
        color: chip.selected ? root.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: chip.selected
      }
    }

    HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: chip.clicked() }
  }

  component MessageBubble: Item {
    id: bubble
    property string role: "assistant"
    property string text: ""
    property bool streaming: false

    implicitHeight: bubbleRect.height

    Rectangle {
      id: bubbleRect
      property real maxW: Math.max(Style.space(80), bubble.width * 0.86)
      width: Math.min(maxW, bubbleText.implicitWidth + Style.space(24))
      height: bubbleText.implicitHeight + Style.space(14)
      radius: Style.cornerRadius
      anchors.right: bubble.role === "user" ? parent.right : undefined
      anchors.left: bubble.role === "user" ? undefined : parent.left
      color: bubble.role === "user" ? root.accent : root.fill
      border.width: bubble.role === "user" ? 0 : 1
      border.color: root.line

      Text {
        id: bubbleText
        anchors.centerIn: parent
        width: bubbleRect.width - Style.space(24)
        text: bubble.role === "system"
          ? bubble.text
          : bubble.text + (bubble.streaming && bubble.text.length > 0 ? " ▍" : "")
        color: bubble.role === "user" ? root.textOn(root.accent) : (bubble.role === "system" ? root.faint : root.foreground)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.italic: bubble.role === "system"
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignLeft
      }
    }
  }
}
