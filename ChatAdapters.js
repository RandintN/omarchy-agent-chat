.pragma library

// Protocol adapters for the Agent Chat modal.
//
// The modal is a persistent, line-delimited bridge: it spawns an agent once,
// writes one JSON command per line on stdin, and renders normalized events
// read from stdout. Each agent spells that differently, so this file is the
// only place that knows an agent's wire format. Chat.qml asks for an adapter
// and then only deals in normalized events:
//
//   { kind: "stream_start" }                          agent began a run
//   { kind: "assistant_reset" }                       open a fresh reply bubble
//   { kind: "text",      delta }                       streamed assistant text
//   { kind: "assistant_end", text }                    final text for the bubble
//   { kind: "tool",      name, detail }                a tool started
//   { kind: "status",    text }                        transient status ("…")
//   { kind: "model",     name }                        active model label
//   { kind: "settled" }                                run finished, composer unlocks
//   { kind: "error",     text }                        command rejected
//   { kind: "system",    text }                        informational line
//   { kind: "dialog",    id, method }                  agent asks for UI; caller cancels
//
// To support a new agent, add a descriptor below. `supported: true` requires a
// persistent bidirectional protocol (not one-shot `--print`). Agents that only
// offer ACP/HTTP/app-server or one-shot printing get an unsupported descriptor
// and the modal explains instead of hanging.

// --------------------------------------------------------------- pi / omp

// pi and Oh My Pi (a pi fork) share one RPC dialect: JSONL commands on stdin,
// JSONL events on stdout, with a `ready` handshake on omp. The shared
// translator is therefore the whole implementation for both.
function makePiRpcAdapter(id, label, binary) {
  return {
    id: id,
    label: label,
    supported: true,
    command: function() {
      return ["bash", "-lc", "exec " + binary + " --mode rpc --no-session"]
    },
    startCommands: function() {
      return [{ type: "get_state" }]
    },
    prompt: function(text, streaming) {
      var command = { type: "prompt", message: text }
      // A message sent while the agent is running is delivered as a steer
      // instead of being rejected.
      if (streaming) command.streamingBehavior = "steer"
      return command
    },
    abort: function() {
      return { type: "abort" }
    },
    cancelDialog: function(id) {
      return { type: "extension_ui_response", id: id, cancelled: true }
    },
    translate: piRpcTranslate
  }
}

var DIALOG_METHODS = ["select", "confirm", "input", "editor"]

function piRpcTranslate(raw) {
  var line = String(raw || "").trim()
  if (!line) return []

  var event = null
  try { event = JSON.parse(line) } catch (e) { return [] }
  if (!event || typeof event.type !== "string") return []

  switch (event.type) {
  case "response":
    return piRpcResponse(event)
  case "message_start":
    return (event.message && event.message.role === "assistant") ? [{ kind: "assistant_reset" }] : []
  case "message_update":
    return piRpcUpdate(event)
  case "message_end":
    return (event.message && event.message.role === "assistant")
      ? [{ kind: "assistant_end", text: extractText(event.message) }]
      : []
  case "tool_execution_start":
    return [{ kind: "tool", name: event.toolName || "tool", detail: toolSummary(event.args) }]
  case "agent_start":
    return [{ kind: "stream_start" }]
  case "agent_end":
    // A retry follows, so the run is not settled yet.
    return event.willRetry === true ? [] : [{ kind: "settled" }]
  case "agent_settled":
    return [{ kind: "settled" }]
  case "auto_retry_start":
    return [{ kind: "status", text: "retrying (" + event.attempt + "/" + event.maxAttempts + ")…" }]
  case "auto_retry_end":
    return event.success ? [{ kind: "status", text: "" }] : []
  case "extension_ui_request":
    return piRpcUi(event)
  case "extension_error":
    return [{ kind: "system", text: "Extension: " + (event.error || "") }]
  default:
    // `ready`, `available_commands_update`, queue updates, and anything a
    // future pi adds are safe to ignore.
    return []
  }
}

function piRpcResponse(event) {
  if (event.command === "get_state" && event.success && event.data && event.data.model) {
    return [{ kind: "model", name: String(event.data.model.name || event.data.model.id || "") }]
  }
  if (event.success === false) {
    return [{ kind: "error", text: event.error || "The agent rejected the command." }]
  }
  return []
}

