# actions

GitHub Actions for [HappyProto](https://happyproto.at).

| Action | What it does |
| --- | --- |
| [`setup-hpy`](#setup-hpy) | Installs `hpy`, the HappyProto command line. |
| [`plugin-publish`](#plugin-publish) | Publishes a HappyView plugin release to the HappyProto registry. |

Both run on Linux and macOS runners. Pin the major version, e.g. `@v1`.

`hpy` has only alpha releases so far, so the examples below set the channel
to `alpha`. Drop that once `hpy` 1.0.0 is out.

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
    channel: alpha
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
    hpy-channel: alpha
```

| Input | Default | |
| --- | --- | --- |
| `version` | | Required. The plugin version to publish. |
| `credential` | | Required. Passed to `hpy` alone. |
| `working-directory` | `.` | Where `hpy.toml` and `manifest.json` are. |
| `wasm` | | The built module, relative to `working-directory`. Omitted, `hpy` finds it. |
| `wait` | `true` | Wait until the registry has copied the artifact. Still `pending` after two minutes is a warning, not a failure. |
| `dry-run` | `false` | Validate and print the record without publishing. |
| `skip-existing` | `true` | When the registry already has this version, succeed with a notice. Versions are immutable, so the existing one is not compared with this build. |
| `hpy-version`, `hpy-channel` | `latest`, `stable` | Which `hpy` to use. |
| `github-token` | `github.token` | Only for looking up `hpy` releases. |

Outputs: `published` (`true`/`false`), `uri`, `status`, `hpy-version`.

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
    hpy-channel: alpha
```

In a monorepo set up with `semantic-release-monorepo`, `new-release-version`
is the whole tag (`my-plugin-v1.2.0`), not the version: strip the prefix from
`new-release-git-tag` instead.

## Development

```sh
for t in test/*.test.sh; do bash "$t"; done   # unit tests
shellcheck -x setup-hpy/*.sh plugin-publish/*.sh test/*.sh
```

CI runs the unit tests, then the actions themselves on Ubuntu and macOS.
Releases are automatic on `main` from [Conventional Commits](https://www.conventionalcommits.org/)
(`fix:`, `feat:`, `feat!:`), and the major tag (`v1`) moves with each release.
