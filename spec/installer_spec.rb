# frozen_string_literal: true

# The off-chain half against the canister half, in memory (W29, Q8 to Q11):
# real .gem files, a real Gemfile.lock, the real canister half over a
# temporary /data, joined at the Runner seam.
RSpec.describe RubyWasmIcInstaller::Installer do
  def lockfile(*gems)
    specs = gems.map { |n, v| "    #{n} (#{v})" }.join("\n")
    RubyWasmIcInstaller::Lockfile.new("GEM\n  remote: https://rubygems.org/\n  specs:\n#{specs}\n\nPLATFORMS\n  ruby\n\n" \
                                      "DEPENDENCIES\n  roda\n")
  end

  around do |ex|
    Dir.mktmpdir do |dir|
      @factory = GemFactory.new(File.join(dir, "gems"))
      @canister = InMemoryCanister.new(File.join(dir, "data").tap { Dir.mkdir(_1) })
      @installer = described_class.new(runner: @canister,
                                       gem_files: RubyWasmIcInstaller::GemFiles.new(cache: File.join(dir, "cache"),
                                                                                     fetcher: @factory.fetcher))
      @factory.build("rack", "3.1.8", "lib/rack.rb" => "module Rack; VERSION = '3.1.8'; end\n",
                                      "lib/rack/utils.rb" => "# -*- encoding: binary -*-\nmodule Rack::Utils; end\n")
      @factory.build("roda", "3.109.0", "lib/roda.rb" => "class Roda; end\n")
      @factory.build("ruby_wasm_ic_minimal", "0.1.3",
                     "lib/ruby_wasm_ic_minimal.rb" => "module RubyWasmIcMinimal; end\n",
                     **%w[date encoding_constants stringio strscan].to_h { ["lib/ruby_wasm_ic_minimal/standins/#{_1}.rb", ""] })
      ex.run
    end
  end

  let(:lock) do
    lockfile(%w[rack 3.1.8], %w[roda 3.109.0], %w[ruby_wasm_ic_minimal 0.1.3], %w[stringio 3.1.2], %w[strscan 3.1.0])
  end

  it "installs a lock: skips the stand-ins' gems, rewrites aliases, sends, commits, writes the setup file" do
    report = @installer.install(lock)
    expect(report).to include(
      "skip stringio-3.1.2: ruby_wasm_ic_minimal stands in for stringio on a minimal canister",
      "skip strscan-3.1.0: ruby_wasm_ic_minimal stands in for strscan on a minimal canister",
      "rewrite rack-3.1.8/lib/rack/utils.rb:1: magic comment binary -> ascii-8bit",
      "setup generation 1 takes effect at the next upgrade",
      "upgrade the canister to load it (icp deploy --mode upgrade)"
    )
    expect(report.grep(/^send /).map { _1.split.at(1) }).to eq(%w[rack-3.1.8 roda-3.109.0 ruby_wasm_ic_minimal-0.1.3])
    expect(@factory.fetched).not_to include("stringio-3.1.2")
    expect(installed).to include(gems: %w[rack-3.1.8 roda-3.109.0 ruby_wasm_ic_minimal-0.1.3], pending: 1, running: nil)
    utils = File.join(@canister.dir, "gems/rack-3.1.8/lib/rack/utils.rb")
    expect(File.read(utils)).to start_with("# -*- encoding: ascii-8bit -*-")
  end

  it "takes effect at the next upgrade: the boot loads the gems from /data" do
    @installer.install(lock)
    expect { require "roda" }.to raise_error(LoadError)
    @canister.upgrade!
    expect($LOAD_PATH[1, 3]).to eq(%w[rack-3.1.8 roda-3.109.0 ruby_wasm_ic_minimal-0.1.3]
                                     .map { File.join(@canister.dir, "gems", _1, "lib") })
    expect($LOAD_PATH.resolve_feature_path("roda")&.last).to eq(File.join(@canister.dir, "gems/roda-3.109.0/lib/roda.rb"))
    expect(@installer.status).to eq(["running generation: 1", "pending generation: 1",
                                     "installed: rack-3.1.8, roda-3.109.0, ruby_wasm_ic_minimal-0.1.3"])
  end

  it "sends nothing the second time" do
    @installer.install(lock)
    calls = @canister.calls.size
    expect(@installer.install(lock).last).to eq(
      "nothing to send: the canister has every locked gem and the setup file already names them"
    )
    expect(@canister.calls.size).to eq(calls + 1) # installed() only
  end

  it "plans without writing on a dry run" do
    report = @installer.install(lock, dry_run: true)
    expect(report).to include(match(/\Awould call install_put: 8 files, \d+ bytes\z/))
    expect(report.last).to eq("setup generation 1 takes effect at the next upgrade")
    expect(@canister.calls.map(&:first)).to eq(["installed"])
    expect(installed[:gems]).to eq([])
  end

  it "replaces a version, keeps the old one until prune, and prunes only what no boot needs" do
    @installer.install(lockfile(%w[rack 3.1.8]))
    @canister.upgrade!
    @factory.build("rack", "3.1.9", "lib/rack.rb" => "module Rack; VERSION = '3.1.9'; end\n")
    @installer.install(lockfile(%w[rack 3.1.9]))
    expect(@installer.status).to eq(["running generation: 1", "pending generation: 2 (takes effect at the next upgrade)",
                                     "installed: rack-3.1.8, rack-3.1.9"])
    expect(@installer.prune).to eq(["nothing to prune: every installed version is named by the running or pending setup"])
    @canister.upgrade!
    expect(@installer.prune(dry_run: true)).to eq(["would remove rack-3.1.8"])
    expect(@installer.prune).to eq(["remove rack-3.1.8: removed rack-3.1.8"])
    expect(installed[:gems]).to eq(["rack-3.1.9"])
  end

  it "goes back by resending the previous lock while the old version is still there" do
    @installer.install(lockfile(%w[rack 3.1.8]))
    @factory.build("rack", "3.1.9", "lib/rack.rb" => "")
    @installer.install(lockfile(%w[rack 3.1.9]))
    report = @installer.install(lockfile(%w[rack 3.1.8]))
    expect(report.grep(/^send/)).to eq([])
    expect(installed).to include(pending: 3, load_paths: ["rack-3.1.8/lib"])
  end

  it "recovers from a run that stopped half way: the next run clears .partial and sends again" do
    @canister.fail_after(1) # installed() answers, the first install_put is lost
    expect { @installer.install(lock) }.to raise_error(RubyWasmIcInstaller::Runner::CallError, /lost/)
    @canister.fail_after(nil)
    put_files = ->(files) { install_put(files) }
    put_files.([{ path: "rack-3.1.8/lib/stale.rb", body: "stale" }])
    report = @installer.install(lock)
    expect(report).to include("call install_remove: clear rack-3.1.8 from .partial")
    expect(File.exist?(File.join(@canister.dir, "gems/rack-3.1.8/lib/stale.rb"))).to be(false)
    expect(installed[:partial]).to eq([])
  end

  it "reports a refusal from the canister, and the canister keeps nothing of the refused call" do
    IC.controller = false
    expect { @installer.install(lock) }.to raise_error(RubyWasmIcInstaller::Runner::CallError) { |e|
      expect(e.refusal).to eq("only a controller may install code")
    }
    IC.controller = true
    expect(installed).to include(gems: [], partial: [])
  end

  it "sends the stand-ins' gems too when ruby_wasm_ic_minimal is not in the lock, and refuses their extensions" do
    @factory.build("stringio", "3.1.2", { "lib/stringio.rb" => "", "ext/stringio/extconf.rb" => "" },
                   extensions: ["ext/stringio/extconf.rb"])
    expect { @installer.install(lockfile(%w[rack 3.1.8], %w[stringio 3.1.2])) }
      .to raise_error(RubyWasmIcInstaller::GemFiles::Refused, /stringio-3.1.2 has a C extension/)
  end

  it "batches a large install over several calls under the budget" do
    @factory.build("big", "1.0.0", (1..30).to_h { ["lib/big/f#{_1}.rb", "x" * 5_000] })
    small = described_class.new(runner: @canister,
                                gem_files: RubyWasmIcInstaller::GemFiles.new(cache: Dir.mktmpdir, fetcher: @factory.fetcher),
                                budget: 40_000)
    small.install(lockfile(%w[big 1.0.0]))
    puts_ = @canister.calls.select { _1.first == "install_put" }
    expect(puts_.size).to be >= 4
    expect(puts_.map { _1[1] }).to all(be <= 40_000)
    expect(Dir.children(File.join(@canister.dir, "gems/big-1.0.0/lib/big")).size).to eq(30)
  end

  def installed
    RubyWasmIcInstaller::Candid.record(
      RubyWasmIcInstaller::Candid.decode(@canister.call("installed", RubyWasmIcInstaller::Candid.empty_args)).first,
      :running, :pending, :gems, :partial, :load_paths
    )
  end
end
