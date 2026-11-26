# frozen_string_literal: true

require "stringio"

# The command (W29, Q13, Q17), with the canister in memory behind the runner.
RSpec.describe RubyWasmIcInstaller::CLI do
  around do |ex|
    Dir.mktmpdir do |dir|
      @dir = dir
      @factory = GemFactory.new(File.join(dir, "gems"))
      @factory.build("rack", "3.1.8", "lib/rack.rb" => "module Rack; end\n")
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

  it "installs and reports under a US-ASCII locale, and reads a lock with non-ASCII in it" do
    @factory.build("rack", "3.1.9", "lib/rack.rb" => "# Café\nmodule Rack; end\n")
    File.write(@lock, File.read(@lock).sub("rack (3.1.8)", "rack (3.1.9)"))
    path_lock = File.join(@dir, "path.lock")
    File.write(path_lock, "PATH\n  remote: vendor/café\n  specs:\n    local (1.0.0)\n\nGEM\n  remote: https://rubygems.org/\n" \
                          "  specs:\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n  local!\n")
    external = Encoding.default_external
    begin
      Encoding.default_external = Encoding::US_ASCII
      expect(cli("install", "my_app", "--lock", @lock)).to eq(0)
      expect(cli("status", "my_app")).to eq(0)
      expect(@out.string).to include("installed: rack-3.1.9")
      expect(cli("install", "my_app", "--lock", path_lock)).to eq(2)
      expect(@err.string).to include("local comes from path")
    ensure
      Encoding.default_external = external
    end
  end

  describe "the target and the config" do
    def write_config(text) = File.write(File.join(@dir, ".ruby_wasm_ic_installer.yml"), text)

    it "reads .ruby_wasm_ic_installer.yml from --project-root, and the flags win" do
      write_config("build: full\nrelease: 0.13.0\n")
      expect(cli("status", "my_app", "--project-root", @dir)).to eq(0)
      expect(@out.string).to include("target: full 0.13.0 (build from #{@dir}/.ruby_wasm_ic_installer.yml")
      expect(cli("status", "my_app", "--project-root", @dir, "--build", "minimal", "--release", "0.14.0")).to eq(0)
      expect(@out.string).to include("target: minimal 0.14.0 (build from --build, release from --release)")
    end

    it "reads --config" do
      path = File.join(@dir, "other.yml")
      File.write(path, "build: full\n")
      expect(cli("status", "my_app", "--config", path)).to eq(0)
      expect(@out.string).to include("target: full (build from #{path}")
    end

    it "exits 2 under --strict when the target is assumed, and installs once it is declared" do
      expect(cli("install", "my_app", "--lock", @lock, "--strict")).to eq(2)
      expect(@err.string).to include("refused (strict): nothing was sent:", "  the target is assumed")
      expect(cli("install", "my_app", "--lock", @lock, "--strict", "--build", "minimal")).to eq(0)
    end

    it "exits 2 on a bad --build, a bad --release or a bad config" do
      expect(cli("status", "my_app", "--build", "huge")).to eq(2)
      expect(@err.string).to include("build must be one of")
      expect(cli("status", "my_app", "--release", "soon")).to eq(2)
      write_config("buid: full\n")
      expect(cli("status", "my_app", "--project-root", @dir)).to eq(2)
    end

    it "exits 2 on a refusal and sends nothing" do
      @factory.build("ruby_wasm_ic_minimal", "0.1.5", "lib/ruby_wasm_ic_minimal.rb" => "")
      File.write(@lock, File.read(@lock).sub("    rack (3.1.8)", "    rack (3.1.8)\n    ruby_wasm_ic_minimal (0.1.5)"))
      expect(cli("install", "my_app", "--lock", @lock, "--build", "full")).to eq(2)
      expect(@err.string).to include("remove it from the Gemfile")
    end
  end

  describe "install --upgrade and verify" do
    it "deploys and verifies, exit 0" do
      File.write(File.join(@dir, ".ruby_wasm_ic_installer.yml"), "verify: [rack]\n")
      expect(cli("install", "my_app", "--lock", @lock, "--upgrade", "--project-root", @dir)).to eq(0)
      expect(@out.string).to include("call icp deploy --mode upgrade", "ok rack", "upgraded:")
      expect(cli("verify", "my_app", "--project-root", @dir)).to eq(0)
      expect(@out.string).to include("verified: 1 require names")
    end

    it "prints the report and exits 1 when something fails to load" do
      File.write(File.join(@dir, ".ruby_wasm_ic_installer.yml"), "verify: [nope]\n")
      expect(cli("verify", "my_app", "--project-root", @dir)).to eq(1)
      expect(@out.string).to include("FAIL nope: LoadError")
      expect(@err.string).to include("verification failed")
    end
  end

  describe "verify-init" do
    let(:path) { File.join(@dir, ".ruby_wasm_ic_installer.yml") }

    it "writes the front doors it finds, keeping the other keys, and says what it could not resolve" do
      @factory.build("other", "1.0.0", "lib/unrelated.rb" => "")
      File.write(@lock, File.read(@lock).sub("    rack (3.1.8)", "    other (1.0.0)\n    rack (3.1.8)"))
      File.write(path, "build: minimal\n")
      expect(cli("verify-init", "--lock", @lock, "--project-root", @dir)).to eq(0)
      expect(YAML.safe_load_file(path)).to eq("build" => "minimal", "verify" => ["rack"])
      expect(@out.string).to include("wrote #{path}: verify: rack", "no front door found for other-1.0.0")
    end

    it "does not replace an existing list without --yes" do
      File.write(path, "verify: [mine]\n")
      expect(cli("verify-init", "--lock", @lock, "--project-root", @dir)).to eq(2)
      expect(@err.string).to include("already has a verify: list")
      expect(cli("verify-init", "--lock", @lock, "--project-root", @dir, "--yes")).to eq(0)
      expect(YAML.safe_load_file(path)).to eq("verify" => ["rack"])
    end
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
    expect(err.string).to include("icp-cli's message follows):\nno network")
  end

  it "has an executable that runs the command" do
    exe = File.expand_path("../exe/ruby_wasm_ic_installer", __dir__)
    out, status = Open3.capture2e(RbConfig.ruby, exe, "--version")
    expect([out, status.exitstatus]).to eq(["#{RubyWasmIcInstaller::VERSION}\n", 0])
  end
end
