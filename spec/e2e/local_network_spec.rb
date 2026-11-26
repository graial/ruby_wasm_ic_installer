# frozen_string_literal: true

require "open3"
require "rbconfig"

# Layer 3 (W29, Q18): the Installer end to end, on a local icp-cli network
# (whose launcher runs PocketIC). It repeats W28 through the gem: `setup` wires
# a Roda Application in, the packer packs it on a published Base Module, icp-cli
# deploys it, `install` sends Rack, Roda and the ruby_wasm_ic gems the Build
# needs from a real Gemfile.lock (fetched from rubygems.org), an upgrade loads
# them, and the canister serves a page through them. Then a second install
# sends nothing. The lock is fixtures/<build>/Gemfile.lock: `minimal` adds
# ruby_wasm_ic_minimal, which `full` refuses.
#
# Skipped unless asked:
#   E2E_BASE=path/to/ruby-3.3-wasm32-unknown-icp-minimal-0.15.0.wasm
#   E2E_PACKER=path/to/packer-0.15.0         (the unpacked packer tarball)
#   E2E_BUILD=minimal|full                   (default: from E2E_BASE's name)
#   E2E_ICP=icp                              (icp-cli 1.6 or later; default icp)
#   ICP_CLI_NETWORK_LAUNCHER_PATH=...        (if icp-cli cannot fetch its launcher)
# and run with `bundle exec rspec spec/e2e`. It needs rubygems.org and a few
# minutes; run it before each release.
RSpec.describe "the Installer on a local icp-cli network", :e2e do
  base = ENV["E2E_BASE"]
  packer = ENV["E2E_PACKER"]
  icp = ENV.fetch("E2E_ICP", "icp")
  build = ENV.fetch("E2E_BUILD") { base.to_s[/-(minimal|full)-/, 1] }

  before(:all) do
    skip "set E2E_BASE and E2E_PACKER to run the end-to-end spec" unless base && packer
    raise "set E2E_BUILD to minimal or full: #{base}'s name does not say" unless %w[minimal full].include?(build)
  end

  around do |ex|
    Dir.mktmpdir("ruby_wasm_ic_installer-e2e") do |dir|
      @dir = dir
      @log = []
      ex.run
    ensure
      sh(icp, "network", "stop", allow_failure: true) if @started
      File.write(File.join(Dir.tmpdir, "ruby_wasm_ic_installer-e2e.log"), @log.join("\n"))
    end
  end

  def sh(*argv, allow_failure: false)
    out, status = Open3.capture2e({ "DO_NOT_TRACK" => "1" }, *argv, chdir: @dir)
    @log << "$ #{argv.join(' ')}" << out << "exit #{status.exitstatus}"
    raise "#{argv.first(3).join(' ')} failed:\n#{out}" unless status.success? || allow_failure

    out
  end

  def cli(*argv)
    exe = File.expand_path("../../exe/ruby_wasm_ic_installer", __dir__)
    sh(RbConfig.ruby, exe, *argv)
  end

  def icp = ENV.fetch("E2E_ICP", "icp")

  def get(path)
    arg = "(record { method = \"GET\"; url = \"#{path}\"; headers = vec {}; body = blob \"\"; " \
          "certificate_version = null })"
    out = sh(icp, "canister", "call", "site", "http_request", arg, "--query")
    body = out[/body = blob "((?:[^"\\]|\\.)*)"/, 1] or raise "no body in #{out}"
    body.gsub(/\\(\h\h)|\\(.)/) { Regexp.last_match(1) ? Regexp.last_match(1).hex.chr : Regexp.last_match(2) }
        .force_encoding("UTF-8")
  end

  it "installs Rack and Roda from a lock, takes effect at the upgrade, and serves a page through them" do
    app = File.join(@dir, "app")
    FileUtils.cp_r(File.expand_path("fixtures/app", __dir__), app)
    FileUtils.cp(File.expand_path("fixtures/#{build}/Gemfile.lock", __dir__), @dir)
    File.write(File.join(@dir, ".ruby_wasm_ic_installer.yml"), "build: #{build}\n")
    cli("setup", app)
    expect(cli("setup", app, "--check")).to include("setup is current")

    FileUtils.mkdir_p(File.join(@dir, "site"))
    sh(RbConfig.ruby, File.join(packer, "pack.rb"), base, app, File.join(@dir, "site", "site.wasm"))
    File.write(File.join(@dir, "icp.yaml"), "canisters:\n  - site\n")
    sh(icp, "network", "start", "-d")
    @started = true
    sh(icp, "deploy", "--yes")
    expect(get("/books")).to eq("w28 app not installed")

    report = cli("install", "site", "--lock", File.join(@dir, "Gemfile.lock"), "--icp", icp,
                 "--project-root", @dir, "--cache", File.join(@dir, "cache"))
    sent = %w[rack-3.1.8 roda-3.109.0 ruby_wasm_ic_rack-0.1.1]
    sent.insert(2, "ruby_wasm_ic_minimal-0.1.5") if build == "minimal"
    lines = report.lines(chomp: true)
    expect(lines.grep(/\Asend /).map { _1.split[1] }).to eq(sent)
    expect(lines).to include(match(/\Atarget: #{build} 0\.1[3-9]\.\d+ \(/), "setup generation 1 takes effect at the next upgrade")
    expect(lines.grep(/newer than|rewrite/)).to eq([])
    expect(get("/books")).to eq("w28 app not installed") # not until the upgrade

    sh(icp, "deploy", "--mode", "upgrade", "--yes")
    expect(get("/books")).to eq("1: Noli Me Tangere")
    expect(get("/books/search?q=Jos%C3%A9")).to eq("q=José")
    status = cli("status", "site", "--icp", icp, "--project-root", @dir)
    expect(status).to include("running generation: 1", "pending generation: 1",
                              "installed: #{sent.join(', ')}", "known releases: 0.13.0 to 0.15.0 " \
                              "(ruby_wasm_ic_installer #{RubyWasmIcInstaller::VERSION})")

    again = cli("install", "site", "--lock", File.join(@dir, "Gemfile.lock"), "--icp", icp,
                "--project-root", @dir, "--cache", File.join(@dir, "cache"))
    expect(again).to include("nothing to send")
    expect(cli("prune", "site", "--icp", icp, "--project-root", @dir)).to include("nothing to prune")
  end
end
