#!/usr/bin/env python3
"""MCP server that hands a task to the Claude Code CLI installed on this machine.

fx cannot use a Claude subscription directly: Anthropic does not allow third
party products to offer claude.ai login or its rate limits. This server never
sees a credential. It runs the operator's own `claude` in headless mode
(`claude -p --output-format stream-json`), so the work happens inside Claude
Code, under whatever login Claude Code already has.

One tool, `claude_code`:
  task             what Claude Code should do (required); sent on stdin
  session_id       continue an earlier run with --resume
  model            Claude Code model alias or id (opus, sonnet, ...)
  effort           low, medium, high, xhigh or max (--effort)
  max_turns        ceiling on Claude Code's turns for this call (--max-turns)
  cwd              absolute working directory; defaults to this process's
  permission_mode  acceptEdits (default), plan or execute. Headless
                   acceptEdits edits files but runs no command; plan neither
                   edits nor runs. execute runs bypassPermissions under this
                   file's PreToolUse policy hook: no write outside cwd and no
                   background process. Plain bypassPermissions is never
                   reachable from a tool call.
  context          lean (default) or full. Lean starts Claude Code without the
                   operator's settings, skills, MCP servers, hooks and slash
                   commands, with only the core file and shell tools; full
                   keeps all of them. Lean also drops the model chosen in
                   those settings: set CLAUDE_CODE_MCP_MODEL for a default.

Each tool Claude Code uses becomes an MCP progress notification, cancelling the
call terminates the run, and the result carries a status (done, quota_exhausted,
turn_limit, failed) and the session_id to continue.

The command shape, the lean preamble and the quota reading follow Faberun's
Claude harness (src/harnesses/claude), which measured them: about 65,000
uncached input tokens per trivial call with the ambient configuration against
about 4,300 with the lean flags.

Standard library only, so it runs wherever python3 does.
"""

import json
import os
import re
import shlex
import subprocess
import sys
import threading
import unicodedata
from datetime import datetime, timedelta, timezone

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - Python without zoneinfo
    ZoneInfo = None

SERVER_NAME = "claude-code"
SERVER_VERSION = "0.2.0"
DEFAULT_PROTOCOL = "2025-06-18"
TOOL_MODES = ("acceptEdits", "plan", "execute")
SERVER_PATH = os.path.realpath(__file__)
WRITE_FIELDS = {"Write": "file_path", "Edit": "file_path", "MultiEdit": "file_path", "NotebookEdit": "notebook_path"}
BACKGROUND_OUTPUT_TOOLS = ("BashOutput", "TaskOutput", "Monitor")
POLICY_MATCHER = "|".join(["Bash", *BACKGROUND_OUTPUT_TOOLS, *WRITE_FIELDS])
EFFORTS = ("low", "medium", "high", "xhigh", "max")
CONTEXTS = ("lean", "full")
LEAN_TOOLS = "Read,Edit,Write,Bash,Glob,Grep"
CLAUDE_BIN = os.environ.get("CLAUDE_CODE_MCP_BIN", "claude")
DEFAULT_MODE = os.environ.get("CLAUDE_CODE_MCP_PERMISSION_MODE", "acceptEdits")
DEFAULT_CONTEXT = os.environ.get("CLAUDE_CODE_MCP_CONTEXT", "lean")
# Lean context skips the operator's Claude Code settings, and with them the
# model they chose there, so the server can name its own default.
DEFAULT_MODEL = os.environ.get("CLAUDE_CODE_MCP_MODEL") or None
MAX_TURNS_CEILING = 500
STDERR_TAIL_BYTES = 4000
PROGRESS_TEXT_CHARS = 160

