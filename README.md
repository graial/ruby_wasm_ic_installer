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
- **skips** it, saying so, if the target already has it: on `minimal`, when
  `ruby_wasm_ic_minimal` is in the lock and stands in for it (`stringio`,
  `strscan`, `date`); on `full`, when one of the extensions it links belongs
  to it (`json`, `psych`, `date`, `bigdecimal`, `openssl`, `zlib`, `stringio`
  and the rest: see [Linked gems](#linked-gems-on-full));
- opens only its `require_paths` (normally `lib/`);
- checks each file's **magic comment**. Every Release this Installer knows
  links every Ruby 3.3 encoding on both Builds, so any encoding Ruby knows is
  sent as written; a name Ruby does not know, or an encoding Ruby cannot read
  source in (UTF-16, UTF-32), is **refused**.

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

- in **`ic-interface.rb`**, the Installer's five Declarations and their types:

  ```ruby
  type :InstallFile,   record(path: Text, body: Blob)
  type :InstallSetup,  record(generation: Nat64, load_paths: Vec[Text])
  type :InstallCommit, record(gems: Vec[Text], setup: Opt[:InstallSetup])
  type :Installed,     record(running: Opt[Nat64], pending: Opt[Nat64], gems: Vec[Text], partial: Vec[Text],
                              load_paths: Vec[Text], running_paths: Vec[Text], protocol: Nat64,
                              build: Opt[Text], release: Opt[Text], load_failures: Vec[Text],
                              linked: Opt[Vec[Text]])
  update :install_put,    takes: [Vec[:InstallFile]], returns: Text
  update :install_commit, takes: [:InstallCommit],    returns: Text
  update :install_remove, takes: [Text],              returns: Text
  query  :install_verify, takes: [Vec[Text]],         returns: Vec[Text]
  query  :installed,      takes: [],                  returns: :Installed
  ```

- at the top of **`app.rb`** (after any shebang and magic comments), the
  `require` of the canister half, which defines those five methods and loads
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

## The target: Build and Release

What a gem needs depends on the module the canister runs: its **Build**
(`minimal` or `full`) and ruby_wasm_builder **Release**. Declare it in
`.ruby_wasm_ic_installer.yml`, in the icp project root (or `--config PATH`):

```yaml
build: full          # minimal | full
release: 0.15.0
verify: [roda, ruby_wasm_ic_rack]    # require names `verify` checks on the canister
strict: true         # refuse, not warn (see below); or --strict
```

Every key is optional. The target is resolved, highest first, from `--build`
and `--release`, this file, what the canister reports (`IC::BUILD` and
`IC::RELEASE`, set by ruby_wasm_builder from 0.14.0), and last the assumption
`minimal`, which prints a line saying so. A canister reporting Release `0.0.0`
runs a CI dry run's module, which is no Release: it sets no Release and shows
no transition. The file is the desired state and the canister the observed
one; the Installer keeps no state of its own, so a move from one Build or
Release to another shows as a **transition** line until the canister has been
upgraded.

**Known Releases.** This Installer knows ruby_wasm_builder 0.13.0 to 0.15.0,
which `status` shows. A target Release before 0.13.0 is an error. One newer
than 0.15.0 installs with a `warning:` that this gem's tables may be out of
date, which `--strict` turns into a refusal. The Installer's own version
number says nothing about which Releases it knows.

On the target, `install` and `status`:

- on `full`, skip the gems it links (below), and **refuse**
  `ruby_wasm_ic_minimal` by name ("remove it from the Gemfile: `full` links
  the real extensions") before anything is sent;
- refuse a gem version known to refuse the target (`ruby_wasm_ic_minimal`
  before 0.1.5 on `minimal`). `install` checks the lock;
  `status` checks what the pending and running setups would load.
- refuse any other compiled gem: add it to ruby_wasm_builder, not here.

The tables behind this are in this gem (`Rules`); a new row is a release.

### Linked gems on `full`

`full` links 26 C extensions, named by require name: `bigdecimal`,
`cgi/escape`, `continuation`, `coverage`, `date_core`, `digest` and
`digest/*`, `etc`, `fcntl`, `json/ext/generator`, `json/ext/parser`,
`monitor`, `nkf`, `objspace`, `openssl`, `pathname`, `psych`,
`rbconfig/sizeof`, `ripper`, `stringio`, `strscan`, `zlib`. Each maps to a
gem by its first segment (`json/ext/parser` to `json`), and `date_core` to
`date`; a locked gem of one of those names is skipped. Its Ruby half (`json.rb`,
`psych.rb` …) is Ruby 3.3.3's, shipped in the module.

Where the list comes from: the canister reports it (`IC::LINKED_EXTENSIONS`,
from builder 0.14.0) when it already runs the target's Build and Release, and
the Installer uses that, printing a **drift** line if it differs from this
gem's table. Otherwise, and that is the usual case when you send gems first,
the canister runs the old module, so the Installer uses its table.

**What loads is the module's version, not the lock's.** Skipping a locked
`json 2.9.1` gives the Application the `json` Ruby 3.3.3 ships, 2.7.1, and
`install` says so:

```
warning: json-2.9.1 is locked; full links json 2.7.1, which is what will load
note: monitor-0.3.0 is locked; full carries monitor as part of Ruby 3.3.3, not as a gem
```

The versions mirrored are ruby_wasm_builder's, from Ruby 3.3.3's default
gemspecs: `bigdecimal` 3.1.5, `cgi` 0.4.1, `date` 3.3.4, `digest` 3.1.1,
`etc` 1.4.3, `fcntl` 1.1.0, `json` 2.7.1, `nkf` 0.1.3, `openssl` 3.2.0,
`pathname` 0.3.0, `psych` 5.1.2, `stringio` 3.1.1, `strscan` 3.0.9, `zlib`
3.1.1. `monitor`, `objspace`, `coverage`, `ripper`, `continuation` and
`rbconfig` are part of Ruby there, not gems: a lock that pins one gets a
`note:`, as does a linked gem the canister reports that this table lacks.

**`--strict`** (or `strict: true`) turns each `warning:` into a refusal (exit
2, nothing sent), and refuses an **assumed** target too: one no flag, config
or canister report names. A `note:` never refuses.

**Gems first, then the module.** A new setup file takes effect at the next
upgrade, **whatever module that upgrade brings**: the canister half boots
`/data/setup.rb` as it finds it. So to move a canister to a new Release,
`install` first (to the canister still running the old one), then upgrade to
the new module. This is guaranteed and has a spec.

## Verifying a boot

The canister half wraps `require` and records each error that escapes an
outermost `require` from an installed gem (name, version, the error's first
line; at most 50 a boot). A gem's own `rescue LoadError` around an optional
require is nested, so it is not recorded; an Application that rescues
`LoadError` itself for a deliberately optional gem will see it listed.
`status` prints them as `load failure:`.

`verify` goes further: it calls `install_verify` (a query, so it changes
nothing) with the names in `verify:`, which `require`s each on the canister
and answers `ok` or the error. It takes names, never code. `verify-init`
writes a first list: the require name each locked gem's gemspec points at
(`autorequire`, else a file named for the gem under its `require_paths`),
from the gemspec's file list alone, with no gem code run; it names the gems it
found nothing for.

**What a `verify` call costs.** `install_verify` is one query, and a query
may spend 5 B instructions. A name the boot already loaded costs almost
nothing; one it did not pays for its first `require`, about 0.84 B for Rack
(ruby_wasm_builder's W47). A list naming several gems the boot did not load
can pass the limit, and that shows as a failed call, not a `FAIL` row: keep
`verify:` to what `app.rb` requires at boot, or split a long list across
config files run with `--config`.

`install --upgrade` sends, runs `icp deploy <canister> --mode upgrade`, and
verifies, exiting 1 if anything failed to load. A CI job can filter on
`Gemfile*` and pass `--upgrade` only then. `icp deploy` builds and installs
the project's module as well, so the new module lands in the same step.

## Commands

```
ruby_wasm_ic_installer install CANISTER [--lock Gemfile.lock] [--dry-run] [--upgrade] [icp options]
ruby_wasm_ic_installer status  CANISTER [icp options]
ruby_wasm_ic_installer verify  CANISTER [icp options]
ruby_wasm_ic_installer verify-init [--lock Gemfile.lock] [--yes]
ruby_wasm_ic_installer prune   CANISTER [--dry-run] [icp options]
ruby_wasm_ic_installer setup   APP_DIR  [--yes | --check]
```

`CANISTER` is the canister's name in your `icp.yaml`, or its principal. icp
options pass through to `icp canister call`: `-e/--environment`,
`-n/--network`, `--identity`, `--project-root` (icp's
`--project-root-override`) and `--icp PATH`. Other options: `--cache DIR`,
`--budget BYTES`, `--build`, `--release`, `--config PATH`, `--strict`.

An icp-cli error (a project that will not load, say, or a missing file icp
reads) is printed as icp-cli's own message under a header saying so, so it does
not look like an Installer fault.

Every call goes through `icp canister call <canister> <method> --args-file
<file> --args-format bin -o hex`, so it needs [icp-cli](https://cli.internetcomputer.org)
1.6 or later. The gem encodes and decodes its few Candid types itself; it
holds no keys and picks no network.

Exit status: 0 done, 1 refused (by the canister, or by `setup`'s questions) or
a verify that failed, 2 a usage error, a gem it cannot install, or a gem the
target refuses.

## Limits

- **Pure Ruby only.** A gem with a C extension reaches a canister only linked
  into its Base Module.
- **Gems from a gem server only;** a `git` or `path` source in the lock is
  refused.
- **A single file larger than one call** (about 2 MB) cannot be sent.
- **ruby_wasm_builder 0.13.0 or later.** For an older Base Module, use
  ruby_wasm_ic_installer 0.3.x.
- **The encoding check runs on your machine's Ruby,** which knows the same
  encodings as the canister's Ruby 3.3.
- **Two halves, one version.** The canister half is vendored into the
  Application, so it can be older than this gem. `installed` reports a
  `protocol` number (3 from 0.3.0). Against protocol 2 the Installer still
  installs, from its own table of linked extensions, and `status` asks you to
  re-run `setup`; against protocol 1 it still installs, says the canister half
  reports no Build and no load failures, and `verify` asks you to re-run
  `setup`.
- The canister keeps no content hash of what it holds yet: `installed` reports
  versions, not digests.

## Development

```bash
bundle install
bundle exec rake          # every spec on MRI, no network; fails below 95% line coverage

# to run e2e a local ic network must be running
E2E_BASE=<path-to-wasm-release>/ruby-3.3-wasm32-unknown-icp-<full-or-minimal>-<version>.wasm E2E_PACKER=$PWD/<path-to-packer>packer-<version> bundle exec rake e2e      # the end-to-end spec on a local icp-cli network

```

The specs run the real canister half on MRI over a temporary `/data`, behind
the same seam the command uses to call icp-cli, with real `.gem` files built
by the specs and a stand-in for ruby_wasm_builder's `IC`. The Candid encoder
is held byte for byte to what `@dfinity/didc` encodes for the same values
(`spec/fixtures/didc-vectors.json`).

`rake e2e` needs `E2E_BASE` (a published Base Module, 0.13.0 or later) and
`E2E_PACKER` (that Release's unpacked packer), icp-cli as `icp` or `E2E_ICP`,
and rubygems.org. It runs `setup` on a Roda Application, packs and deploys it,
installs Rack, Roda and the two `ruby_wasm_ic` gems from a real lock, upgrades,
serves a page through them, and checks that a second install sends nothing.
If icp-cli cannot fetch its network launcher, download it by tag from
`dfinity/icp-cli-network-launcher`'s releases and set
`ICP_CLI_NETWORK_LAUNCHER_PATH`.

## Versions

See [CHANGELOG.md](CHANGELOG.md): what each version changes, the builder
Releases it knows, and its protocol.

MIT licensed.
