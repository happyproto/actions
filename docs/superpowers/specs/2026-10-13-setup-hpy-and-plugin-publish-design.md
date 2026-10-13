# `setup-hpy` and `plugin-publish` — design

Two GitHub Actions in `happyproto/actions`: one installs the `hpy` CLI, the
other publishes a HappyView plugin to the HappyProto registry with it. The
first consumer is `happyproto/plugins`, a monorepo whose plugins are released
by semantic-release.

## Goals

- A workflow can install a chosen `hpy` in one step, on Linux and macOS
  runners.
- A workflow can publish one plugin release to the registry in one step,
  given the version semantic-release just cut.
- `setup-hpy` stays usable on its own; `plugin-publish` wraps it, and both
  always run the same install code.
- The registry credential reaches only the step that needs it.

Not goals: Windows runners; building the plugin (the workflow already did);
a lexicon publisher (a later action in the same repo).

## Repository layout

```
setup-hpy/
  action.yml        thin wrapper: runs setup.sh
  setup.sh          resolve + install + verify (shared)
  resolve.sh        prints the hpy version for (version, channel, releases JSON)
plugin-publish/
  action.yml        runs ../setup-hpy/setup.sh, then publish.sh
  publish.sh        skip-if-present, then `hpy registry plugin publish`
test/
  resolve.test.sh   resolve.sh against canned GitHub API responses
  publish.test.sh   publish.sh against a stub `hpy` on PATH
.github/workflows/
  ci.yml            tests, then the actions themselves on real runners; release
.releaserc.json
README.md
```

Both actions are composite actions written in bash: there is no `dist/`
bundle to build and commit.

**Why a shared script rather than `uses:`.** A composite action's
`uses: ./setup-hpy` resolves against the *caller's* checkout, not this repo,
and `uses: happyproto/actions/setup-hpy@v1` could run a different ref of setup
than the `plugin-publish` that called it. So `plugin-publish` runs
`"${{ github.action_path }}/../setup-hpy/setup.sh"`, which is always the same
ref.

## `setup-hpy`

### Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `version` | `latest` | An exact `hpy` version (`1.0.0-alpha.2`, a leading `v` allowed), or `latest`. |
| `channel` | `stable` | `stable`, `beta` or `alpha` (`main` means `stable`): which channel `latest` means. Ignored with an exact version. |
| `credential` | — | Optional. An `HPY_CREDENTIAL` from `hpy registry login --export`. When given, it is checked, never exported. |
| `github-token` | `${{ github.token }}` | Used only for the GitHub API call that resolves `latest`, to avoid the anonymous rate limit. |

### Outputs

| Output | Meaning |
| --- | --- |
| `version` | The installed version, without `v`. |
| `did`, `handle` | Who the credential signs in as; empty without one. |

### Behaviour

1. **Resolve** (`resolve.sh`). An exact version is used as given, after
   stripping a leading `v`. `latest` fetches
   `GET /repos/happyproto/cli/releases?per_page=100`, skips drafts, parses
   each `tag_name` as semver, keeps those on the channel — the CLI's own
   strict rule: no prerelease is `stable`, `-beta.N` is `beta`, `-alpha.N` is
   `alpha`, anything else is no channel — and picks the highest. No release on
   the channel fails with `no <channel> release of hpy has been published`.
   An unknown channel fails naming the three.
2. **Install.** Downloads and runs
   `https://github.com/happyproto/cli/releases/download/v<version>/hpy-cli-installer.sh`
   with `HPY_CLI_NO_MODIFY_PATH=1`, then appends
   `${CARGO_HOME:-$HOME/.cargo}/bin` to `$GITHUB_PATH`. A 404 fails with
   `hpy <version> does not exist`.
3. **Verify.** `hpy --version` must print `hpy <version>`; otherwise fail,
   showing both. `HPY_NO_UPDATE_CHECK=1` is set for every `hpy` call.
