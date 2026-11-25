# frozen_string_literal: true

require "optparse"

module RubyWasmIcInstaller
  # The command: `ruby_wasm_ic_installer <install|status|prune|setup> ...`.
  class CLI
    USAGE = <<~TEXT
      Usage:
        ruby_wasm_ic_installer install CANISTER [--lock Gemfile.lock] [--dry-run] [--upgrade] [icp options]
        ruby_wasm_ic_installer status  CANISTER [icp options]
        ruby_wasm_ic_installer verify  CANISTER [icp options]
        ruby_wasm_ic_installer verify-init [--lock Gemfile.lock] [--yes]
        ruby_wasm_ic_installer prune   CANISTER [--dry-run] [icp options]
        ruby_wasm_ic_installer setup   APP_DIR  [--yes | --check]

      install  sends the lock's pure-Ruby gems the canister lacks, then the setup
               file that loads them; it takes effect at the next upgrade, or at
               once with --upgrade (icp deploy --mode upgrade, then verify)
      status   what the canister has installed, running and pending; the target
               Build and Release; gems the target refuses; the boot's load failures
      verify   requires the names in the config's verify: list on the canister,
               and reports the boot's load failures; exits 1 if any failed
      verify-init  writes the front-door require names of the lock's gems into
               the config's verify: list, for you to edit
      prune    removes every version neither the running nor the pending setup names
      setup    wires the Installer's methods into an Application (ic-interface.rb,
               app.rb, vendor/ruby_wasm_ic_installer/)

      icp options, passed to `icp canister call`:
        -e, --environment ENV   -n, --network NETWORK   --identity NAME
        --project-root DIR      the icp project (icp's --project-root-override)
        --icp PATH              the icp command (default: icp)
      Other options:
        --cache DIR             where fetched .gem files are kept
                                (default: ~/.cache/ruby_wasm_ic_installer)
        --build minimal|full    the target Build (else the config, else the canister's report,
                                else minimal)
        --release VERSION       the target Release, likewise
        --strict                refuse, not warn, when a linked gem's locked version is not the one the
                                Build links, or when the target is assumed (or strict: true in the config)
        --config PATH           the config file (default: #{Config::FILE} in the project root)
        --budget BYTES          the largest batch, in bytes of Candid (default: #{Plan::DEFAULT_BUDGET})
        -h, --help, --version
    TEXT

    def self.start(argv, out: $stdout, err: $stderr, input: $stdin, runner: nil, gem_files: nil)
      new(out: out, err: err, input: input, runner: runner, gem_files: gem_files).run(argv)
    end

    def initialize(out:, err:, input:, runner:, gem_files:)
      @out = out
      @err = err
      @input = input
      @runner = runner
      @gem_files = gem_files
    end

    # The exit status.
    def run(argv)
      opts = { lock: "Gemfile.lock", icp: "icp", icp_args: [], dry_run: false, yes: false, check: false,
               upgrade: false, flags: {}, config: nil, project_root: nil,
               cache: File.join(Dir.home, ".cache", "ruby_wasm_ic_installer"), budget: Plan::DEFAULT_BUDGET }
      args = parser(opts).parse(argv)
      return 0 if opts[:done]

      command = args.shift
      target = args.shift
      raise Error, "#{USAGE}\nunexpected: #{args.join(' ')}" unless args.empty?
      raise Error, USAGE if command.nil? || (target.nil? && command != "verify-init")

      case command
      when "setup" then setup(target, opts)
      when "install" then report(installer(target, opts).install(Lockfile.read(opts[:lock]), dry_run: opts[:dry_run],
                                                                             upgrade: opts[:upgrade]))
      when "status" then report(installer(target, opts).status)
      when "verify" then report(installer(target, opts).verify)
      when "verify-init" then verify_init(opts)
      when "prune" then report(installer(target, opts).prune(dry_run: opts[:dry_run]))
      else raise Error, "#{USAGE}\nunknown command: #{command}"
      end
    rescue Installer::VerifyFailed => e
      e.lines.each { @out.puts(_1) }
      @err.puts(e.message)
      1
    rescue Error, OptionParser::ParseError => e
      @err.puts(e.message)
      e.is_a?(Runner::CallError) || e.is_a?(AppSetup::Aborted) ? 1 : 2
    end

    private

    def parser(opts)
      OptionParser.new do |o|
        o.banner = USAGE
        o.on("--lock PATH") { opts[:lock] = _1 }
        o.on("--dry-run") { opts[:dry_run] = true }
        o.on("--yes") { opts[:yes] = true }
        o.on("--upgrade") { opts[:upgrade] = true }
        o.on("--build BUILD") { opts[:flags][:build] = Config.check_build(_1, "--build") }
        o.on("--release VERSION") { opts[:flags][:release] = Config.check_release(_1, "--release") }
        o.on("--config PATH") { opts[:config] = _1 }
        o.on("--strict") { opts[:flags][:strict] = true }
        o.on("--check") { opts[:check] = true }
        o.on("--icp PATH") { opts[:icp] = _1 }
        o.on("--cache DIR") { opts[:cache] = _1 }
        o.on("--budget BYTES", Integer) { opts[:budget] = _1 }
        o.on("-e", "--environment ENV") { opts[:icp_args] += ["-e", _1] }
        o.on("-n", "--network NETWORK") { opts[:icp_args] += ["-n", _1] }
        o.on("--identity NAME") { opts[:icp_args] += ["--identity", _1] }
        o.on("--project-root DIR") do
          opts[:icp_args] += ["--project-root-override", _1]
          opts[:project_root] = _1
        end
        o.on("-h", "--help") { @out.puts(USAGE) || opts[:done] = true }
        o.on("--version") { @out.puts(VERSION) || opts[:done] = true }
      end
    end

    def installer(canister, opts)
      runner = @runner || Runner.new(canister: canister, icp: opts[:icp], icp_args: opts[:icp_args])
      Installer.new(runner: runner, gem_files: @gem_files || GemFiles.new(cache: opts[:cache]), budget: opts[:budget],
                    config: config(opts), flags: opts[:flags])
    end

    def config_path(opts) = opts[:config] || Config.default_path(opts[:project_root])

    def config(opts) = Config.read(config_path(opts))

    # Writes the lock's gems' front-door names into the config's verify: list.
    # It keeps the other keys but not comments, and does not overwrite a list
    # that is already there without --yes.
    def verify_init(opts)
      path = config_path(opts)
      found, unresolved = installer(nil, opts).entry_points(Lockfile.read(opts[:lock]))
      data = File.file?(path) ? (YAML.safe_load_file(path) || {}) : {}
      Config.new(data, path: path) # a malformed file stops here
      if Array(data["verify"]).any? && !opts[:yes]
        raise Error, "#{path} already has a verify: list; run again with --yes to replace it"
      end

      File.write(path, YAML.dump(data.merge("verify" => found)))
      @out.puts("wrote #{path}: verify: #{found.join(', ')}")
      unresolved.each { @out.puts("no front door found for #{_1}: add its require name by hand if the app needs it") }
      0
    end

    def setup(dir, opts)
      s = AppSetup.new(dir, io: @out, input: @input)
      return s.check if opts[:check]

      s.run(yes: opts[:yes])
      0
    end

    def report(lines)
      lines.each { @out.puts(_1) }
      0
    end
  end
end
