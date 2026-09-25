# fx flavor

This fork's `flavor` branch is the official [vercel-labs/fx](https://github.com/vercel-labs/fx)
plus a short queue of patches, kept as commits on top of upstream `main`:

| Patch | Why | Upstream |
| --- | --- | --- |
| Report prompt cache reads from Chat Completions providers | DeepSeek and other OpenAI-compatible providers return cache counters fx dropped | [#1043](https://github.com/vercel-labs/fx/pull/1043) |
| Stop the skill walk at the repository when HOME is not above it | a workspace outside HOME made fx load skills from every directory up to `/` | [#1045](https://github.com/vercel-labs/fx/pull/1045) |
| Keep a flavor build from upgrading itself to the official channel | the stable auto-upgrade would replace the flavor and drop its patches | flavor only |

## Install

```sh
curl -fsSL https://github.com/feliperun/fx/releases/latest/download/install.sh | sh
```

`FX_INSTALL_DIR` picks the directory (default `~/.local/bin`), `FX_FLAVOR_VERSION`
pins a tag, and `FX_FLAVOR_ARCHIVE` installs a local archive. The installer
verifies the SHA-256 and refuses a build that is not a flavor.

## Staying current

`.github/workflows/flavor.yml` runs every six hours: `flavor/sync.sh` rebases the
branch onto upstream `main`, the result is built and tested, and a moved branch is
force-pushed. A patch that conflicts opens an issue instead. When an upstream
pull request in `upstream-prs.txt` merges, the next rebase drops that patch on its
own, because the same change is already upstream.

Without GitHub Actions, `flavor/watch.sh` does one pass of the same work on an
operator's machine, and `flavor/watch-install.sh` schedules it every six hours
(launchd on macOS, cron on Linux). It notifies through `FX_FLAVOR_NOTIFY` only
when something changed: a conflict, failing patch tests, a new upstream version
or an upstream pull request that moved.

Releases are built only on a manual dispatch with `package: true`, versioned
`X.Y.Z-flavor.N`, and created as drafts. Publishing one is a human decision.