4. **Credential** (only when given). `::add-mask::` it, then run
   `hpy registry whoami --json` with `HPY_CREDENTIAL` in that one command's
   environment. Failure fails the step with hpy's message. `whoami` only
   decodes the credential, without the network, so this catches a malformed
   or truncated secret; an expired or revoked session is caught by
   `plugin-publish`'s status check, the first call that reaches the
   registry. The `did` and `handle` outputs come from the JSON. The credential is not
   written to `$GITHUB_ENV`.

## `plugin-publish`

### Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `version` | — | Required. The plugin version to publish, e.g. semantic-release's `new-release-version`. |
| `credential` | — | Required. `HPY_CREDENTIAL`. |
| `working-directory` | `.` | The plugin's directory (where `hpy.toml` and `manifest.json` are). |
| `wasm` | — | Path to the built module, relative to `working-directory`. Omitted: hpy's own discovery. |
| `wait` | `true` | Wait until the registry has copied the artifact and the release is active. |
| `dry-run` | `false` | Validate and print the record without publishing. |
| `skip-existing` | `true` | When the registry already has this version, succeed with a notice instead of failing. |
| `hpy-version` | `latest` | Passed to setup as `version`. |
| `hpy-channel` | `stable` | Passed to setup as `channel`. |
| `github-token` | `${{ github.token }}` | Passed to setup. |

### Outputs

| Output | Meaning |
| --- | --- |
| `published` | `true` if this run published; `false` if skipped or a dry run. |
| `uri`, `status` | The release's AT URI, and its registry status (`registryStatus` in hpy's `--json`; empty without `wait`). |
| `hpy-version` | The `hpy` that ran. |

### Behaviour

1. Run setup with `hpy-version`, `hpy-channel` and `credential` (so a bad
   credential fails before anything else).
