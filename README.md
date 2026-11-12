# actions

GitHub Actions for [HappyProto](https://happyproto.at).

| Action | What it does |
| --- | --- |
| [`setup-hpy`](#setup-hpy) | Installs `hpy`, the HappyProto command line. |
| [`plugin-publish`](#plugin-publish) | Publishes a HappyView plugin release to the HappyProto registry. |
| [`lexicon-publish`](#lexicon-publish) | Publishes a directory of atproto lexicons so a PDS can resolve them. |
| [`release-publish`](#release-publish) | Publishes a software release as `software.release.*` records in the publisher's own repo. |

All of them run on Linux and macOS runners. Pin the major version, e.g. `@v1`.

`hpy` has only prereleases so far, so the examples below set the channel to
`beta`. Drop that once `hpy` 1.0.0 is out.

## Credentials

Publishing acts as your atproto account. Sign in once on your own machine and
store what it prints as a repository secret, e.g. `HPY_CREDENTIAL`:

```sh
hpy registry login --export
```

The credential is a session of its own: signing out locally doesn't break CI,
and you can revoke it with `HPY_CREDENTIAL=… hpy registry logout` or from the
HappyView dashboard. If it expires or is revoked, publishing fails with
`your session has expired or was revoked`; export a new one.

## `setup-hpy`

```yaml
- uses: happyproto/actions/setup-hpy@v1
  with:
    channel: beta
```

| Input | Default | |
| --- | --- | --- |
| `version` | `latest` | An exact version (`1.0.0-alpha.2`), or `latest`. |
| `channel` | `stable` | `stable`, `beta` or `alpha`: which channel `latest` means. Channels are strict, as in `hpy` itself: `latest` on `alpha` is the newest alpha, never a newer stable. |
| `credential` | | Optional. Checked (a malformed secret fails here), never exported to later steps. |
| `github-token` | `github.token` | Only for looking up releases. |

Outputs: `version`, and `did` and `handle` when a credential was given.

## `plugin-publish`

Installs `hpy` (as `setup-hpy` does) and publishes the plugin in
`working-directory`. It does not build: build first.

```yaml
- uses: happyproto/actions/plugin-publish@v1
  with:
    version: 1.2.0
    credential: ${{ secrets.HPY_CREDENTIAL }}
    working-directory: plugins/my-plugin
    wasm: ../../target/wasm32-unknown-unknown/release/my_plugin.wasm
    hpy-channel: beta
```

| Input | Default | |
| --- | --- | --- |
| `version` | | Required. The plugin version to publish. |
| `credential` | | Required. Passed to `hpy` alone. |
| `working-directory` | `.` | Where `hpy.toml` and `manifest.json` are. |
| `wasm` | | The built module, relative to `working-directory`. Omitted, `hpy` finds it. |
| `track` | | `latest`, `beta` or `alpha`: the release track to publish to. Omitted, `hpy` uses its default. |
| `wait` | `true` | Wait until the registry has copied the artifact. Still `pending` after two minutes is a warning, not a failure. |
| `dry-run` | `false` | Validate and print the record without publishing. |
| `skip-existing` | `true` | When the registry already has this version, succeed with a notice. Versions are immutable, so the existing one is not compared with this build. |
| `hpy-version`, `hpy-channel` | `latest`, `stable` | Which `hpy` to use. |
| `github-token` | `github.token` | Only for looking up `hpy` releases. |

Outputs: `published` (`true`/`false`), `uri` (the version's AT URI, empty when
skipped or a dry run), `status` (the version's availability: `available` or
`pending`; for a skipped run, what the registry already reported), `hpy-version`.

### With semantic-release

Add [`semantic-release-export-data`](https://github.com/felipecrs/semantic-release-export-data)
to your release config, give the release step an `id`, and publish when it cut
a release:

```yaml
- id: release
  run: npx semantic-release
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
- if: steps.release.outputs.new-release-published == 'true'
  uses: happyproto/actions/plugin-publish@v1
  with:
    version: ${{ steps.release.outputs.new-release-version }}
    credential: ${{ secrets.HPY_CREDENTIAL }}
    hpy-channel: beta
```

In a monorepo set up with `semantic-release-monorepo`, `new-release-version`
is the whole tag (`my-plugin-v1.2.0`), not the version: strip the prefix from
`new-release-git-tag` instead.

## `lexicon-publish`

Publishes every lexicon under `lexicons-dir` as a `com.atproto.lexicon.schema`
record in one account's repo, with Bluesky's
[`goat`](https://github.com/bluesky-social/goat), adding new schemas and
updating changed ones. A PDS finds a lexicon through DNS: a TXT record at
`_lexicon.<authority>` names the DID whose repo holds it, so
`at.happyproto.registry.project` resolves through `_lexicon.registry.happyproto.at`.

`goat` skips an NSID whose DNS doesn't name the account and still succeeds, so
the action checks first: if any authority's record is missing or names another
DID, it fails and prints each TXT record to add.

```yaml
- uses: happyproto/actions/lexicon-publish@v1
  with:
    identifier: happyproto.at
    password: ${{ secrets.LEXICON_APP_PASSWORD }}
```

| Input | Default | |
| --- | --- | --- |
| `identifier` | | Required. Handle or DID of the account the lexicons belong to. |
| `password` | | An app password for that account. Not needed for a dry run. |
| `lexicons-dir` | `lexicons` | The lexicon files, laid out by NSID. |
| `include` | | NSID prefixes to publish, comma or newline separated. Empty publishes them all. |
| `exclude` | | NSID prefixes to leave out, applied after `include`. |
| `dry-run` | `false` | Check DNS and report what would change (`goat lex status`), without publishing. |
| `goat-version` | `0.2.6` | The `goat` release to use, checked against its published checksums. |

### Several accounts in one tree

When one tree holds lexicons for more than one account, run the action once per
account and split the tree with `include` and `exclude`. A prefix matches whole
segments: `dev.happyview` covers `dev.happyview.adminFull`, never
`dev.happyviewer.thing`. Only the selected lexicons are checked against DNS and
given to `goat`.

```yaml
- uses: happyproto/actions/lexicon-publish@v1
  with:
    identifier: happyproto.at
    exclude: dev.happyview
    password: ${{ secrets.LEXICON_APP_PASSWORD }}
- uses: happyproto/actions/lexicon-publish@v1
  with:
    identifier: happyview.dev
    include: dev.happyview
    password: ${{ secrets.HAPPYVIEW_DEV_LEXICON_APP_PASSWORD }}
```

## `release-publish`

Publishes one release as `software.release.*` records in the publishing
account's own repo, talking XRPC to its PDS with `curl`. It signs in with an
app password, never touches anyone else's repo, and never writes a blob.

```yaml
- uses: happyproto/actions/release-publish@v1
  with:
    identifier: happyview.dev
    publisher-did: did:plc:qneu5uamqs6cug7sjobbaexm
    password: ${{ secrets.RELEASE_APP_PASSWORD }}
    project: happyview
    version: ${{ steps.release.outputs.new-release-version }}
    repository: https://github.com/${{ github.repository }}.git
    commit: ${{ github.sha }}
    changelog-url: https://github.com/${{ github.repository }}/releases/tag/v${{ steps.release.outputs.new-release-version }}
    published-at: ${{ steps.published.outputs.at }}
    channels: |
      v2
      latest
    dry-run: false
```

For project `P`, version `V` and `published-at` `T` it writes, in this order:

| Record | Key | On a rerun |
| --- | --- | --- |
| `software.release.project` | `P` | Created if missing, otherwise left alone. |
| `software.release.manifest` | the TID of `T` | Immutable. Identical: skipped. Different: the action fails. |
| `software.release.version` | `P.V` | Immutable, as the manifest. It names the manifest by URI and CID. |
| `software.release.channel` | `P.<channel>` | Created, or moved to `V` with `swapRecord`, so a concurrent move fails instead of being overwritten. |

The manifest's key is a [TID](https://atproto.com/specs/tid) made from
`published-at` (microseconds since 1970, clock id 0), so the same release
always gets the same key. Take `published-at` from the release itself, such as
the GitHub release's `published_at`, never from the clock of the run.

A channel never moves backwards: when it already points at a version that is
newer by SemVer (`3.0.0` is newer than `3.0.0-beta.12`, `alpha.10` newer than
`alpha.9`), it is left there with a notice.

Every record is read and planned before anything is written. If an immutable
record differs from the plan, or a planned record holds a blob, the action
fails and writes nothing. Any XRPC error stops the run, naming the error; there
are no retries, so a rerun picks up where it stopped.

| Input | Default | |
| --- | --- | --- |
| `identifier` | | Required. Handle or DID of the publishing account. |
| `password` | | An app password for that account. Not needed for a dry run. |
| `publisher-did` | | The DID `identifier` must resolve to; anything else fails before a record is read. |
| `project` | | Required. The project name and the project record's key. |
| `version` | | Required unless `releases` is set. SemVer, with or without a leading `v`; no build metadata. |
| `repository` | | Required unless `releases` is set. The cloneable git URL the release was built from. |
| `commit` | | Required unless `releases` is set. The full 40-character SHA-1. |
| `tag` | `v<version>` | The git tag, recorded as `refs/tags/<tag>`. |
| `changelog-url` | | Left out of the version record when empty. |
| `published-at` | | Required unless `releases` is set. RFC 3339; gives the manifest's key. |
| `channels` | | Channel names, comma or newline separated. Empty writes no channel. |
| `releases` | | A path to a JSON file of releases to publish in one run; see [Many releases at once](#many-releases-at-once). |
| `pace` | `2` | Seconds to wait between writes. Not used in a dry run. |
| `dry-run` | `true` | Print every planned record and action (`create`, `skip`, `fail`, `move`, `skip-backwards`) from public reads, without signing in or writing. A planned `fail` fails the dry run too. |
| `plc-url` | `https://plc.directory` | Where `did:plc` documents are looked up. `did:web` uses `/.well-known/did.json`. |

Outputs:

- `version-uri`, `version-cid`: the version record, the last one for a batch.
  `version-cid` is empty on a dry run before the version exists.
- `published`: `true` when this run wrote any record.
- `count-written`: how many releases needed at least one record written.
  Always 0 on a dry run.
- `count-skipped`: how many releases were already published in full.

### Many releases at once

To backfill past releases in one job, write them to a JSON file and pass its
path as `releases`, leaving `version`, `repository`, `commit`, `tag`,
`changelog-url`, `published-at` and `channels` empty; setting any of them
alongside `releases` fails. Each entry takes those seven keys with the same
meanings, and `channels` may be a string or an array:

```json
[
  { "version": "2.17.3", "repository": "https://github.com/example/app.git",
    "commit": "…", "published-at": "2026-10-15T00:00:00Z" },
  { "version": "2.17.4", "repository": "https://github.com/example/app.git",
    "commit": "…", "published-at": "2026-11-12T00:00:00Z", "channels": ["v2", "latest"] }
]
```

Every entry is checked before the first request, including that no two share
a `published-at`, since that would give them one manifest key. The releases
are then published in the file's order with one session, `pace` seconds apart
between writes, under the same rules as a single release. Put the channels only
on the newest release of each line; older entries without channels only add
their manifest and version.

The run stops at the first release that fails, before writing anything for
it. The releases before it stay published, and a rerun skips them. A dry run
prints every release's plan and fails at the end if any would fail.

The action needs `bash`, `curl`, `jq`, `dig` and `python3`, which GitHub's
Ubuntu and macOS runners have.

## Development

```sh
for t in test/*.test.sh; do bash "$t"; done   # unit tests
shellcheck -x setup-hpy/*.sh plugin-publish/*.sh lexicon-publish/*.sh release-publish/*.sh test/*.sh
```

CI runs the unit tests, then the actions themselves on Ubuntu and macOS.
Releases are automatic on `main` from [Conventional Commits](https://www.conventionalcommits.org/)
(`fix:`, `feat:`, `feat!:`), and the major tag (`v1`) moves with each release.
