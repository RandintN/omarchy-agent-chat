import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "ChatAdapters.js" as Adapters

// A fullscreen, keyboard-exclusive chat surface for the machine's default
// coding agent. The agent is driven over a persistent JSON protocol (one
// command per line on stdin, one event per line on stdout); the per-agent wire
// formats live in ChatAdapters.js. The overlay is loaded only while it is
// summoned, so Esc tears the agent process down with it.
Item {
  id: root

  // Injected by omarchy-shell before open() is called.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME") || "/home"
  readonly property string ipcId: (manifest && manifest.id) || "robson.agent-chat"
  readonly property string agentFile: home + "/.config/omarchy/defaults/agent"

  // ------------------------------------------------------------- state

  property bool opened: false
  property bool streaming: false
  property bool agentReady: false
  property string inputText: ""
  property string statusText: ""
  property string modelName: ""
  property bool agentResolved: false
  property string defaultAgent: ""
  property var adapter: null
  property bool unsupportedNotified: false

  // Index of the assistant bubble currently receiving deltas, or -1 when the
  // next delta should open a fresh bubble. Reset on every message_start so a
  // tool-using turn grows a new bubble instead of appending to the old one.
  property int currentIndex: -1
  property bool stickToBottom: true

  // Optimistic until the one-line agent file has been read, so the composer
  // does not flicker to "unsupported" for the first frame of every open.
  readonly property bool rpcSupported: !root.agentResolved || (!!root.adapter && root.adapter.supported)

  readonly property string statusLabel: {
    if (root.agentResolved && !root.rpcSupported) return "unavailable"
    if (!root.agentReady) return "connecting…"
    if (root.streaming) return root.statusText || "thinking…"
    return root.modelName || "ready"
  }

  // ------------------------------------------------------------- theme

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color scrim: Color.menu.scrim
  property color accent: Color.menu.selectedBackground
  property color accentText: Color.menu.selectedText
  property color danger: Color.urgent
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property var inputBorderSpec: Border.surfaceSpec("menu", "border", Util.alpha(foreground, 0.2), 1)
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int inputHeight: Style.space(42)
  readonly property int cardWidth: Math.min(Style.space(780), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(640), panel.height - Style.gapsOut * 2)

  // ------------------------------------------------------- lifecycle API

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.fontFamily) root.fontFamily = payload.fontFamily

    root.opened = true
    root.streaming = false
    root.agentReady = false
    root.inputText = ""
    root.statusText = ""
    root.modelName = ""
    root.currentIndex = -1
    root.stickToBottom = true
    root.unsupportedNotified = false
    messageModel.clear()
    inputField.text = ""

    root.maybeStart()

    Qt.callLater(function() { inputField.forceActiveFocus() })
    return "ok"
  }

  // Called by the shell both when the user closes us and when hide() is
  // invoked from outside. Killing the process is the whole teardown: the
  // Loader drops this item next, taking the Process with it.
  function close() {
    root.opened = false
    root.streaming = false
    root.agentReady = false
    root.currentIndex = -1
    root.stickToBottom = true
    if (agentProc.running) agentProc.running = false
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // Esc path: close locally, then ask the host to forget the open state so
  // `omarchy-shell shell toggle` is a summon again.
  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.ipcId)
  }

  function applyAgentResolution(name) {
    root.defaultAgent = name
    root.agentResolved = true
    // Never swap the protocol out from under a running conversation.
    if (!agentProc.running) root.adapter = Adapters.adapterFor(name)
    root.maybeStart()
  }

  function maybeStart() {
    if (!root.opened || agentProc.running) return
    if (!root.agentResolved) return
    if (!root.rpcSupported) {
      if (!root.unsupportedNotified) {
        root.unsupportedNotified = true
        root.addMessage("error",
          "The default agent is \"" + (root.defaultAgent || "unknown") + "\". " +
          ((root.adapter && root.adapter.reason) || "It is not supported yet.") +
          " You can still open it in a terminal with Super+A.")
      }
      return
    }
    root.startAgent()
  }

  function startAgent() {
    if (agentProc.running) return
    if (!root.adapter || !root.adapter.supported) return
    agentProc.command = root.adapter.command()
    agentProc.running = true
  }

  // --------------------------------------------------------- agent protocol

  function send(command) {
    if (!agentProc.running) return
    agentProc.write(JSON.stringify(command) + "\n")
  }

  function sendPrompt() {
    if (!root.agentReady || !root.rpcSupported || !root.adapter) return
    var text = root.inputText.trim()
    if (!text) return

    var command = root.adapter.prompt(text, root.streaming)
    if (!command) return

    root.addMessage("user", text)
    inputField.text = ""
    root.inputText = ""
    root.stickToBottom = true

    if (!root.streaming) {
      root.streaming = true
      root.statusText = ""
    }
    root.send(command)
  }

  // The adapter turns a raw stdout line into normalized events; this file only
  // knows how to render them.
  function handleEvent(line) {
    if (!root.adapter) return
    var events = root.adapter.translate(line)
    for (var i = 0; i < events.length; i++) root.applyEvent(events[i])
  }

  function applyEvent(event) {
    switch (event.kind) {
    case "stream_start":
      root.streaming = true
      break
    case "assistant_reset":
      root.currentIndex = -1
      break
    case "text":
      root.appendText(event.delta)
      break
    case "assistant_end":
      root.onAssistantEnd(event.text)
      break
    case "tool":
      root.addMessage("tool", event.name || "tool", event.detail || "")
      break
    case "status":
      root.statusText = event.text || ""
      break
    case "model":
      root.modelName = event.name || ""
      break
    case "settled":
      root.streaming = false
      root.currentIndex = -1
      root.statusText = ""
      break
    case "error":
      root.streaming = false
      root.addMessage("error", event.text || "The agent rejected the command.")
      break
    case "system":
      root.addMessage("system", event.text || "")
      break
    case "dialog":
      // A blocking dialog would hang the agent: answer it as cancelled.
      var cancel = root.adapter && root.adapter.cancelDialog ? root.adapter.cancelDialog(event.id) : null
      if (cancel) root.send(cancel)
      break
    }
  }

  function onAssistantEnd(text) {
    if (root.currentIndex >= 0) {
      var current = messageModel.get(root.currentIndex)
      if (text && (!current || !current.msgText)) messageModel.setProperty(root.currentIndex, "msgText", text)
    } else if (text) {
      root.addMessage("assistant", text)
    }
  }

  // ------------------------------------------------------- message store

  ListModel { id: messageModel }

  function addMessage(kind, text, detail) {
    messageModel.append({ msgKind: kind, msgText: text || "", msgDetail: detail || "" })
    if (kind === "assistant") root.currentIndex = messageModel.count - 1
    root.scrollToEnd()
  }

  function appendText(delta) {
    if (!delta) return
    if (root.currentIndex < 0 || root.currentIndex >= messageModel.count) {
      messageModel.append({ msgKind: "assistant", msgText: "", msgDetail: "" })
      root.currentIndex = messageModel.count - 1
    }
    var current = messageModel.get(root.currentIndex).msgText || ""
    messageModel.setProperty(root.currentIndex, "msgText", current + delta)
    root.scrollToEnd()
  }

  function scrollToEnd() {
    if (root.stickToBottom) Qt.callLater(function() { chatList.positionViewAtEnd() })
  }

  // ------------------------------------------------------- agent wiring

  Process {
    id: agentProc
    running: false
    stdinEnabled: true
    workingDirectory: root.home

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.handleEvent(line) }
    }

    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        var message = String(line || "").trim()
        if (message) root.addMessage("system", message)
      }
    }

    onStarted: {
      root.agentReady = true
      var commands = root.adapter ? root.adapter.startCommands() : []
      for (var i = 0; i < commands.length; i++) root.send(commands[i])
    }

    onExited: function(exitCode, exitStatus) {
      root.agentReady = false
      root.streaming = false
      if (root.opened) root.addMessage("error", "The agent exited (code " + exitCode + ").")
    }
  }

  // The default agent lives in a one-line file written by `omarchy default
  // agent`; the adapter registry decides how (or whether) the modal can talk
  // to it.
  FileView {
    path: root.agentFile
    watchChanges: true
    printErrors: false
    onLoaded: root.applyAgentResolution(String(text() || "").trim().split("\n")[0].trim() || "pi")
    onLoadFailed: root.applyAgentResolution("pi")
    onFileChanged: reload()
  }

  // Catch Esc even when focus drifted off the input (e.g. after selecting
  // text in a reply).
  Shortcut {
    sequence: "Escape"
    enabled: root.opened
    onActivated: root.dismiss()
  }

  // ------------------------------------------------------------- surface

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-agent-chat"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      anchors.centerIn: parent
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      // Swallow clicks on the card so the dismissing scrim MouseArea under it
      // never fires. Clicking the card also returns focus to the composer.
      MouseArea {
        anchors.fill: parent
        onClicked: inputField.forceActiveFocus()
      }

      ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.sm

        // ---------------------------------------------------------- header
        RowLayout {
          Layout.fillWidth: true
          Layout.preferredHeight: root.headerHeight
          spacing: Style.space(10)

          Text {
            text: "󰚩"
            color: root.accentText
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            Layout.alignment: Qt.AlignVCenter
          }

          Text {
            text: "Default agent"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
            Layout.alignment: Qt.AlignVCenter
          }

          Text {
            text: root.defaultAgent ? "· " + root.defaultAgent : ""
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            Layout.alignment: Qt.AlignVCenter
          }

          Item { Layout.fillWidth: true }

          Rectangle {
            Layout.preferredHeight: Style.space(22)
            Layout.preferredWidth: statusLabelText.implicitWidth + Style.space(18)
            Layout.alignment: Qt.AlignVCenter
            radius: Style.space(11)
            color: root.streaming ? Util.alpha(root.accentText, 0.22) : Util.alpha(root.foreground, 0.1)

            Text {
              id: statusLabelText
              anchors.centerIn: parent
              text: root.statusLabel
              textFormat: Text.PlainText
              color: root.streaming ? root.accentText : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: Style.spacing.hairline
          color: Util.alpha(root.foreground, 0.15)
        }

        // ------------------------------------------------------------ chat
        ListView {
          id: chatList
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          model: messageModel
          spacing: Style.space(12)
          boundsBehavior: Flickable.StopAtBounds

          onMovementEnded: root.stickToBottom = chatList.atYEnd
          onContentHeightChanged: if (root.stickToBottom) chatList.positionViewAtEnd()

          delegate: Item {
            id: messageRow
            required property int index
            required property string msgKind
            required property string msgText
            required property string msgDetail

            readonly property bool isUser: msgKind === "user"
            readonly property bool isAssistant: msgKind === "assistant"
            readonly property bool isTool: msgKind === "tool"
            readonly property bool isError: msgKind === "error"

            width: chatList.width
            height: contentColumn.implicitHeight

            Column {
              id: contentColumn
              width: parent.width
              spacing: 0

              // User bubble, right-aligned.
              BorderSurface {
                visible: messageRow.isUser
                x: parent.width - width
                width: Math.min(parent.width * 0.9,
                                Math.max(Style.space(120), userText.implicitWidth + Style.space(26)))
                height: userText.implicitHeight + Style.space(18)
                radius: root.cornerRadius
                color: root.accent
                borderSpec: Border.none()

                Text {
                  id: userText
                  anchors.fill: parent
                  anchors.margins: Style.space(9)
                  text: messageRow.msgText
                  textFormat: Text.PlainText
                  color: root.accentText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  wrapMode: Text.Wrap
                }
              }

              // Assistant reply, markdown-rendered and selectable.
              TextEdit {
                visible: messageRow.isAssistant
                width: parent.width
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.MarkdownText
                text: messageRow.msgText.length > 0
                  ? messageRow.msgText
                  : (messageRow.index === root.currentIndex && root.streaming ? "…" : "")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                selectionColor: root.accent
                selectedTextColor: root.accentText
              }

              // Tool / system / error line. Rendered as plain text: the agent
              // controls this string, and AutoText would let it inject markup.
              Text {
                visible: !messageRow.isUser && !messageRow.isAssistant
                width: parent.width
                text: (messageRow.isTool ? "⚙ " : (messageRow.isError ? "✕ " : "• "))
                  + messageRow.msgText
                  + (messageRow.msgDetail ? "   " + messageRow.msgDetail : "")
                textFormat: Text.PlainText
                color: messageRow.isError ? root.danger : root.foreground
                opacity: messageRow.isTool ? 0.6 : 0.8
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }
            }
          }

          // Empty state.
          Column {
            anchors.centerIn: parent
            width: parent.width
            spacing: Style.space(8)
            visible: messageModel.count === 0

            Text {
              width: parent.width
              text: "󰚩"
              color: root.accentText
              opacity: 0.75
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              width: parent.width
              text: root.rpcSupported
                ? "Ask anything. The conversation lives in the agent until you press Esc."
                : "Set the default agent to pi to chat here."
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
            }
          }
        }

        // -------------------------------------------------------- composer
        BorderSurface {
          Layout.fillWidth: true
          Layout.preferredHeight: root.inputHeight
          radius: root.cornerRadius
          color: Util.alpha(root.foreground, 0.06)
          borderSpec: root.inputBorderSpec

          TextInput {
            id: inputField
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            enabled: root.rpcSupported
            clip: true
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            selectionColor: root.accent
            selectedTextColor: root.accentText
            selectByMouse: true

            onTextChanged: root.inputText = text

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                root.dismiss()
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.sendPrompt()
                event.accepted = true
              }
            }
          }

          Text {
            anchors.left: inputField.left
            anchors.right: inputField.right
            anchors.verticalCenter: parent.verticalCenter
            visible: !inputField.text.length
            text: root.rpcSupported
              ? (root.streaming ? "Steer with an instruction…" : "Ask something…")
              : "Agent does not support RPC"
            color: root.foreground
            opacity: 0.42
            elide: Text.ElideRight
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        // ----------------------------------------------------------- hints
        RowLayout {
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(20)
          spacing: Style.space(16)

          RowLayout {
            spacing: Style.space(6)

            Rectangle {
              Layout.preferredHeight: Style.space(18)
              Layout.preferredWidth: enterKey.implicitWidth + Style.space(10)
              Layout.alignment: Qt.AlignVCenter
              radius: Style.space(4)
              color: Util.alpha(root.foreground, 0.1)

              Text {
                id: enterKey
                anchors.centerIn: parent
                text: "Enter"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              text: root.streaming ? "send as steer" : "send"
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              Layout.alignment: Qt.AlignVCenter
            }
          }

          RowLayout {
            spacing: Style.space(6)

            Rectangle {
              Layout.preferredHeight: Style.space(18)
              Layout.preferredWidth: escKey.implicitWidth + Style.space(10)
              Layout.alignment: Qt.AlignVCenter
              radius: Style.space(4)
              color: Util.alpha(root.foreground, 0.1)

              Text {
                id: escKey
                anchors.centerIn: parent
                text: "Esc"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              text: "end"
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              Layout.alignment: Qt.AlignVCenter
            }
          }

          Item { Layout.fillWidth: true }
        }
      }
    }
  }
}
