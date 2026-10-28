# frozen_string_literal: true

require "optparse"

module RubyWasmIcInstaller
  # The command: `ruby_wasm_ic_installer <install|status|prune|setup> ...`.
  class CLI
    USAGE = <<~TEXT
      Usage:
        ruby_wasm_ic_installer install CANISTER [--lock Gemfile.lock] [--dry-run] [icp options]
        ruby_wasm_ic_installer status  CANISTER [icp options]
        ruby_wasm_ic_installer prune   CANISTER [--dry-run] [icp options]
        ruby_wasm_ic_installer setup   APP_DIR  [--yes | --check]

      install  sends the lock's pure-Ruby gems the canister lacks, then the setup
               file that loads them; it takes effect at the next upgrade
      status   what the canister has installed, running and pending
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
               cache: File.join(Dir.home, ".cache", "ruby_wasm_ic_installer"), budget: Plan::DEFAULT_BUDGET }
      args = parser(opts).parse(argv)
      return 0 if opts[:done]

      command = args.shift
      target = args.shift
      raise Error, "#{USAGE}\nunexpected: #{args.join(' ')}" unless args.empty?
      raise Error, USAGE if command.nil? || target.nil?

      case command
      when "setup" then setup(target, opts)
      when "install" then report(installer(target, opts).install(Lockfile.read(opts[:lock]), dry_run: opts[:dry_run]))
      when "status" then report(installer(target, opts).status)
      when "prune" then report(installer(target, opts).prune(dry_run: opts[:dry_run]))
      else raise Error, "#{USAGE}\nunknown command: #{command}"
      end
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
        o.on("--check") { opts[:check] = true }
        o.on("--icp PATH") { opts[:icp] = _1 }
        o.on("--cache DIR") { opts[:cache] = _1 }
        o.on("--budget BYTES", Integer) { opts[:budget] = _1 }
        o.on("-e", "--environment ENV") { opts[:icp_args] += ["-e", _1] }
        o.on("-n", "--network NETWORK") { opts[:icp_args] += ["-n", _1] }
        o.on("--identity NAME") { opts[:icp_args] += ["--identity", _1] }
        o.on("--project-root DIR") { opts[:icp_args] += ["--project-root-override", _1] }
        o.on("-h", "--help") { @out.puts(USAGE) || opts[:done] = true }
        o.on("--version") { @out.puts(VERSION) || opts[:done] = true }
      end
    end

    def installer(canister, opts)
      runner = @runner || Runner.new(canister: canister, icp: opts[:icp], icp_args: opts[:icp_args])
      Installer.new(runner: runner, gem_files: @gem_files || GemFiles.new(cache: opts[:cache]), budget: opts[:budget])
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