QUOTA_TEXT = re.compile(r"429|rate.?limit|usage limit|session limit|spend limit|limit exhausted|quota|too many requests", re.I)
ABSOLUTE_RESET = re.compile(r"reset(?:s| at| on)?\s+(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:?\d{2})?)", re.I)
WALL_CLOCK_RESET = re.compile(r"resets?(?:\s+at)?\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*\(([A-Za-z_]+(?:/[A-Za-z0-9_+-]+)+|UTC|GMT)\)", re.I)

TOOL = {
    "name": "claude_code",
    "title": "Claude Code",
    "description": (
        "Delegate one coding task to the Claude Code CLI installed on this machine, "
        "running under the user's own Claude login. Claude Code works in the given "
        "directory with its own tools and returns its final answer, a status and a "
        "session_id. Pass that session_id back to continue the same Claude Code "
        "conversation. Give the full task: Claude Code does not see this conversation. "
        "In the default acceptEdits mode it edits files but cannot run commands; verify "
        "its work yourself. Status quota_exhausted means the user's Claude plan hit its "
        "limit until reset_at; do not retry before then."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "task": {"type": "string", "minLength": 1, "description": "Complete instructions for Claude Code."},
            "session_id": {"type": "string", "minLength": 1, "description": "session_id from an earlier result, to continue that conversation."},
            "model": {"type": "string", "minLength": 1, "description": "Optional Claude Code model alias or id, such as opus or sonnet."},
            "effort": {"type": "string", "enum": list(EFFORTS), "description": "Optional reasoning effort for this run."},
            "max_turns": {"type": "integer", "minimum": 1, "maximum": MAX_TURNS_CEILING, "description": "Optional ceiling on Claude Code's turns for this call."},
            "cwd": {"type": "string", "minLength": 1, "description": "Absolute working directory. Defaults to the server's directory."},
            "permission_mode": {"type": "string", "enum": list(TOOL_MODES), "description": "acceptEdits edits files but runs no command; plan only reads and proposes; execute also runs commands, with writes confined to cwd and no background processes. Defaults to acceptEdits."},
            "context": {"type": "string", "enum": list(CONTEXTS), "description": "lean (default) skips the user's Claude Code settings, skills, MCP servers and hooks to save plan usage; full keeps them. Use full only when the task needs them."},
        },
        "required": ["task"],
        "additionalProperties": False,
    },
}

_write_lock = threading.Lock()
_runs_lock = threading.Lock()
_runs = {}  # request id (as JSON text) -> Popen


def send(message):
    data = json.dumps(message, ensure_ascii=False, separators=(",", ":"))
    with _write_lock:
        sys.stdout.write(data + "\n")
        sys.stdout.flush()


def respond(request_id, result=None, error=None):
    message = {"jsonrpc": "2.0", "id": request_id}
    if error is not None:
        message["error"] = error
    else:
        message["result"] = result
    send(message)


def tool_error(text):
    return {"content": [{"type": "text", "text": text}], "isError": True}


def shorten(text, limit=PROGRESS_TEXT_CHARS):
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def describe_tool_use(block):
    name = block.get("name") or "tool"
    data = block.get("input") or {}
    for key in ("command", "file_path", "path", "pattern", "url", "description", "prompt"):
        if isinstance(data.get(key), str):
            return f"{name}: {shorten(data[key], 120)}"
    return name


def policy_settings(workspace):
    """Inline --settings that wires this file as the PreToolUse policy hook."""
    hook = " ".join(shlex.quote(part) for part in (sys.executable, SERVER_PATH, "--hook", "--workspace", workspace))
    return json.dumps({"hooks": {"PreToolUse": [{"matcher": POLICY_MATCHER, "hooks": [{"type": "command", "command": hook}]}]}})


