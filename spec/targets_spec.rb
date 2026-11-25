# frozen_string_literal: true

# The Installer reconciling the declared target (config, flags) with what the
# canister reports, on a minimal and on a full canister, in memory.
RSpec.describe RubyWasmIcInstaller::Installer do
  def lockfile(*gems)
    specs = gems.map { |n, v| "    #{n} (#{v})" }.join("\n")
    RubyWasmIcInstaller::Lockfile.new("GEM\n  remote: https://rubygems.org/\n  specs:\n#{specs}\n\nPLATFORMS\n  ruby\n\n" \
                                      "DEPENDENCIES\n  rack\n")
  end

  def build(config: RubyWasmIcInstaller::Config.empty, flags: {})
    described_class.new(runner: @canister, config: config, flags: flags,
                        gem_files: RubyWasmIcInstaller::GemFiles.new(cache: File.join(@dir, "cache"), fetcher: @factory.fetcher))
  end

  def config(text)
    path = File.join(@dir, "config.yml")
    File.write(path, text)
    RubyWasmIcInstaller::Config.read(path)
  end

  around do |ex|
    Dir.mktmpdir do |dir|
      @dir = dir
      @factory = GemFactory.new(File.join(dir, "gems"))
      @canister = InMemoryCanister.new(File.join(dir, "data").tap { Dir.mkdir(_1) })
      @factory.build("rack", "3.1.8", "lib/rack.rb" => "module Rack; end\n")
      @factory.build("stringio", "3.1.2", { "lib/stringio.rb" => "", "ext/s/extconf.rb" => "" }, extensions: ["ext/s/extconf.rb"])
      @factory.build("ruby_wasm_ic_minimal", "0.1.4", "lib/ruby_wasm_ic_minimal.rb" => "",
                     "lib/ruby_wasm_ic_minimal/standins/stringio.rb" => "")
      @factory.build("ruby_wasm_ic_minimal", "0.1.5", "lib/ruby_wasm_ic_minimal.rb" => "",
                     "lib/ruby_wasm_ic_minimal/standins/stringio.rb" => "")
      @factory.build("net-http", "0.4.0", "lib/net/http.rb" => "")
      @factory.build("active_support_like", "1.0.0", "lib/other.rb" => "")
      %w[2.9.1 2.7.1].each do |v|
        @factory.build("json", v, { "lib/json.rb" => "", "ext/json/ext/parser/extconf.rb" => "" },
                       extensions: ["ext/json/ext/parser/extconf.rb"])
      end
      @factory.build("monitor", "0.3.0", "lib/monitor.rb" => "")
      @factory.build("zlib", "3.1.1", { "ext/zlib/extconf.rb" => "", "lib/zlib.rb" => "" }, extensions: ["ext/zlib/extconf.rb"])
      @factory.build("eucgem", "1.0.0", "lib/eucgem.rb" => "# -*- coding: euc-jp -*-\nX = 1\n",
                     "lib/eucgem/bin.rb" => "# encoding: binary\n")
      ex.run
    end
  end

  describe "install on full" do
    let(:full) { config("build: full\nrelease: 0.13.0\n") }

    it "skips the linked stringio, not refusing it as a C extension, and says where the target came from" do
      report = build(config: full).install(lockfile(%w[rack 3.1.8], %w[stringio 3.1.2]))
      expect(report).to include("skip stringio-3.1.2: linked into the full module, so it is not sent",
                                "target: full 0.13.0 (build from #{full.path}, release from #{full.path})")
      expect(@factory.fetched).to eq(["rack-3.1.8"])
    end

    it "refuses ruby_wasm_ic_minimal by name before sending anything" do
      expect { build(config: full).install(lockfile(%w[rack 3.1.8], %w[ruby_wasm_ic_minimal 0.1.5])) }
        .to raise_error(described_class::Refused, /ruby_wasm_ic_minimal-0.1.5: .*remove it from the Gemfile/m)
      expect(@canister.calls.map(&:first)).to eq(["installed"])
    end

    it "still refuses other compiled gems, pointing at the builder" do
      @factory.build("nokogiri_like", "1.0.0", { "lib/n.rb" => "", "ext/e/extconf.rb" => "" },
                     extensions: ["ext/e/extconf.rb"])
      expect { build(config: full).install(lockfile(%w[nokogiri_like 1.0.0])) }
        .to raise_error(RubyWasmIcInstaller::GemFiles::Refused, /has to be added to ruby_wasm_builder/)
    end
  end

  describe "linked gems on full" do
    let(:full) { config("build: full\nrelease: 0.13.0\n") }

    it "skips every gem a linked extension maps to, not refusing it as compiled" do
      report = build(config: full).install(lockfile(%w[rack 3.1.8], %w[json 2.7.1], %w[zlib 3.1.1]))
      expect(report).to include("skip json-2.7.1: linked into the full module, so it is not sent",
                                "skip zlib-3.1.1: linked into the full module, so it is not sent")
      expect(@factory.fetched).to eq(["rack-3.1.8"])
    end

    it "warns when the locked version is not the one full links, and notes a gem full has as part of Ruby" do
      report = build(config: full).install(lockfile(%w[json 2.9.1], %w[monitor 0.3.0]))
      expect(report).to include("warning: json-2.9.1 is locked; full links json 2.7.1, which is what will load",
                                "skip monitor-0.3.0: linked into the full module, so it is not sent",
                                "note: monitor-0.3.0 is locked; full carries monitor as part of Ruby 3.3.6, not as a gem")
      expect(build(config: full).install(lockfile(%w[json 2.7.1], %w[zlib 3.1.1])).grep(/warning|note/)).to eq([])
    end

    it "refuses the version warning under --strict or strict: true, before anything is sent, and not the note" do
      lock = lockfile(%w[rack 3.1.8], %w[json 2.9.1])
      expect { build(config: full, flags: { strict: true }).install(lock) }
        .to raise_error(described_class::Refused, /refused \(strict\): nothing was sent:\n  json-2.9.1 is locked; full links json 2.7.1/)
      expect { build(config: config("build: full\nrelease: 0.13.0\nstrict: true\n")).install(lock) }
        .to raise_error(described_class::Refused)
      expect(@canister.calls.map(&:first).uniq).to eq(["installed"])
      expect(build(config: full, flags: { strict: true }).install(lockfile(%w[monitor 0.3.0]))).to include(match(/\Anote: monitor/))
    end

    it "uses the canister's list when it runs the target, and reports drift from the table" do
      @canister.build = "full"
      @canister.release = "0.13.0"
      @canister.linked = %w[stringio json/ext/parser json/ext/generator newext]
      report = build(config: full).install(lockfile(%w[rack 3.1.8], %w[json 2.7.1]))
      expect(report).to include("skip json-2.7.1: linked into the full module, so it is not sent",
                                "drift: the canister links newext, which this Installer's table lacks",
                                match(/\Adrift: this Installer's table has .*zlib, which the canister does not link\z/))
      expect(build(config: full).install(lockfile(%w[newext 1.0.0])))
        .to include("note: newext-1.0.0 is locked; full links newext, a version this Installer does not mirror")
      expect { build(config: full).install(lockfile(%w[zlib 3.1.1])) }
        .to raise_error(RubyWasmIcInstaller::GemFiles::Refused, /zlib-3.1.1 has a C extension/)
    end

    it "uses the table in a transition, when the canister's list is for the module it runs now" do
      @canister.build = "minimal"
      @canister.release = "0.13.0"
      @canister.linked = []
      report = build(config: full).install(lockfile(%w[json 2.7.1]))
      expect(report).to include("skip json-2.7.1: linked into the full module, so it is not sent")
      expect(report.grep(/drift/)).to eq([])
    end

    it "takes a dry run's module (release 0.0.0) as no Release: no transition, but its list counts on its Build" do
      @canister.build = "full"
      @canister.release = "0.0.0"
      @canister.linked = %w[json/ext/parser]
      report = build(config: full).install(lockfile(%w[rack 3.1.8]))
      expect(report.grep(/transition/)).to eq([])
      expect(report).to include(match(/\Adrift: this Installer's table has/))
      expect(build.status).to include("target: full (build from the canister)")
    end

    it "refuses full before Release 0.13.0, which had no full" do
      expect { build(config: config("build: full\nrelease: 0.12.0\n")).install(lockfile(%w[rack 3.1.8])) }
        .to raise_error(RubyWasmIcInstaller::Error, /`full` exists from ruby_wasm_builder 0.13.0/)
    end
  end

  describe "--strict and an assumed target" do
    it "refuses when nothing says what the target is" do
      expect { build(flags: { strict: true }).install(lockfile(%w[rack 3.1.8])) }
        .to raise_error(described_class::Refused, /refused \(strict\).*\n  the target is assumed/m)
      expect(build(config: config("build: minimal\n"), flags: { strict: true }).install(lockfile(%w[rack 3.1.8])))
        .to include(match(/\Asend rack-3.1.8/))
    end
  end

  describe "magic comments by Release" do
    it "sends files in any encoding Ruby knows, unrewritten, from 0.13.0" do
      report = build(config: config("build: minimal\nrelease: 0.13.0\n")).install(lockfile(%w[eucgem 1.0.0]))
      expect(report.grep(/rewrite/)).to eq([])
      expect(File.read(File.join(@canister.dir, "gems/eucgem-1.0.0/lib/eucgem/bin.rb"))).to eq("# encoding: binary\n")
    end

    it "keeps the three-encoding rule when the Release is unknown, and says how to lift it" do
      expect { build.install(lockfile(%w[eucgem 1.0.0])) }
        .to raise_error(RubyWasmIcInstaller::MagicComment::Refused, /declare `release:`/)
    end
  end

  describe "install on minimal" do
    it "assumes minimal with a printed line when nothing says otherwise, as 0.1.x did" do
      report = build.install(lockfile(%w[rack 3.1.8]))
      expect(report).to include(match(/\Atarget: minimal \(build from assumed: /))
    end

    it "refuses ruby_wasm_ic_minimal 0.1.4 for minimal 0.13.0 and sends nothing" do
      c = config("build: minimal\nrelease: 0.13.0\n")
      expect { build(config: c).install(lockfile(%w[rack 3.1.8], %w[ruby_wasm_ic_minimal 0.1.4])) }
        .to raise_error(described_class::Refused, /update it to 0.1.5/)
      expect(build(config: c).install(lockfile(%w[rack 3.1.8], %w[ruby_wasm_ic_minimal 0.1.5])))
        .to include(match(/\Asend rack-3.1.8/))
    end

    it "lets flags override the config" do
      c = config("build: minimal\nrelease: 0.12.0\n")
      report = build(config: c, flags: { build: "full", release: "0.13.0" }).install(lockfile(%w[rack 3.1.8]))
      expect(report).to include("target: full 0.13.0 (build from --build, release from --release)")
    end
  end

  describe "the transition" do
    it "is reported when the canister runs another Build or Release than the declared one" do
      @canister.build = "minimal"
      @canister.release = "0.12.0"
      report = build(config: config("build: full\nrelease: 0.13.0\n")).install(lockfile(%w[rack 3.1.8]))
      expect(report).to include("canister: protocol 3, build minimal, release 0.12.0",
                                "transition: the canister runs minimal 0.12.0; this is for full 0.13.0")
    end

    it "is not reported when they agree, or when the canister reports nothing" do
      @canister.build = "minimal"
      @canister.release = "0.13.0"
      expect(build(config: config("build: minimal\nrelease: 0.13.0\n")).install(lockfile(%w[rack 3.1.8])).grep(/transition/)).to eq([])
      expect(build(config: config("build: minimal\n")).install(lockfile(%w[rack 3.1.8])).grep(/transition/)).to eq([])
      @canister.build = nil
      @canister.release = nil
      expect(build.install(lockfile(%w[rack 3.1.8])).grep(/transition/)).to eq([])
    end

    it "uses what the canister reports as the target when nothing is declared" do
      @canister.build = "full"
      @canister.release = "0.13.0"
      expect(build.status).to include("target: full 0.13.0 (build from the canister, release from the canister)")
    end
  end

  describe "status" do
    it "shows the setup's gems that the target refuses" do
      build(config: config("build: minimal\nrelease: 0.12.0\n")).install(lockfile(%w[ruby_wasm_ic_minimal 0.1.4]))
      st = build(config: config("build: minimal\nrelease: 0.13.0\n")).status
      expect(st).to include(match(/\Arefuses minimal 0.13.0: ruby_wasm_ic_minimal-0.1.4: .*update it to 0.1.5/))
    end

    it "says so when the canister half is protocol 2, and still works" do
      @canister.protocol_two!
      expect(build.status).to include(match(/\Acanister half: protocol 2, which reports no linked extensions: re-run/))
      expect(build.install(lockfile(%w[rack 3.1.8]))).to include("setup generation 1 takes effect at the next upgrade")
    end

    it "says so when the canister half is protocol 1, and still works" do
      @canister.protocol_one!
      st = build.status
      expect(st).to include(match(/\Acanister half: protocol 1, which reports no Build and no load failures: run/))
      expect(build.install(lockfile(%w[rack 3.1.8]))).to include("setup generation 1 takes effect at the next upgrade")
    end

    it "lists the boot's load failures" do
      build.install(lockfile(%w[rack 3.1.8]))
      File.write(File.join(@canister.dir, "gems/rack-3.1.8/lib/rack.rb"), "raise LoadError, 'cannot load such file -- x'\n")
      @canister.upgrade!
      expect { require "rack" }.to raise_error(LoadError)
      expect(build.status).to include("load failure: rack-3.1.8: LoadError: cannot load such file -- x")
    end
  end

  describe "install --upgrade" do
    it "sends, deploys, then checks the boot and the verify list" do
      c = config("verify: [rack]\n")
      report = build(config: c).install(lockfile(%w[rack 3.1.8]), upgrade: true)
      expect(@canister.deploys).to eq(1)
      expect(report).to include("call icp deploy --mode upgrade", "ok rack")
      expect(report.last).to eq("upgraded: the boot loaded every gem and 1 verify names")
      expect(report).not_to include("upgrade the canister to load it (icp deploy --mode upgrade)")
    end

    it "upgrades even when there is nothing to send, and with no verify list" do
      build.install(lockfile(%w[rack 3.1.8]))
      report = build.install(lockfile(%w[rack 3.1.8]), upgrade: true)
      expect(report).to include("nothing to send: the canister has every locked gem and the setup file already names them")
      expect(report.last).to eq("upgraded: the boot loaded every gem")
    end

    it "fails with the report when a verify name fails" do
      expect { build(config: config("verify: [no_such_lib]\n")).install(lockfile(%w[rack 3.1.8]), upgrade: true) }
        .to raise_error(described_class::VerifyFailed) { |e|
          expect(e.lines).to include(match(/\AFAIL no_such_lib: LoadError/), "upgraded, but 1 failed")
        }
    end

    it "fails when the boot recorded a load failure" do
      @factory.build("bad", "1.0.0", "lib/bad.rb" => "raise LoadError, 'boom'\n")
      installer = build(config: config("verify: []\n"))
      installer.install(lockfile(%w[bad 1.0.0]))
      # The app's own `require` at boot, which the in-memory canister does not run.
      allow(@canister).to receive(:deploy).and_wrap_original do |m|
        m.call
        begin
          require "bad"
        rescue LoadError
          nil
        end
      end
      expect { installer.install(lockfile(%w[bad 1.0.0]), upgrade: true) }
        .to raise_error(described_class::VerifyFailed) { |e| expect(e.lines).to include("load failure: bad-1.0.0: LoadError: boom") }
    end

    it "does not deploy on a dry run" do
      build.install(lockfile(%w[rack 3.1.8]), dry_run: true, upgrade: true)
      expect(@canister.deploys).to eq(0)
    end
  end

  describe "verify" do
    it "requires the config's names on the canister" do
      build.install(lockfile(%w[rack 3.1.8]))
      @canister.upgrade!
      lines = build(config: config("verify: [rack]\n")).verify
      expect(lines).to eq(["ok rack", "verified: 1 require names, no load failures"])
    end

    it "fails, with the report, on a name that does not load" do
      expect { build(config: config("verify: [rack]\n")).verify }
        .to raise_error(described_class::VerifyFailed) { |e| expect(e.lines).to include(match(/\AFAIL rack: LoadError/), "1 failed") }
    end

    it "checks only the load failures when there is no list" do
      expect(build.verify).to eq(["no verify: list in .ruby_wasm_ic_installer.yml; checking the boot's load failures only",
                                  "verified: 0 require names, no load failures"])
    end

    it "asks for setup when the canister half is protocol 1" do
      @canister.protocol_one!
      expect { build.verify }.to raise_error(RubyWasmIcInstaller::Error, /protocol 1: run `ruby_wasm_ic_installer setup`/)
    end
  end

  describe "entry_points" do
    it "finds each gem's front door from its gemspec, leaves out what the target stands in for, and says what it cannot find" do
      found, unresolved = build.entry_points(lockfile(%w[rack 3.1.8], %w[net-http 0.4.0], %w[active_support_like 1.0.0],
                                                      %w[ruby_wasm_ic_minimal 0.1.5], %w[stringio 3.1.2]))
      expect(found).to match_array(%w[rack net/http ruby_wasm_ic_minimal])
      expect(unresolved).to eq(["active_support_like-1.0.0"])
    end

    it "uses a gem's autorequire when it sets one" do
      @factory.build("auto", "1.0.0", "lib/entry.rb" => "")
      path = File.join(@factory.dir, "server", "auto-1.0.0.gem")
      spec = Gem::Package.new(path).spec
      spec.autorequire = "entry"
      allow_any_instance_of(Gem::Package).to receive(:spec).and_return(spec)
      expect(build.entry_points(lockfile(%w[auto 1.0.0])).first).to eq(["entry"])
    end
  end
end

# The quickstart's gems-first ordering (ADR-0004): a new setup file takes
# effect at the next upgrade, whatever module that upgrade brings.
RSpec.describe "gems first, then a new module" do
  it "loads the gems sent under the old Release when the upgrade brings a new Build and Release" do
    Dir.mktmpdir do |dir|
      factory = GemFactory.new(File.join(dir, "gems"))
      factory.build("rack", "3.1.8", "lib/rack.rb" => "module Rack; end\n")
      canister = InMemoryCanister.new(File.join(dir, "data").tap { Dir.mkdir(_1) })
      canister.build = "minimal"
      canister.release = "0.10.0"
      installer = RubyWasmIcInstaller::Installer.new(
        runner: canister, gem_files: RubyWasmIcInstaller::GemFiles.new(cache: File.join(dir, "cache"), fetcher: factory.fetcher)
      )
      lock = RubyWasmIcInstaller::Lockfile.new("GEM\n  remote: https://rubygems.org/\n  specs:\n    rack (3.1.8)\n\n" \
                                               "PLATFORMS\n  ruby\n\nDEPENDENCIES\n  rack\n")
      installer.install(lock)
      canister.build = "full" # the new module
      canister.release = "0.13.0"
      canister.upgrade!
      expect(require("rack")).to be(true)
      expect(installer.status).to include("canister: protocol 3, build full, release 0.13.0")
    end
  end
end