2. **Skip if present** (when `skip-existing` and not `dry-run`): run
   `hpy registry plugin status --json` (every version; asking for one that
   doesn't exist is an error) in `working-directory`. If the version is
   listed with registry status `active` or `pending`, emit
   `::notice::<slug> <version> is already in the registry; skipping`, set
   `published=false`, and stop. If it is in the repo with any other registry
   status (`not indexed`, `unknown`), fail: the record exists but the registry
   hasn't accepted it, and `hpy registry plugin status` is where to look.
   This call needs a live session, so it is also where an expired or revoked
   credential fails. (`status` reports no artifact checksum today,
   so a version published earlier from different bytes is also skipped; the
   notice says releases are immutable. Comparing checksums would need `status`
   to report them — a CLI follow-up, not part of this.)
3. **Publish:** in `working-directory`,
   `hpy registry plugin publish --no-input --yes --no-build --json --version <version>`
   plus `--wasm <wasm>` when given, `--wait` when `wait`, `--dry-run` when
   `dry-run`. `HPY_CREDENTIAL` is set in this command's environment only.
   Outputs come from the JSON. A failure fails the step with hpy's message.
   With `wait`, hpy gives up after two minutes and reports the last status
   seen; anything but `active` is a `::warning::` (the release is published
   and the registry will finish copying it), not a failure.
4. Write a job summary line: `Published <slug> <version> (<status>)`, or the
   skip/dry-run equivalent.

## Use in `happyproto/plugins`

semantic-release keeps cutting the GitHub release first; registry publishing
follows when a release was cut. Changes:

- `package.json` adds `semantic-release-export-data`.
- Each plugin's `.releaserc.json` adds `"semantic-release-export-data"` to
  `plugins`, so the release step gets `new-release-published` and
  `new-release-git-tag` outputs. `prepareCmd` keeps building the module and
  bumping `manifest.json`.
- **Not `new-release-version`.** `semantic-release-monorepo` and
  `release/package-paths.mjs` both hand every plugin's `generateNotes` a
  `nextRelease.version` replaced by the git tag (so release notes name the
  plugin), and `generateNotes` is where `semantic-release-export-data` reads
  it: `new-release-version` would be `happyview-sql-v1.2.0`. A step reads
  the version from `new-release-git-tag` instead, strips
  `happyview-<plugin>-v`, and fails unless it equals the version
  `prepareCmd` wrote to `manifest.json`.
- The `release` job's semantic-release step gets `id: release`, and a step
  follows it:

  ```yaml
  - uses: happyproto/actions/plugin-publish@v1
    if: steps.release.outputs.new-release-published == 'true'
    with:
      version: ${{ steps.version.outputs.version }}
      credential: ${{ secrets.HPY_CREDENTIAL }}
      working-directory: plugins/happyview/${{ matrix.plugin }}
      wasm: <the module semantic-release built, per plugin>
      hpy-channel: alpha
  ```

  The `.wasm` path differs per plugin (crate name, and `wasm32-wasip1` for the
  three interpreters). A step before it reads the path from the plugin's
  `.releaserc.json` — the `.wasm` asset `@semantic-release/github` already
  uploads — so there is one place that names it. A `release/` test asserts
  every plugin's `.releaserc.json` names exactly one `.wasm` asset and lists
  `semantic-release-export-data`.
- **Recovery.** If the registry publish fails after the GitHub release was
  cut, rerunning the job won't help: semantic-release finds nothing new. A
  `workflow_dispatch` workflow (`publish-plugin.yml`, inputs `plugin` and
  `version`) checks out tag `happyview-<plugin>-v<version>`, builds that
  plugin, and runs `plugin-publish` with the same inputs. `skip-existing`
  makes it safe to run twice.
- Repository secret `HPY_CREDENTIAL`: from `hpy registry login --export`,
  signed in as the account that owns the plugins' registry profiles.

## Releasing the actions

Same pattern as `happyview-actions`: on push to `main`, after CI passes,
semantic-release (conventional commits) tags `vX.Y.Z`, writes `CHANGELOG.md`,
creates the GitHub release, and the workflow force-moves the major tag
(`v1`). Consumers pin `@v1`. Commit messages are linted on pull requests.

## Testing

- **Unit (`test/*.test.sh`, plain bash, run in CI):**
  - `resolve.sh`: an exact version passes through (with and without `v`);
    `latest` on each channel picks the highest of that channel only; a newer
    stable never counts for `alpha`; drafts and non-semver tags are skipped;
    `-rc.1` is on no channel; no release on the channel fails with the message
    above; an unknown channel fails.
  - `publish.sh` with a stub `hpy` that records its arguments and plays back
    canned JSON: the flags passed for each input combination; an existing
    `active` version is skipped with `published=false`; `skip-existing: false`
    publishes anyway (and hpy's refusal fails the step); `dry-run` never
    checks status; the credential is in the publish command's environment and
    absent from `$GITHUB_ENV`.
- **Integration (CI jobs that use the actions from the checkout, on
  `ubuntu-latest` and `macos-latest`):** `setup-hpy` with `channel: alpha`
  (latest) and with an exact version, asserting `hpy --version` and the
  `version` output; a bogus `credential` makes the step fail
  (`continue-on-error` plus an assertion on the outcome); `plugin-publish`
  with `dry-run: true` against a fixture plugin in `test/fixture/` and a
  bogus credential fails at the credential check, before publishing.
  A real publish is not run in this repo's CI; the first one happens in
  `happyproto/plugins`.

## Decisions

- Bash composite actions over a bundled TypeScript action: the work is
  "download, run, check exit code", and there is nothing to bundle.
- GitHub release first, registry second, with a manual recovery workflow —
  chosen over a dry-run-first order to keep semantic-release's flow as it is.
- The credential is verified by setup but never exported; `plugin-publish`
  hands it to the one command that needs it.
- `channel` defaults to `stable`; `happyproto/plugins` sets `alpha` until hpy
  has a stable release.