def build_command(args, workspace=None):
    mode = args.get("permission_mode") or DEFAULT_MODE
    command = [
        CLAUDE_BIN,
        "-p",
        "--output-format",
        "stream-json",
        "--verbose",
        "--permission-mode",
        "bypassPermissions" if mode == "execute" else mode,
    ]
    if mode == "execute":
        # bypassPermissions only ever travels with the policy hook. An explicit
        # --settings applies even when lean context drops every settings file.
        command += ["--settings", policy_settings(workspace or os.getcwd())]
    if args.get("session_id"):
        command += ["--resume", args["session_id"]]
    model = args.get("model") or DEFAULT_MODEL
    if model:
        command += ["--model", model]
    if args.get("effort"):
        command += ["--effort", args["effort"]]
    if args.get("max_turns"):
        command += ["--max-turns", str(args["max_turns"])]
    if (args.get("context") or DEFAULT_CONTEXT) == "lean":
        # An explicit --settings would still apply; --bare is avoided because it
        # also disables hooks a future tool policy needs.
        command += ["--disable-slash-commands", "--strict-mcp-config", "--setting-sources", "", "--tools", LEAN_TOOLS]
    return command


def validate(args):
    if not isinstance(args, dict):
        return "arguments must be an object"
    unknown = set(args) - set(TOOL["inputSchema"]["properties"])
    if unknown:
        return f"unknown arguments: {', '.join(sorted(unknown))}"
    if not isinstance(args.get("task"), str) or not args["task"].strip():
        return "task is required"
    for key in ("session_id", "model", "cwd"):
        if key in args and (not isinstance(args[key], str) or not args[key].strip() or args[key].startswith("-")):
            return f"{key} is not valid"
    for key, allowed in (("permission_mode", TOOL_MODES), ("effort", EFFORTS), ("context", CONTEXTS)):
        if key in args and args[key] not in allowed:
            return f"{key} must be one of {', '.join(allowed)}"
    if "max_turns" in args:
        value = args["max_turns"]
        if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= MAX_TURNS_CEILING:
            return f"max_turns must be an integer from 1 to {MAX_TURNS_CEILING}"
    if "cwd" in args and not (os.path.isabs(args["cwd"]) and os.path.isdir(args["cwd"])):
        return "cwd must be an existing absolute directory"
    return None


def assistant_text(event):
    message = event.get("message") or {}
    parts = [block.get("text", "") for block in message.get("content") or [] if isinstance(block, dict) and block.get("type") == "text"]
    return " ".join(part for part in parts if part).strip() or None


def quota_text(result_event, events):
    """The quota message a run stopped on, or None; mirrors Faberun's claudeQuotaText."""
    for event in events:
        if event.get("type") != "assistant":
            continue
        if event.get("error") != "rate_limit" and event.get("is_api_error_message") is not True:
            continue
        text = assistant_text(event)
        if text and QUOTA_TEXT.search(text):
            return text
    if result_event.get("terminal_reason") == "api_error" or result_event.get("is_error") is True:
        text = result_event.get("result")
        if not isinstance(text, str) and isinstance(result_event.get("error"), dict):
            text = result_event["error"].get("message")
        if isinstance(text, str) and QUOTA_TEXT.search(text):
            return text
    return None


def reset_at(message, now=None):
    """The instant a quota message names, as ISO 8601 UTC, or None."""
    now = now or datetime.now(timezone.utc)
    absolute = ABSOLUTE_RESET.search(message)
    if absolute:
        value = absolute.group(1).replace(" ", "T")
        if not re.search(r"(Z|[+-]\d{2}:?\d{2})$", value):
            value += "+00:00"
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc).isoformat()
        except ValueError:
            pass
    match = WALL_CLOCK_RESET.search(message)
    if not match or ZoneInfo is None:
        return None
    hour, minute = int(match.group(1)), int(match.group(2) or 0)
    meridiem = (match.group(3) or "").lower()
    if meridiem == "pm" and hour < 12:
        hour += 12
    if meridiem == "am" and hour == 12:
        hour = 0
    if hour > 23 or minute > 59:
        return None
    try:
        zone = ZoneInfo(match.group(4))
    except Exception:
        return None
    local_now = now.astimezone(zone)
    target = local_now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if target <= local_now:
        target += timedelta(days=1)
    return target.astimezone(timezone.utc).isoformat()


