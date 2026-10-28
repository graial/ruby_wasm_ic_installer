# frozen_string_literal: true

module RubyWasmIcInstaller
  # The off-chain half's three acts against one canister, through a Runner:
  # `install` (the lock's gems the canister lacks, then the setup file),
  # `status` (what installed() says) and `prune` (every version neither the
  # running boot nor the pending setup names). Each returns the lines of its
  # report; nothing here prints.
  class Installer
    MINIMAL = "ruby_wasm_ic_minimal"

    def initialize(runner:, gem_files:, budget: Plan::DEFAULT_BUDGET)
      @runner = runner
      @gem_files = gem_files
      @budget = budget
    end

    def status
      i = installed
      [
        "running generation: #{i[:running] || 'none'}",
        "pending generation: #{i[:pending] || 'none'}#{pending_note(i)}",
        "installed: #{i[:gems].empty? ? 'none' : i[:gems].join(', ')}",
        *(i[:partial].empty? ? [] : ["half-sent (.partial): #{i[:partial].join(', ')}"])
      ]
    end

    # `dry_run`: plan and report, call nothing that writes.
    def install(lockfile, dry_run: false)
      report = []
      locked = lockfile.gems
      skip = standins(locked)
      skipped, wanted = locked.partition { skip.include?(_1.name) }
      skipped.each { report << "skip #{_1.name_version}: #{MINIMAL} stands in for #{_1.name} on a minimal canister" }
      prepared = wanted.map { @gem_files.prepare(_1) }
      prepared.flat_map(&:rewrites).each do |r|
        report << "rewrite #{r.file}:#{r.line}: magic comment #{r.from} -> #{r.to}"
      end

      plan = Plan.new(prepared, installed, budget: @budget)
      plan.sent.each { report << "send #{_1.name_version} (#{_1.files.size} files, #{_1.bytes} bytes)" }
      if plan.empty?
        report << "nothing to send: the canister has every locked gem and the setup file already names them"
        return report
      end

      plan.steps.each do |step|
        report << "#{dry_run ? 'would call' : 'call'} #{step.method}: #{step.note}"
        next if dry_run

        reply = Candid.decode(@runner.call(step.method, step.args)).first
        report << "  #{reply}"
      end
      report << (plan.generation ? "setup generation #{plan.generation} takes effect at the next upgrade" \
                                 : "the setup file is unchanged")
      report << "upgrade the canister to load it (icp deploy --mode upgrade)" if plan.generation && !dry_run
      report
    end

    def prune(dry_run: false)
      i = installed
      keep = (names_of(i[:load_paths]) + names_of(i[:running_paths])).uniq
      gone = i[:gems] - keep
      return ["nothing to prune: every installed version is named by the running or pending setup"] if gone.empty?

      gone.map do |nv|
        next "would remove #{nv}" if dry_run

        reply = Candid.decode(@runner.call("install_remove", Candid.text_arg(nv))).first
        "remove #{nv}: #{reply}"
      end
    end

    private

    def installed
      v = Candid.decode(@runner.call("installed", Candid.empty_args, query: true)).first
      Candid.record(v, :running, :pending, :gems, :partial, :load_paths, :running_paths)
    end

    def names_of(paths) = paths.map { _1.split("/").first }.uniq

    def pending_note(i)
      return "" if i[:pending].nil? || i[:pending] == i[:running]

      " (takes effect at the next upgrade)"
    end

    def standins(locked)
      minimal = locked.find { _1.name == MINIMAL }
      minimal ? @gem_files.standins(minimal) : []
    end
  end
end