function piRpcUpdate(event) {
  var delta = event.assistantMessageEvent
  if (!delta) return []
  if (delta.type === "text_delta") return [{ kind: "text", delta: delta.delta }]
  if (delta.type === "toolcall_start") return delta.toolName ? [{ kind: "status", text: delta.toolName + "…" }] : []
  if (delta.type === "toolcall_end") return [{ kind: "status", text: "" }]
  return []
}

function piRpcUi(event) {
  if (event.method === "notify") return [{ kind: "system", text: event.message || "" }]
  // A blocking dialog would hang the agent: the modal has no widget to answer
  // it, so it answers "cancelled" and says so.
  if (DIALOG_METHODS.indexOf(event.method) !== -1) {
    return [
      { kind: "dialog", id: event.id, method: event.method },
      { kind: "system", text: "Agent's \"" + event.method + "\" request answered as cancelled." }
    ]
  }
  return []
}

function extractText(message) {
  if (!message) return ""
  var content = message.content
  if (typeof content === "string") return content
  if (!Array.isArray(content)) return ""
  var out = ""
  for (var i = 0; i < content.length; i++) {
    var block = content[i]
    if (block && block.type === "text" && typeof block.text === "string") out += block.text
  }
  return out
}

function toolSummary(args) {
  if (!args) return ""
  if (typeof args === "string") return args
  try {
    if (args.command) return String(args.command)
    if (args.file_path) return String(args.file_path)
    if (args.path) return String(args.path)
    var serialized = JSON.stringify(args)
    return serialized.length > 120 ? serialized.slice(0, 117) + "…" : serialized
  } catch (e) {
    return ""
  }
}

// ------------------------------------------------------------------- agy

// Antigravity CLI (`agy`). One process runs every turn of the conversation:
// NDJSON user events on stdin, NDJSON events on stdout. `--input-format
// stream-json` implies print mode, so it must be paired with an explicit
// `--output-format stream-json`.
//
// Headless print mode cannot draw a permission prompt, so without the
// skip-permissions flag any tool that needs approval is auto-denied and the
// agent is left unable to do anything. The desktop launcher (`Super+A`,
// `omarchy-agent`) makes the same call, so the modal matches it.
function makeAgyAdapter(id, label, binary) {
  // Per-conversation state: a fresh process is spawned for every open(), and
  // command() is called first, so resetting here keeps turns independent.
  var state = { responseStep: -1 }

  return {
    id: id,
    label: label,
    supported: true,
    command: function() {
      state.responseStep = -1
      return ["bash", "-lc", "exec " + binary +
        " --dangerously-skip-permissions" +
        " --input-format stream-json --output-format stream-json" +
        " --print-timeout 30m"]
    },
    // No handshake: the first user event starts the conversation.
    startCommands: function() { return [] },
    prompt: function(text, streaming) {
      // agy has no steer concept; a message sent mid-run is queued and becomes
      // the next turn, so the streaming flag makes no difference here.
      return {
        event: "user",
        message: { role: "user", content: [{ type: "text", text: text }] }
      }
    },
    // Stream input only accepts user turns; there is no abort command.
    abort: function() { return null },
    cancelDialog: function() { return null },
    translate: function(raw) { return agyTranslate(raw, state) }
  }
}

function agyTranslate(raw, state) {
  var line = String(raw || "").trim()
  // agy also prints human notices on stdout (e.g. an auto-denied tool); only
  // JSON objects are protocol traffic.
  if (!line || line.charAt(0) !== "{") return []

  var event = null
  try { event = JSON.parse(line) } catch (e) { return [] }
  if (!event || typeof event.event !== "string") return []

  switch (event.event) {
  case "init":
    state.responseStep = -1
    return []
  case "step_update":
    return agyStep(event.step_update, state)
  case "result":
    return agyResult(event.result, state)
  default:
    return []
  }
}

