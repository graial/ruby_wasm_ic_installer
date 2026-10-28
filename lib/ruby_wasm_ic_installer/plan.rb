# frozen_string_literal: true

module RubyWasmIcInstaller
  # What one install run sends (W29, Q10): every prepared gem the canister
  # lacks, whole, packed into install_put batches by bytes, each followed by
  # an install_commit for the gems it completed; then one install_commit that
  # writes the setup file, unless the pending one already says the same.
  #
  # A batch is at most `budget` bytes of Candid (2 MiB is the ingress limit;
  # W28 saw 2,093,069 bytes pass and 2,101,455 refused at submission, so the
  # default leaves room for the envelope icp-cli adds). A gem bigger than a
  # batch spans several; .partial holds it until its commit.
  class Plan
    DEFAULT_BUDGET = 2_000_000

    Step = Struct.new(:method, :args, :note, keyword_init: true)

    attr_reader :steps, :sent, :generation

    # `prepared`: GemFiles::Prepared in the lock's order (stand-ins already
    # left out). `installed`: the canister's installed() record.
    def initialize(prepared, installed, budget: DEFAULT_BUDGET)
      @budget = budget
      have = installed[:gems]
      @sent = prepared.reject { have.include?(_1.name_version) }
      @steps = []
      # A version half-sent by an earlier run is cleared first: its files are
      # resent whole, so nothing stale is committed with them.
      (installed[:partial] & @sent.map(&:name_version)).each do |nv|
        @steps << Step.new(method: "install_remove", args: Candid.text_arg(nv), note: "clear #{nv} from .partial")
      end
      batch!
      setup!(prepared, installed)
    end

    def empty? = @steps.empty?

    private

    def batch!
      files = []
      size = 0
      done = []
      flush = lambda do
        next if files.empty?

        @steps << Step.new(method: "install_put", args: Candid.install_files(files),
                           note: "#{files.size} files, #{files.sum { _1[:body].bytesize }} bytes")
        unless done.empty?
          @steps << Step.new(method: "install_commit", args: Candid.install_commit(gems: done),
                             note: "commit #{done.join(', ')}")
        end
        files = []
        size = 0
        done = []
      end
      @sent.each do |gem|
        gem.files.each do |rel, body|
          path = "#{gem.name_version}/#{rel}"
          one = Candid.install_file_size(path, body)
          if one + Candid.install_files_overhead(1) > @budget
            raise Error, "#{path} is #{body.bytesize} bytes, more than one call can carry (#{@budget})"
          end

          flush.call if size + one + Candid.install_files_overhead(files.size + 1) > @budget
          files << { path: path, body: body }
          size += one
        end
        done << gem.name_version
      end
      flush.call
    end

    def setup!(prepared, installed)
      paths = prepared.flat_map { |g| g.require_paths.map { "#{g.name_version}/#{_1}" } }
      return if installed[:pending] && installed[:load_paths] == paths

      @generation = [installed[:pending], installed[:running]].compact.max.to_i + 1
      @steps << Step.new(method: "install_commit",
                         args: Candid.install_commit(gems: [], setup: { generation: @generation, load_paths: paths }),
                         note: "write setup generation #{@generation} (#{paths.size} load paths)")
    end
  end
end
