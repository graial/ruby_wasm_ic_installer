# Changelog

What each release of `ruby_wasm_ic_installer` changes, newest first. The
version number is the Installer's own: which ruby_wasm_builder Releases a
version knows is listed under **Known Releases**, not encoded in the number.
**Protocol** is the version of the canister half's interface. When it changes,
re-run `setup` and upgrade once.

## 0.5.0: 26 November 2026

Known Releases: 0.13.0 to 0.15.0. Protocol 4: `installed` adds `boot`.
Re-run `setup` and upgrade once.

- **The Boot outcome.** An Application can say how its boot ended by calling
  `RubyWasmIcInstaller::Canister.boot_finished(error)` once at its end, with
  nil when it booted. `status` and `verify` show `boot: booted` or `boot:
  failed <class>: <message>`.
- **Load failures read by it.** When the boot reported it booted, they're
  shown as `rescued during boot:` and don't fail `verify` or `install
  --upgrade`. When it reported failing, they're shown under the error as
  `before the failure:`, and the error is what fails. When it reports
  nothing, they count as before.
- **The recorder stops at `boot_finished`:** a failing `require` while
  answering a call is not the boot's.
- Against a protocol 3 canister half, `status` asks you to re-run `setup`.

## 0.4.1: 26 November 2026

Known Releases: 0.13.0 to 0.15.0. Protocol 3, unchanged.

- **Built-in gems:** a locked `prism` is refused on either Build with its own
  message. Ruby 3.3.3 has Prism 0.19.0 built in, which `require "prism"`
  loads, and the lock's version, a different gem with a C extension, can't
  replace it. Before, it got the general "add it to ruby_wasm_builder"
  refusal.
- **Every command works under a US-ASCII locale,** not only `setup`. The lock
  is read as UTF-8, and icp-cli's output is too, so a refusal naming a
  non-ASCII path no longer crashes the Installer. `-EUTF-8:UTF-8` isn't
  needed.

## 0.4.0: 26 November 2026

Known Releases: 0.13.0 to 0.15.0. Protocol 3, unchanged.

- **Known Releases.** The Installer declares the ruby_wasm_builder Releases its
  tables were checked against, and `status` shows them. A target Release
  before 0.13.0 is an error. One newer than 0.15.0 installs with a `warning:`
  that the tables may be out of date, which `--strict` turns into a refusal.
- **Releases before 0.13.0 are refused.** With them, the three-encoding rule
  and its magic-comment rewrites are gone: every Release from 0.13.0 links
  every Ruby 3.3 encoding, so files are sent as written. An encoding Ruby does
  not know, or cannot read source in (UTF-16, UTF-32), is still refused. For
  an older Base Module, use 0.3.x.
- **`ruby_wasm_ic_minimal` before 0.1.5 is refused on `minimal` whatever the
  Release,** including when it isn't declared.
- **Ruby 3.3.3, not 3.3.6,** in the `note:` for gems that are part of Ruby,
  and in the README. The mirrored gem versions were already 3.3.3's.
- **Fixed:** `setup` failed with `invalid byte sequence in US-ASCII` under a
  US-ASCII locale when `app.rb` or `ic-interface.rb` held a non-ASCII
  character. It reads them as UTF-8 now.
- The end-to-end spec runs on either Build (`E2E_BUILD`, or from
  `E2E_BASE`'s name), with a lock per Build.

## 0.3.1: 25 November 2026

Protocol 3. 0.3.0 was not published, and 0.3.1 includes it.

- **Fourteen mirrored versions** of the gems `full` links: `cgi` 0.4.1, `etc`
  1.4.3, `fcntl` 1.1.0, `pathname` 0.3.0 and `zlib` 3.1.1 join the nine from
  0.3.0.
- **Gems that are part of Ruby** (`monitor`, `objspace`, `coverage`,
  `ripper`, `continuation`, `rbconfig`) get a `note:` when a lock pins one,
  never a warning.

## 0.3.0: 25 November 2026 (not published)

Protocol 3: `installed` adds `linked`. Re-run `setup` and upgrade once.

- **Linked gems on `full`.** A locked gem that one of `full`'s 26 linked C
  extensions belongs to is skipped, not refused as compiled. The list comes
  from the canister (`IC::LINKED_EXTENSIONS`, builder 0.14.0) when it runs the
  target, with a `drift:` line if it differs from the Installer's table, and
  from the table otherwise.
- **Version warnings:** a lock pinning another version of a linked gem than
  `full` carries gets a `warning:`.
- **`--strict`** (or `strict: true`) refuses on any `warning:`, and on an
  assumed target, with exit 2 and nothing sent.
- **Magic comments keyed on the Release:** from 0.13.0, any encoding Ruby
  knows is sent as written.
- Release `0.0.0`, a CI dry run's module, counts as no Release.
- `build: full` with a Release before 0.13.0 is an error.

## 0.2.0: 12 November 2026

Protocol 2: `installed` adds `protocol`, `build`, `release` and
`load_failures`, and `install_verify` is new. Re-run `setup` and upgrade once.

- **The target:** a Build (`minimal` or `full`) and Release, from
  `--build` / `--release`, `.ruby_wasm_ic_installer.yml`, the canister's
  report, or else assumed `minimal`, with a line saying so. A move between
  targets shows as a `transition:` line until the upgrade.
- **On `full`,** `ruby_wasm_ic_minimal` is refused before anything is sent.
- **Refusals by target:** `install` refuses, and `status` reports, a gem
  version known to refuse the target (`ruby_wasm_ic_minimal` before 0.1.5 on
  `minimal` 0.13.0 or later).
- **Load failures:** the canister half records a gem whose `require` raised
  at boot, and `status` prints it. `verify` requires the config's `verify:`
  names on the canister. `verify` and `install --upgrade` exit 1 on any
  failure.
- icp-cli's own message is passed through when a call fails.

## 0.1.1: 29 October 2026

- **Three encodings, not twelve.** A `minimal` canister claims UTF-8, US-ASCII
  and ASCII-8BIT. The nine other names it lists have no encoding behind them,
  so a file whose magic comment names one is refused.

## 0.1.0: 28 October 2026

The first release.

- `install` sends a lock's pure-Ruby gems that the canister lacks, through
  calls, into `/data`, and writes the setup file last. The next upgrade loads
  them.
- `setup` wires the canister half into an Application. `status` reports what
  the canister holds, and `prune` removes versions no setup names.
- Gems with a C extension are refused. `ruby_wasm_ic_minimal`'s stand-ins are
  skipped. Magic comments naming an alias are rewritten.