function agyStep(step, state) {
  if (!step || typeof step.step_type !== "string") return []

  if (step.step_type === "agent_response") {
    if (typeof step.text_delta !== "string" || step.text_delta === "") return []
    // Each agent_response step is its own bubble, so a reply that follows a
    // tool run does not append to the previous one.
    var events = []
    if (step.step_index !== state.responseStep) {
      state.responseStep = step.step_index
      events.push({ kind: "assistant_reset" })
    }
    events.push({ kind: "text", delta: step.text_delta })
    return events
  }

  if (step.step_type === "tool") {
    // Only the ACTIVE transition starts a tool; the DONE one carries output
    // the modal has no place to put.
    if (step.state !== "ACTIVE") return []
    return [{ kind: "tool", name: step.tool_name || "tool", detail: agyToolSummary(step.tool_info) }]
  }

  // `user_input`, `error_message` (no message text), and any future step are
  // safe to ignore: the result event carries the turn's outcome.
  return []
}

function agyResult(result, state) {
  state.responseStep = -1
  var events = []
  var text = (result && typeof result.response === "string") ? result.response : ""
  if (text) {
    events.push({ kind: "assistant_end", text: text })
  } else if (result && result.status && result.status !== "SUCCESS") {
    // Only surface failures the agent could not recover from. agy reports a
    // transient API error here (and auto-retries) even when the turn still
    // produced a reply, so a non-empty response is treated as the outcome.
    events.push({ kind: "error", text: result.error || "The agent reported an error." })
  }
  events.push({ kind: "settled" })
  return events
}

function agyToolSummary(info) {
  var params = info && info.parameters
  if (!params || typeof params !== "object") return ""
  var preferred = ["CommandLine", "AbsolutePath", "TargetFile", "DirectoryPath", "Query", "query", "path", "file_path", "pattern"]
  for (var i = 0; i < preferred.length; i++) {
    if (params[preferred[i]] !== undefined && params[preferred[i]] !== null) return String(params[preferred[i]])
  }
  try {
    var serialized = JSON.stringify(params)
    return serialized.length > 120 ? serialized.slice(0, 117) + "…" : serialized
  } catch (e) {
    return ""
  }
}

// ------------------------------------------------------------- unsupported

// Agents with a real persistent protocol but a wire format the modal does not
// speak yet. Listed by name so the message can say what is missing rather than
// pretending the agent is unknown. A future adapter flips one of these to a
// `make...Adapter(...)` call.
var PENDING = {
  claude: "stream-json (bidirectional) — adapter TODO",
  codex: "app-server JSON-RPC — adapter TODO",
  copilot: "Agent Client Protocol (ACP) — adapter TODO",
  gemini: "Agent Client Protocol (ACP) — adapter TODO",
  opencode: "headless server / ACP — adapter TODO",
  hermes: "ACP / serve — adapter TODO",
  crush: "crush server socket — adapter TODO",
  grok: "streaming-messages-json + session resume — adapter TODO"
}

// Agents that stop at one-shot printing or a TUI, with no protocol to keep a
// conversation alive.
var ONE_SHOT = ["cursor-agent", "muse", "antigravity", "openclaw"]

function normalizeAgent(agent) {
  var name = String(agent || "").trim().toLowerCase()
  if (name === "oh-my-pi" || name === "ohmy pi") return "omp"
  if (name === "antigravity") return "agy"
  return name
}

function unsupportedAdapter(name) {
  var reason = "This modal speaks a persistent JSON protocol. "
  if (PENDING[name]) reason += "The adapter for \"" + name + "\" is not written yet (" + PENDING[name] + ")."
  else if (ONE_SHOT.indexOf(name) !== -1) reason += "\"" + name + "\" only offers one-shot printing or a TUI, so a back-and-forth conversation is not possible yet."
  else reason += "\"" + name + "\" is not supported yet."
  return {
    id: name || "unknown",
    label: name || "unknown",
    supported: false,
    reason: reason,
    command: function() { return [] },
    startCommands: function() { return [] },
    prompt: function() { return null },
    abort: function() { return null },
    cancelDialog: function() { return null },
    translate: function() { return [] }
  }
}

// --------------------------------------------------------------- registry

function adapterFor(agent) {
  var name = normalizeAgent(agent)
  switch (name) {
  case "pi":
    return makePiRpcAdapter("pi", "pi", "pi")
  case "omp":
    return makePiRpcAdapter("omp", "omp", "omp")
  case "agy":
    return makeAgyAdapter("agy", "agy", "agy")
  default:
    return unsupportedAdapter(name)
  }
}
