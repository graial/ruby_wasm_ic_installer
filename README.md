# ruby_wasm_ic_installer

Install pure-Ruby gems into a Ruby canister on the Internet Computer, through
calls, after it is deployed: the **Installer** for canisters packed by
[ruby_wasm_builder](https://gitlab.com/phrug/ruby_wasm_builder).

A packed Application carries its code in a 1 MiB buffer. Gems installed with
this gem live in the canister's `/data` instead, so neither the buffer nor the
module's size bounds them: Rack and Roda whole are 224 files and 1.1 MB, sent
in one or a few calls, and the canister boots them within 2% of the same
Application packed (measured on PocketIC; ruby_wasm_builder's W28).

```bash
ruby_wasm_ic_installer setup my_app        # once: wire the Installer into the Application
# pack and deploy my_app as usual (pack.rb, icp deploy)
ruby_wasm_ic_installer install my_app      # send the Gemfile.lock's gems the canister lacks
icp deploy --mode upgrade                  # they load at the next boot
```

## What it does

**Off chain,** `install` reads the Application's `Gemfile.lock` with Bundler's
own parser (it resolves nothing: the lock is yours) and, for each locked gem:

- fetches its `.gem` for platform `ruby` with `gem fetch` into a cache
  (`~/.cache/ruby_wasm_ic_installer`), checking it against the lock's
  `CHECKSUMS` when the lock has them;
- **refuses** it if it has a C extension, or is locked only for a native
  platform: a canister cannot load compiled code, so only pure Ruby can be
  installed;
- **skips** it, saying so, if `ruby_wasm_ic_minimal` is in the lock and stands
  in for it (`stringio`, `strscan`, `date`), since the real ones are C
  extensions;
- opens only its `require_paths` (normally `lib/`);
- **rewrites magic comments** naming an alias of an encoding a `minimal`
  canister claims (`# encoding: binary` to `ascii-8bit`, `ascii` to
  `us-ascii`), and **refuses** a file in any other encoding (`ISO-8859-1`,
  `Shift_JIS`, `EUC-JP`, `UTF-16LE`). A canister claims three encodings,
  UTF-8, US-ASCII and ASCII-8BIT, each by one name and no alias, and reads the
  comment before any Ruby runs. It lists nine more names (the UTF-16 and
  UTF-32 family, UTF8-MAC, EUC-JP, Windows-31J) with no encoding behind them:
  a file whose comment names one would load as ASCII-8BIT, so it is refused
  too. Every rewrite is in the report.

It asks the canister what it has (`installed`), and sends **only the gem
versions it lacks**, packed into calls of up to 2,000,000 bytes (the IC's
ingress limit is 2 MiB). Then it writes the canister's **setup file**, last.
Nothing changes what the canister runs until the **next upgrade**, which loads
the new setup file; `install` says so and does not upgrade for you.

**On the canister,** the canister half keeps one directory per gem version:

```
/data/gems/<name>-<version>/lib/...       a complete version
/data/gems/.partial/<name>-<version>/     a version still arriving
/data/setup.rb                            the setup file: a generation number and the load paths
```

A version arrives into `.partial` and is renamed into place when complete, so
a run that stops half way leaves nothing half-installed (the next run clears
it and sends the version again). The setup file puts each gem's load path on
`$LOAD_PATH` at boot, in the lock's order, after `/app` (so anything you pack
still wins) and before Ruby's own library.

**Removing** a version is never automatic. `prune` removes every version that
neither the running boot nor the pending setup file names; the canister
refuses to remove one that either needs (Rack loads files lazily, through
`autoload`, long after boot). Until you prune, you can go back by installing
the previous lock again.

**Only the canister's controllers** may install, commit or remove: the
canister asks the IC whether the caller is one. `--identity` chooses who signs;
whoever can upgrade the canister can install code into it, and no one else.
`installed` is a public query: anyone can read which generation runs and which
gem versions are there.

## Wiring it into an Application: `setup`

```bash
ruby_wasm_ic_installer setup my_app [--yes | --check]
```

`setup` makes three changes, each between marker comments
(`# >>> ruby_wasm_ic_installer` … `# <<< ruby_wasm_ic_installer`):

- in **`ic-interface.rb`**, the Installer's four Declarations and their types:

  ```ruby
  type :InstallFile,   record(path: Text, body: Blob)
  type :InstallSetup,  record(generation: Nat64, load_paths: Vec[Text])
  type :InstallCommit, record(gems: Vec[Text], setup: Opt[:InstallSetup])
  type :Installed,     record(running: Opt[Nat64], pending: Opt[Nat64], gems: Vec[Text], partial: Vec[Text],
                              load_paths: Vec[Text], running_paths: Vec[Text])
  update :install_put,    takes: [Vec[:InstallFile]], returns: Text
  update :install_commit, takes: [:InstallCommit],    returns: Text
  update :install_remove, takes: [Text],              returns: Text
  query  :installed,      takes: [],                  returns: :Installed
  ```

- at the top of **`app.rb`** (after any shebang and magic comments), the
  `require` of the canister half, which defines those four methods and loads
  `/data/setup.rb` if there is one;
- the canister half itself, copied to **`vendor/ruby_wasm_ic_installer/`**.
  It uses only core Ruby and ruby_wasm_builder's `IC`, and loads on `minimal`.

Running it again changes nothing. If the lines between the markers, or the
vendored file, differ from what `setup` would write (your edit, or an older
version's), it shows the diff and asks before writing; with no terminal it
aborts unless `--yes`. If the Installer's names are already declared or
defined outside the markers, it stops and shows where. `--check` prints the
diffs and exits 1 if anything would change (for CI).

The Application needs an `ic-interface.rb` already (one with no Interface file
is served `run` alone). Pack and deploy it again after `setup`.

Then require your installed gems in `app.rb` as usual, after the Installer's
block. Before the first install and upgrade they are not there yet, so an
Application that should boot either way rescues `LoadError`:

```ruby
APP = begin
  require "ruby_wasm_ic_minimal"   # first, on minimal: the Encoding constants and stand-ins
  require "ruby_wasm_ic_rack"
  require "roda"
  # ... your Roda app ...
rescue LoadError
  nil
end
```

## Commands

```
ruby_wasm_ic_installer install CANISTER [--lock Gemfile.lock] [--dry-run] [icp options]
ruby_wasm_ic_installer status  CANISTER [icp options]
ruby_wasm_ic_installer prune   CANISTER [--dry-run] [icp options]
ruby_wasm_ic_installer setup   APP_DIR  [--yes | --check]
```

`CANISTER` is the canister's name in your `icp.yaml`, or its principal. icp
options pass through to `icp canister call`: `-e/--environment`,
`-n/--network`, `--identity`, `--project-root` (icp's
`--project-root-override`) and `--icp PATH`. Other options: `--cache DIR`,
`--budget BYTES`.

Every call goes through `icp canister call <canister> <method> --args-file
<file> --args-format bin -o hex`, so it needs [icp-cli](https://cli.internetcomputer.org)
1.6 or later. The gem encodes and decodes its few Candid types itself; it
holds no keys and picks no network.

Exit status: 0 done, 1 refused (by the canister, or by `setup`'s questions),
2 a usage error or a gem it cannot install.

## Limits

- **Pure Ruby only.** A gem with a C extension reaches a canister only linked
  into its Base Module.
- **Gems from a gem server only;** a `git` or `path` source in the lock is
  refused.
- **A single file larger than one call** (about 2 MB) cannot be sent.
- **Three encodings:** UTF-8, US-ASCII and ASCII-8BIT, the ones a `minimal`
  canister claims (ruby_wasm_builder's ADR-0053; the other nine names it lists
  were probed on 0.8.0 and are names only, W30). A Build that links encodings
  is a release of this gem.
- The canister keeps no content hash of what it holds yet: `installed` reports
  versions, not digests.

## Development

```bash
bundle install
bundle exec rake          # every spec on MRI, no network; fails below 95% line coverage
bundle exec rake e2e      # the end-to-end spec on a local icp-cli network
```

The specs run the real canister half on MRI over a temporary `/data`, behind
the same seam the command uses to call icp-cli, with real `.gem` files built
by the specs and a stand-in for ruby_wasm_builder's `IC`. The Candid encoder
is held byte for byte to what `@dfinity/didc` encodes for the same values
(`spec/fixtures/didc-vectors.json`).

`rake e2e` needs `E2E_BASE` (a published Base Module, 0.8.0 or later) and
`E2E_PACKER` (that Release's unpacked packer), icp-cli as `icp` or `E2E_ICP`,
and rubygems.org. It runs `setup` on a Roda Application, packs and deploys it,
installs Rack, Roda and the two `ruby_wasm_ic` gems from a real lock, upgrades,
serves a page through them, and checks that a second install sends nothing.
If icp-cli cannot fetch its network launcher, download it by tag from
`dfinity/icp-cli-network-launcher`'s releases and set
`ICP_CLI_NETWORK_LAUNCHER_PATH`.

## Versions

- **0.1.0:** the first release.

MIT licensed.
