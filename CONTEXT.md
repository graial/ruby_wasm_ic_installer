# ruby_wasm_ic_installer

Installs pure-Ruby gems into a deployed Ruby canister (packed by ruby_wasm_builder) through calls, so they live in the canister's `/data`, not in its packed Application.

## Language

### The module a canister runs

**Build**:
Which variant of ruby_wasm_builder's Base Module a canister runs: `minimal` or `full`.
_Avoid_: flavour, edition

**Release**:
The ruby_wasm_builder version a module was published as. `0.0.0` (a CI dry run's module) is not a Release.
_Avoid_: builder version

**Target**:
The Build and Release an install is for. When the module about to be installed has a Module record, the Target is what that record says, and every declared Build or Release must agree with it. Otherwise the Target is what the developer declared, or else what the canister reports, or else assumed `minimal`.
_Avoid_: environment, platform

**Module record**:
What a Base Module from Release 0.15.0 on records about itself, readable without booting it: its Build and Release, its Ruby, its Linked extensions with their gems and versions, and its encodings.
_Avoid_: manifest, build info, pack metadata

**Known Releases**:
The range of Releases, from oldest to newest, whose facts the Installer's tables were checked against. It is declared as data, and the Installer's own version number doesn't encode it. A Target below the oldest is refused. A Target above the newest gets a warning, which strict mode turns into a refusal.
_Avoid_: supported versions, compatible builders

**Transition**:
A Target that differs from the Build or Release the canister runs now, until the canister is upgraded.

**Linked extension**:
A C extension compiled into a Build's module, named by its require name (`json/ext/parser`, `date_core`). A gem whose name a linked extension maps to is a **linked gem**.
_Avoid_: built-in, bundled extension

**Built-in gem**:
A gem whose code is compiled into the Ruby a Build carries, not linked in as an extension, such as Prism 0.19.0. `require` finds it, but a locked version of the gem with a C extension is still refused, because it is a different gem from the one that would load.
_Avoid_: bundled gem, default gem (Ruby's own words for other things)

**Drift**:
A difference between the Installer's table of Linked extensions and the list a canister running the Target reports.

### What happens to a locked gem

**Skip**:
Leaving a locked gem unsent because the Target already has it: as a Linked gem, or through a Stand-in.

**Stand-in**:
A pure-Ruby replacement, shipped in `ruby_wasm_ic_minimal`, for a gem whose real version is a C extension a `minimal` module lacks.

**Refuse**:
Stopping an install, before anything is sent, because of a gem the canister cannot load.

### The two halves

**Canister half**:
The part of the Installer vendored into an Application, which runs on the canister and answers its calls.
_Avoid_: server side, on-chain half

**Boot outcome**:
How the Application's boot ended, as the Application itself reports it: *booted*, *failed* (with the error), or *unreported* when the Application doesn't report it.
_Avoid_: boot result, boot status, health

**Protocol**:
The version of the Canister half's interface, which `installed` reports. It can be older than the Installer, because the Canister half is vendored.
