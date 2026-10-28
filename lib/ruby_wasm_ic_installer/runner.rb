# frozen_string_literal: true

require "open3"
require "tempfile"

module RubyWasmIcInstaller
  # The one way the off-chain half reaches a canister (W29, Q13):
  # `icp canister call <canister> <method> --args-file <file> --args-format
  # bin -o hex`, with `--query` for a query. The author's icp.yaml,
  # environment, network and identity pass through as `icp_args`; the
  # Installer holds no keys and picks no network. A file carries the
  # arguments because one command-line argument is capped at 128 KiB and a
  # batch is up to 2 MiB.
  #
  # It is also the test seam: the specs give the Installer a runner whose
  # #call answers from a canister held in memory.
  class Runner
    class CallError < Error
      attr_reader :refusal

      def initialize(message, refusal: nil)
        super(message)
        @refusal = refusal
      end
    end

    # `spawn` is called as spawn.(*argv) and returns [stdout, stderr, status];
    # the default is Open3.capture3.
    def initialize(canister:, icp: "icp", icp_args: [], spawn: nil)
      @canister = canister
      @icp = icp
      @icp_args = icp_args
      @spawn = spawn || Open3.method(:capture3)
    end

    # The reply's bytes.
    def call(method, args, query: false)
      Tempfile.create(["ruby_wasm_ic_installer", ".bin"], binmode: true) do |f|
        f.write(args)
        f.flush
        argv = [@icp, "canister", "call", @canister, method, "--args-file", f.path, "--args-format", "bin",
                "-o", "hex", *(query ? ["--query"] : []), *@icp_args]
        out, err, status = @spawn.call(*argv)
        raise CallError.new("#{method}: #{err.strip.empty? ? out.strip : err.strip}", refusal: refusal(err)) \
          unless status.success?

        hex = out.strip
        raise CallError, "#{method}: icp replied #{out.inspect[0, 200]}, not hex" unless hex.match?(/\A(?:[0-9a-fA-F]{2})+\z/)

        [hex].pack("H*")
      end
    end

    private

    # The text after `refused: ` in a trap message, if the canister refused.
    def refusal(err) = err[/refused: (.*?)(?:'|"|$)/, 1]
  end
end
