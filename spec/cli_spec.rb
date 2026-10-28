# frozen_string_literal: true

require "stringio"

# The command (W29, Q13, Q17), with the canister in memory behind the runner.
RSpec.describe RubyWasmIcInstaller::CLI do
  around do |ex|
    Dir.mktmpdir do |dir|
      @dir = dir
      @factory = GemFactory.new(File.join(dir, "gems"))
      @factory.build("rack", "3.1.8", "lib/rack.rb" => "R")
      @canister = InMemoryCanister.new(File.join(dir, "data").tap { Dir.mkdir(_1) })
      @lock = File.join(dir, "Gemfile.lock")
      File.write(@lock, "GEM\n  remote: https://rubygems.org/\n  specs:\n    rack (3.1.8)\n\nPLATFORMS\n  ruby\n\n" \
                        "DEPENDENCIES\n  rack\n")
      ex.run
    end
  end

  def cli(*argv, input: "")
    @out = StringIO.new
    @err = StringIO.new
    described_class.start(argv, out: @out, err: @err, input: StringIO.new(input), runner: @canister,
                                gem_files: RubyWasmIcInstaller::GemFiles.new(cache: File.join(@dir, "cache"),
                                                                             fetcher: @factory.fetcher))
  end

  it "installs from the lock, reports status, and prunes" do
    expect(cli("install", "my_app", "--lock", @lock)).to eq(0)
    expect(@out.string).to include("send rack-3.1.8", "setup generation 1 takes effect at the next upgrade")
    expect(cli("status", "my_app")).to eq(0)
    expect(@out.string).to include("pending generation: 1 (takes effect at the next upgrade)", "installed: rack-3.1.8")
    expect(cli("prune", "my_app", "--dry-run")).to eq(0)
    expect(@out.string).to include("nothing to prune")
  end

  it "plans without writing with --dry-run" do
    expect(cli("install", "my_app", "--lock", @lock, "--dry-run")).to eq(0)
    expect(@out.string).to include("would call install_put")
  end

  it "takes --budget and the icp options" do
    expect(cli("install", "my_app", "--lock", @lock, "--budget", "100000", "-e", "ic", "-n", "local",
               "--identity", "me", "--project-root", @dir, "--icp", "/x/icp", "--cache", File.join(@dir, "c2"))).to eq(0)
  end

  it "runs setup and setup --check" do
    app = File.join(@dir, "app")
    Dir.mkdir(app)
    File.write(File.join(app, "app.rb"), "")
    File.write(File.join(app, "ic-interface.rb"), "")
    expect(cli("setup", app, "--check")).to eq(1)
    expect(cli("setup", app)).to eq(0)
    expect(cli("setup", app, "--check")).to eq(0)
    File.write(File.join(app, "app.rb"), File.read(File.join(app, "app.rb")).sub("require", "load"))
    expect(cli("setup", app)).to eq(1)
    expect(@err.string).to include("no terminal")
    expect(cli("setup", app, "--yes")).to eq(0)
  end

  it "prints usage, help and the version" do
    expect(cli("--help")).to eq(0)
    expect(@out.string).to include("Usage:", "ruby_wasm_ic_installer setup   APP_DIR")
    expect(cli("--version")).to eq(0)
    expect(@out.string).to eq("#{RubyWasmIcInstaller::VERSION}\n")
  end

  it "exits 2 for a usage error, a bad option, an unknown command and a missing lock" do
    expect(cli).to eq(2)
    expect(@err.string).to include("Usage:")
    expect(cli("install")).to eq(2)
    expect(cli("frobnicate", "x")).to eq(2)
    expect(@err.string).to include("unknown command: frobnicate")
    expect(cli("install", "x", "extra")).to eq(2)
    expect(@err.string).to include("unexpected: extra")
    expect(cli("install", "x", "--no-such")).to eq(2)
    expect(cli("install", "x", "--lock", File.join(@dir, "none.lock"))).to eq(2)
    expect(@err.string).to include("bundle lock")
  end

  it "exits 1 when the canister refuses" do
    IC.controller = false
    expect(cli("install", "my_app", "--lock", @lock)).to eq(1)
    expect(@err.string).to include("refused: only a controller may install code")
  end

  it "builds a real Runner and GemFiles when none is given" do
    out = StringIO.new
    err = StringIO.new
    expect(Open3).to receive(:capture3).with("icp", "canister", "call", "my_app", "installed", any_args)
                                       .and_return(["", "no network", instance_double(Process::Status, success?: false)])
    expect(described_class.start(%w[status my_app], out: out, err: err)).to eq(1)
    expect(err.string).to include("installed: no network")
  end

  it "has an executable that runs the command" do
    exe = File.expand_path("../exe/ruby_wasm_ic_installer", __dir__)
    out, status = Open3.capture2e(RbConfig.ruby, exe, "--version")
    expect([out, status.exitstatus]).to eq(["#{RubyWasmIcInstaller::VERSION}\n", 0])
  end
end