def outcome(final, events, session_id, returncode, stderr_tail):
    """Classify one finished run the way Faberun does: quota, turn limit, failure or done."""
    if final is None:
        return {"status": "failed", "text": f"Claude Code exited with status {returncode} before a result: {stderr_tail or 'no output'}", "error": True}
    quota = quota_text(final, events)
    if quota:
        when = reset_at(quota)
        text = f"Claude plan limit reached: {quota}" + (f" (resets at {when})" if when else "")
        return {"status": "quota_exhausted", "text": text, "error": True, "reset_at": when}
    if final.get("subtype") == "error_max_turns":
        return {"status": "turn_limit", "text": "Claude Code stopped at max_turns; continue with the same session_id to let it finish.", "error": True}
    result = final.get("result") if isinstance(final.get("result"), str) else ""
    if final.get("is_error") or returncode != 0:
        return {"status": "failed", "text": result or f"Claude Code exited with status {returncode}", "error": True}
    return {"status": "done", "text": result, "error": False}


def run_tool(request_id, args, progress_token):
    key = json.dumps(request_id)
    problem = validate(args)
    if problem:
        respond(request_id, tool_error(problem))
        return
    workspace = os.path.realpath(args.get("cwd") or os.getcwd())
    try:
        process = subprocess.Popen(
            build_command(args, workspace),
            cwd=workspace,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            start_new_session=True,
        )
    except FileNotFoundError:
        respond(request_id, tool_error(f"Claude Code CLI not found ({CLAUDE_BIN}). Install it and sign in with `claude`."))
        return
    with _runs_lock:
        _runs[key] = process

    def feed_task():
        # The task travels on stdin: no argv length limit, and it never shows in
        # the process table.
        try:
            process.stdin.write(args["task"])
            process.stdin.close()
        except (BrokenPipeError, OSError):
            pass

    stderr_chunks = []

    def drain_stderr():
        for chunk in process.stderr:
            stderr_chunks.append(chunk)
            while sum(len(c) for c in stderr_chunks) > STDERR_TAIL_BYTES and len(stderr_chunks) > 1:
                stderr_chunks.pop(0)

    threading.Thread(target=feed_task, daemon=True).start()
    stderr_thread = threading.Thread(target=drain_stderr, daemon=True)
    stderr_thread.start()

    steps = 0
    session_id = args.get("session_id")
    events = []
    final = None

    def progress(message):
        nonlocal steps
        steps += 1
        if progress_token is None:
            return
        send({
            "jsonrpc": "2.0",
            "method": "notifications/progress",
            "params": {"progressToken": progress_token, "progress": steps, "message": message},
        })

    for line in process.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        events.append(event)
        kind = event.get("type")
        if event.get("session_id"):
            session_id = event["session_id"]
        if kind == "system" and event.get("subtype") == "init":
            progress(f"Claude Code started ({event.get('model') or 'default model'})")
        elif kind == "assistant":
            for block in (event.get("message") or {}).get("content") or []:
                if block.get("type") == "tool_use":
                    progress(describe_tool_use(block))
                elif block.get("type") == "text" and block.get("text", "").strip():
                    progress(shorten(block["text"]))
        elif kind == "result":
            final = event

    process.wait()
    stderr_thread.join(timeout=2)
    with _runs_lock:
        cancelled = _runs.pop(key, None) is None
    if cancelled:
        return  # The client cancelled; MCP sends no response to a cancelled request.

    result = outcome(final, events, session_id, process.returncode, shorten("".join(stderr_chunks), 1200))
    footer = [f"status: {result['status']}"]
    if session_id:
        footer.append(f"session_id: {session_id}")
    if final and final.get("num_turns") is not None:
        footer.append(f"turns: {final['num_turns']}")
    structured = {
        "status": result["status"],
        "result": result["text"],
        "session_id": session_id,
        "num_turns": final.get("num_turns") if final else None,
    }
    if result.get("reset_at"):
        structured["reset_at"] = result["reset_at"]
    respond(request_id, {
        "content": [{"type": "text", "text": result["text"].rstrip() + "\n\n" + " · ".join(footer)}],
        "structuredContent": structured,
        "isError": result["error"],
    })


