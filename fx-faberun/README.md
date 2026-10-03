# fx-faberun

This fork's `fx-faberun` branch is the official [vercel-labs/fx](https://github.com/vercel-labs/fx)
plus a short queue of patches, kept as commits on top of upstream `main`:

| Patch | Why | Upstream |
| --- | --- | --- |
| Report prompt cache reads from Chat Completions providers | DeepSeek and other OpenAI-compatible providers return cache counters fx dropped | [#1043](https://github.com/vercel-labs/fx/pull/1043) |
| Stop the skill walk at the repository when HOME is not above it | a workspace outside HOME made fx load skills from every directory up to `/` | [#1045](https://github.com/vercel-labs/fx/pull/1045) |
| Keep an fx-faberun build from upgrading itself to the official channel | the stable auto-upgrade would replace fx-faberun and drop its patches | fx-faberun only |
| Read credentials from `FX_AUTH_HOME` when it is set | Faberun runs each worker under a throwaway HOME, and fx refuses a linked credential file while a copy diverges on the first token refresh | fx-faberun only |
| List every connection's models in `/model` | the picker only showed the active connection, so reaching GLM, DeepSeek, OpenCode Go or Codex meant restarting with `FX_PROVIDER`. Other connections appear as `connection/model` rows (profile `model_metadata` for configured ones, the live catalog for a signed-in Codex) and choosing one switches to it. A configured connection may set `session_header` (OpenCode Go needs `x-opencode-session`) to receive the fx session id in that header | fx-faberun only |
| Offer each model's own reasoning levels after choosing it in `/model` | GLM, DeepSeek, Codex and OpenCode Go accept different levels, and fx never sent one to a configured connection. A model lists its levels in `model_metadata.<id>.reasoning_efforts`, either by name (sent as `reasoning_effort`) or as `{"name": "off", "body": {"thinking": {"type": "disabled"}}}` with its own request fields. Levels a service reports in its `/models` (DeepSeek's `effort.supported_levels`) are added after the declared ones when the picker opens | fx-faberun only |
| Let a Chat Completions turn call a tool the request did not advertise | GLM, DeepSeek and OpenCode Go failed the whole turn with `InvalidToolName` when the model called an MCP tool whose selection lapsed with the previous turn. A well-formed name now reaches the dispatcher, as on the Gateway and Codex routes | fx-faberun only |

## Install

```sh
curl -fsSL https://github.com/feliperun/fx/releases/latest/download/install.sh | sh
```

`FX_INSTALL_DIR` picks the directory (default `~/.local/bin`), `FX_FABERUN_VERSION`
pins a tag, and `FX_FABERUN_ARCHIVE` installs a local archive. The installer
verifies the SHA-256 and refuses a build that is not fx-faberun.


## Claude Code from inside fx

fx cannot sign in with a Claude subscription: Anthropic does not allow third party
products to offer claude.ai login or its rate limits. `claude-code-mcp/` is a small
MCP server that hands a task to the Claude Code CLI already installed and signed in
on the machine, so the work runs inside Claude Code under its own login and fx never
sees a credential.

```sh
fx mcp add claude-code python3 "$PWD/fx-faberun/claude-code-mcp/claude_code_mcp.py"
```

Then raise `operation_timeout_ms` for `claude-code` in `~/.fx/mcp.json` (the default
60 seconds ends most real tasks; 3600000 allows an hour). The model calls
`claude_code` with a `task` (sent on stdin), and optionally `session_id` to continue
an earlier run, `model`, `effort`, `max_turns`, `cwd`, `permission_mode` and `context`.
The result carries a `status`: `done`, `quota_exhausted` with the `reset_at` instant
the plan names, `turn_limit` (continue with the same `session_id`), or `failed`.

Headless `acceptEdits`, the default, edits files but runs no command; `plan` neither
edits nor runs. `execute` runs Claude Code with `bypassPermissions` under a PreToolUse
hook the server wires inline: it denies `Write`, `Edit` and `NotebookEdit` outside
`cwd` (symlinks resolved) and any background process, as Faberun's tool policy does.
A write made through the shell is not intercepted. Plain `bypassPermissions` is not
reachable from a tool call. `context`
defaults to `lean`, which starts Claude Code without the operator's settings, skills,
MCP servers, hooks and slash commands: a trivial call measured 7,082 input tokens
lean against 34,766 with the full configuration. Lean also drops the model chosen in
those settings, so set `CLAUDE_CODE_MCP_MODEL` in the server's `env` for a default.
The command shape, the lean flags and the quota reading follow Faberun's Claude
harness.

## Staying current

`.github/workflows/fx-faberun.yml` runs every six hours: `fx-faberun/sync.sh` rebases the
branch onto upstream `main`, the result is built and tested, and a moved branch is
force-pushed. A patch that conflicts opens an issue instead. When an upstream
pull request in `upstream-prs.txt` merges, the next rebase drops that patch on its
own, because the same change is already upstream.

Without GitHub Actions, `fx-faberun/watch.sh` does one pass of the same work on an
operator's machine, and `fx-faberun/watch-install.sh` schedules it every six hours
(launchd on macOS, cron on Linux). It notifies through `FX_FABERUN_NOTIFY` only
when something changed: a conflict, failing patch tests, a new upstream version
or an upstream pull request that moved.

Releases are built only on a manual dispatch with `package: true`, versioned
`X.Y.Z-faberun.N`, and created as drafts. Publishing one is a human decision.
