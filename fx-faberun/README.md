# fx-faberun

This fork's `fx-faberun` branch is the official [vercel-labs/fx](https://github.com/vercel-labs/fx)
plus a short queue of patches, kept as commits on top of upstream `main`:

| Patch | Why | Upstream |
| --- | --- | --- |
| Report prompt cache reads from Chat Completions providers | DeepSeek and other OpenAI-compatible providers return cache counters fx dropped | [#1043](https://github.com/vercel-labs/fx/pull/1043) |
| Stop the skill walk at the repository when HOME is not above it | a workspace outside HOME made fx load skills from every directory up to `/` | [#1045](https://github.com/vercel-labs/fx/pull/1045) |
| Keep an fx-faberun build from upgrading itself to the official channel | the stable auto-upgrade would replace fx-faberun and drop its patches | fx-faberun only |
| Read credentials from `FX_AUTH_HOME` when it is set | Faberun runs each worker under a throwaway HOME, and fx refuses a linked credential file while a copy diverges on the first token refresh | fx-faberun only |

## Install

```sh
curl -fsSL https://github.com/feliperun/fx/releases/latest/download/install.sh | sh
```

`FX_INSTALL_DIR` picks the directory (default `~/.local/bin`), `FX_FABERUN_VERSION`
pins a tag, and `FX_FABERUN_ARCHIVE` installs a local archive. The installer
verifies the SHA-256 and refuses a build that is not fx-faberun.

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