def cancel(request_id):
    key = json.dumps(request_id)
    with _runs_lock:
        process = _runs.pop(key, None)
    if process is None:
        return
    try:
        os.killpg(process.pid, 15)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, 9)
        except ProcessLookupError:
            pass


def handle(message):
    method = message.get("method")
    request_id = message.get("id")
    params = message.get("params") or {}
    if method is None:
        return  # a response to a request this server never sends
    if request_id is None:
        if method == "notifications/cancelled":
            cancel(params.get("requestId"))
        return
    if method == "initialize":
        respond(request_id, {
            "protocolVersion": params.get("protocolVersion") or DEFAULT_PROTOCOL,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        })
    elif method == "ping":
        respond(request_id, {})
    elif method == "tools/list":
        respond(request_id, {"tools": [TOOL]})
    elif method == "tools/call":
        if params.get("name") != TOOL["name"]:
            respond(request_id, error={"code": -32602, "message": f"unknown tool: {params.get('name')}"})
            return
        token = (params.get("_meta") or {}).get("progressToken")
        threading.Thread(
            target=run_tool,
            args=(request_id, params.get("arguments") or {}, token),
            daemon=True,
        ).start()
    else:
        respond(request_id, error={"code": -32601, "message": f"method not found: {method}"})


def normalized(path):
    return unicodedata.normalize("NFC", path)


def within(path, root):
    path, root = normalized(path), normalized(root)
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def reached_path(path):
    """Where a path lands once symlinks resolve, even when it does not exist yet."""
    head, tail = path, []
    while head and not os.path.exists(head):
        head, name = os.path.split(head)
        if not name:
            break
        tail.insert(0, name)
    return os.path.join(os.path.realpath(head or os.sep), *tail)


def policy_decision(workspace, payload):
    """The PreToolUse denial reason for one tool call, or None when it may run."""
    name = payload.get("tool_name") if isinstance(payload.get("tool_name"), str) else ""
    data = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    if name in BACKGROUND_OUTPUT_TOOLS or (name == "Bash" and data.get("run_in_background") is True):
        return "background tool invocation denied by the foreground-only policy; rerun the tool in the foreground and wait for it to finish"
    field = WRITE_FIELDS.get(name)
    if field is None:
        return None
    raw = data.get(field)
    if not isinstance(raw, str) or not raw:
        return None
    base = payload.get("cwd") if isinstance(payload.get("cwd"), str) and payload.get("cwd") else workspace
    declared = os.path.normpath(raw if os.path.isabs(raw) else os.path.join(base, raw))
    roots = {os.path.normpath(workspace), os.path.realpath(workspace)}
    if any(within(declared, root) for root in roots) and any(within(reached_path(declared), root) for root in roots):
        return None
    return f"write outside the working directory {workspace} denied by policy; write only inside it"


def run_hook(argv):
    """`--hook --workspace DIR`: decide one PreToolUse event read from stdin."""
    workspace = argv[argv.index("--workspace") + 1] if "--workspace" in argv else os.getcwd()
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    reason = policy_decision(workspace, payload if isinstance(payload, dict) else {})
    if reason:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}}))
    return 0


def main():
    if "--hook" in sys.argv[1:]:
        sys.exit(run_hook(sys.argv[1:]))
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            send({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
            continue
        if isinstance(message, dict):
            handle(message)
    with _runs_lock:
        pending = list(_runs.keys())
    for key in pending:
        cancel(json.loads(key))


if __name__ == "__main__":
    main()
