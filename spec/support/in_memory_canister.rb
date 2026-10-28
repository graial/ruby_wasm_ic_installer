# frozen_string_literal: true

# A canister held in memory behind the Runner seam (W29, Q13 and Q18): the
# real canister half, on MRI, over a temporary IC::DATA_DIR. It decodes each
# call's Candid as the canister's Codec would hand it to a handler (records
# as Symbol-keyed Hashes), calls the handler, and encodes the reply, so the
# off-chain half is exercised end to end with no icp-cli and no network.
#
# Like the IC, a call that refuses changes nothing: the data directory is
# restored from a copy taken before the call. A message over 2 MiB is refused
# before it runs, as at ingress. `upgrade!` boots the canister half again
# with a fresh $LOAD_PATH, as a new heap would.
class InMemoryCanister
  C = RubyWasmIcInstaller::Candid
  INGRESS_LIMIT = 2 * 1024 * 1024

  attr_reader :dir, :calls

  def initialize(dir)
    @dir = dir
    @calls = []
    @fail_after = nil
    RubyWasmIcInstaller::Canister.data_dir = dir
    upgrade!
  end

  # The next `n` calls succeed, and the one after raises as a lost call would.
  def fail_after(n) = @fail_after = n

  def upgrade!
    @base_load_path ||= $LOAD_PATH.reject { _1 == "/app" }
    $LOAD_PATH.replace(["/app", *@base_load_path])
    RubyWasmIcInstaller::Canister.boot!
  end

  def call(method, args, query: false)
    @calls << [method, args.bytesize, query]
    if @fail_after
      raise RubyWasmIcInstaller::Runner::CallError, "#{method}: the connection was lost" if @fail_after.zero?

      @fail_after -= 1
    end
    raise RubyWasmIcInstaller::Runner::CallError, "#{method}: message larger than the max allowed" if args.bytesize > INGRESS_LIMIT

    values = C.decode(args)
    snapshot = File.join(File.dirname(@dir), "snapshot")
    FileUtils.rm_rf(snapshot)
    FileUtils.cp_r(@dir, snapshot)
    begin
      reply(method, handle(method, values))
    rescue IC::Refusal => e
      FileUtils.rm_rf(@dir)
      FileUtils.mv(snapshot, @dir)
      raise RubyWasmIcInstaller::Runner::CallError.new("#{method}: refused: #{e.message}", refusal: e.message)
    end
  end

  private

  def handle(method, values)
    case method
    when "install_put"
      files = values.first.map { |r| C.record(r, :path, :body) }
      install_put(files)
    when "install_commit"
      r = C.record(values.first, :gems, :setup)
      r[:setup] &&= C.record(r[:setup], :generation, :load_paths)
      install_commit(r)
    when "install_remove" then install_remove(values.first)
    when "installed" then installed
    else raise ArgumentError, "no method #{method}"
    end
  end

  def reply(method, value)
    return C.text_arg(value) unless method == "installed"

    opt = ->(n) { n.nil? ? "\x00".b : "\x01".b + C.nat64_value(n) }
    table = C.types(
      C.record_type([["running", C.sleb(1)], ["pending", C.sleb(1)], ["gems", C.sleb(2)], ["partial", C.sleb(2)],
                     ["load_paths", C.sleb(2)], ["running_paths", C.sleb(2)]]),
      "\x6e".b + C.sleb(C::NAT64),
      "\x6d".b + C.sleb(C::TEXT)
    )
    body = C.record_value("running" => opt.(value[:running]), "pending" => opt.(value[:pending]),
                          "gems" => C.texts_value(value[:gems]), "partial" => C.texts_value(value[:partial]),
                          "load_paths" => C.texts_value(value[:load_paths]),
                          "running_paths" => C.texts_value(value[:running_paths]))
    C::MAGIC + table + C.leb(1) + C.sleb(0) + body
  end
end
