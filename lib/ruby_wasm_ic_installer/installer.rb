# frozen_string_literal: true

module RubyWasmIcInstaller
  # The off-chain half's acts against one canister, through a Runner:
  # `install` (the lock's gems the canister lacks, then the setup file),
  # `status` (what installed() says), `verify` (require the config's names on
  # the canister) and `prune` (every version neither the running boot nor the
  # pending setup names). Each returns the lines of its report; nothing here
  # prints.
  #
  # The decisions are made here, on the developer's machine, from the config
  # (the desired state) and what the canister reports (the observed state);
  # the canister only answers facts.
  class Installer
    MINIMAL = "ruby_wasm_ic_minimal"
    REQUIRED = %i[running pending gems partial load_paths running_paths].freeze
    # Fields a protocol-1 canister half does not have (`linked`, a protocol-2
    # one; `boot`, a protocol-3 one).
    BOOT_CALL = "RubyWasmIcInstaller::Canister.boot_finished"

    OPTIONAL = { protocol: 1, build: nil, release: nil, load_failures: [], linked: nil, boot: nil }.freeze

    # The target would load a gem that refuses it, the lock holds a compiled
    # gem, or --strict met a warning: nothing was sent.
    class Refused < Error; end

    # `verify` found failures; `lines` is the whole report.
    class VerifyFailed < Error
      attr_reader :lines

      def initialize(lines)
        @lines = lines
        super("verification failed")
      end
    end

    def initialize(runner:, gem_files:, budget: Plan::DEFAULT_BUDGET, config: Config.empty, flags: {})
      @runner = runner
      @gem_files = gem_files
      @budget = budget
      @config = config
      @flags = flags
    end

    def status
      i = installed
      target = Target.resolve(flags: @flags, config: @config, info: i)
      [
        "running generation: #{i[:running] || 'none'}",
        "pending generation: #{i[:pending] || 'none'}#{pending_note(i)}",
        "installed: #{i[:gems].empty? ? 'none' : i[:gems].join(', ')}",
        *(i[:partial].empty? ? [] : ["half-sent (.partial): #{i[:partial].join(', ')}"]),
        *canister_lines(i), target.describe, known_line, *target.warnings.map { "warning: #{_1}" },
        *transition_lines(i, target), *linked(target, i).last,
        *refusal_lines(target, i), *boot_lines(i, hint: true)
      ]
    end

    # `dry_run`: plan and report, call nothing that writes. `upgrade`: after
    # sending, deploy the project as an upgrade and verify the boot.
    def install(lockfile, dry_run: false, upgrade: false)
      i = installed
      target = Target.resolve(flags: @flags, config: @config, info: i)
      names, drift = linked(target, i)
      report = [*canister_lines(i), target.describe, *transition_lines(i, target), *drift]
      locked = lockfile.gems
      refuse!(target, locked.map { [_1.name, _1.version] }, report)

      skip = skips(target, locked, names)
      skipped, wanted = locked.partition { skip.key?(_1.name) }
      skipped.each { report << "skip #{_1.name_version}: #{skip[_1.name]}" }
      warnings, notes = linked_versions(target, skipped, Rules.linked_gems(names))
      warnings = target.warnings + warnings
      report.concat(warnings.map { "warning: #{_1}" }, notes.map { "note: #{_1}" })
      strict!(target, warnings, report)
      prepared = wanted.map { @gem_files.prepare(_1) }

      plan = Plan.new(prepared, i, budget: @budget)
      plan.sent.each { report << "send #{_1.name_version} (#{_1.files.size} files, #{_1.bytes} bytes)" }
      send_plan(plan, report, dry_run)
      report << "upgrade the canister to load it (icp deploy --mode upgrade)" if plan.generation && !dry_run && !upgrade
      upgrade!(report) if upgrade && !dry_run
      report
    end

    # Requires the config's `verify` names on the canister, and reports its
    # boot's load failures. Raises VerifyFailed if either has any.
    def verify
      i = installed
      raise Error, "the canister half is protocol #{i[:protocol]}: run `ruby_wasm_ic_installer setup` and upgrade" if i[:protocol] < 2

      lines = @config.verify.empty? ? ["no verify: list in #{Config::FILE}; checking the boot's load failures only"] : []
      results = @config.verify.empty? ? [] : verify_calls(@config.verify)
      lines.concat(results)
      lines.concat(boot_lines(i))
      failed = results.grep(/\AFAIL /).size + boot_failures(i)
      raise VerifyFailed, lines + ["#{failed} failed"] unless failed.zero?

      lines << "verified: #{results.size} require names" \
               "#{i[:boot] == 'booted' ? '; the boot reported it booted' : ', no load failures'}"
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

    # The lock's gems' entry points, for `verify-init`: [found names, gems
    # with none found]. Gems the target links in or stands in for are left out.
    def entry_points(lockfile)
      i = installed
      target = Target.resolve(flags: @flags, config: @config, info: i)
      locked = lockfile.gems
      skip = skips(target, locked, linked(target, i).first)
      found = []
      unresolved = []
      locked.reject { skip.key?(_1.name) }.each do |g|
        names = @gem_files.entry_points(g)
        names.empty? ? unresolved << g.name_version : found.concat(names)
      end
      [found.uniq, unresolved]
    end

    private

    def installed
      v = Candid.decode(@runner.call("installed", Candid.empty_args, query: true)).first
      rec = Candid.record(v, *REQUIRED)
      OPTIONAL.each do |name, default|
        h = Candid.idl_hash(name)
        rec[name] = v.key?(h) ? v[h] : default
      end
      rec
    end

    def send_plan(plan, report, dry_run)
      if plan.empty?
        report << "nothing to send: the canister has every locked gem and the setup file already names them"
        return
      end

      plan.steps.each do |step|
        report << "#{dry_run ? 'would call' : 'call'} #{step.method}: #{step.note}"
        next if dry_run

        reply = Candid.decode(@runner.call(step.method, step.args)).first
        report << "  #{reply}"
      end
      report << (plan.generation ? "setup generation #{plan.generation} takes effect at the next upgrade" \
                                 : "the setup file is unchanged")
    end

    # Deploys the project as an upgrade, then checks the boot.
    def upgrade!(report)
      report << "call icp deploy --mode upgrade"
      @runner.deploy
      i = installed
      results = @config.verify.empty? ? [] : verify_calls(@config.verify)
      report.concat(results)
      report.concat(boot_lines(i))
      failed = results.grep(/\AFAIL /).size + boot_failures(i)
      raise VerifyFailed, report + ["upgraded, but #{failed} failed"] unless failed.zero?

      report << "upgraded: the boot loaded every gem#{@config.verify.empty? ? '' : " and #{results.size} verify names"}"
    end

    def verify_calls(names)
      Candid.decode(@runner.call("install_verify", Candid.texts_arg(names), query: true)).first
    end

    # What the target does not need sent: the gems its linked extensions
    # (`names`, require names) belong to, and on minimal the stand-ins the
    # lock's ruby_wasm_ic_minimal carries.
    def skips(target, locked, names)
      skip = Rules.linked_gems(names).to_h { [_1, "linked into the #{target.build} module, so it is not sent"] }
      minimal = target.build == "minimal" && locked.find { _1.name == MINIMAL }
      return skip unless minimal

      @gem_files.standins(minimal).to_h { [_1, "#{MINIMAL} stands in for #{_1} on a minimal canister"] }.merge(skip)
    end

    # The require names the target links, and the drift lines: the canister's
    # own list when it runs the target, else (a transition, or a canister half
    # or module that does not report one) this gem's table.
    def linked(target, i)
      table = Rules.linked(target)
      reported = i[:linked]
      return [table, []] if reported.nil? || !runs_target?(i, target)

      drift = []
      extra = reported - table
      missing = table - reported
      drift << "drift: the canister links #{extra.join(', ')}, which this Installer's table lacks" if extra.any?
      drift << "drift: this Installer's table has #{missing.join(', ')}, which the canister does not link" if missing.any?
      [reported, drift]
    end

    # The canister runs the target's Build, and its Release when both say a
    # real one.
    def runs_target?(i, target)
      rel = Rules.release?(i[:release]) ? i[:release] : nil
      i[:build] == target.build && (target.release.nil? || rel.nil? || rel == target.release)
    end

    # [warnings, notes] for the skipped linked gems: a locked version other
    # than the one the Build links, a gem the Build has as part of Ruby, or
    # one this gem does not mirror.
    def linked_versions(target, skipped, linked_gems)
      warnings = []
      notes = []
      skipped.select { linked_gems.include?(_1.name) }.each do |g|
        have = Rules.linked_version(target.build, g.name)
        if Rules.part_of_ruby?(g.name)
          notes << "#{g.name_version} is locked; #{target.build} carries #{g.name} as part of Ruby 3.3.3, not as a gem"
        elsif have.nil?
          notes << "#{g.name_version} is locked; #{target.build} links #{g.name}, a version this Installer does not mirror"
        elsif have != g.version
          warnings << "#{g.name_version} is locked; #{target.build} links #{g.name} #{have}, which is what will load"
        end
      end
      [warnings, notes]
    end

    # --strict (or strict: true) refuses what is otherwise a warning: a linked
    # version other than the lock's, and a target nothing declared or reported.
    def strict!(target, warnings, report)
      return unless @flags[:strict] || @config.strict

      msgs = warnings.dup
      msgs << "the target is assumed (#{target.build_source}): declare build: and release:" if target.assumed?
      return if msgs.empty?

      raise Refused, (report + ["refused (strict): nothing was sent:"] + msgs.map { "  #{_1}" }).join("\n")
    end

    def refuse!(target, gems, report)
      msgs = Rules.refused(target, gems)
      return if msgs.empty?

      raise Refused, (report + ["refused: nothing was sent:"] + msgs.map { "  #{_1}" }).join("\n")
    end

    def canister_lines(i)
      return ["canister half: protocol 1, which reports no Build and no load failures: run " \
              "`ruby_wasm_ic_installer setup` to update it"] if i[:protocol] < 2

      ["canister: protocol #{i[:protocol]}, #{i[:build] ? "build #{i[:build]}" : 'build not reported'}" \
       "#{i[:release] ? ", release #{i[:release]}" : ''}",
       *(i[:protocol] < 3 ? ["canister half: protocol #{i[:protocol]}, which reports no linked extensions: re-run " \
                             "`ruby_wasm_ic_installer setup` to update it"] : []),
       *(i[:protocol] == 3 ? ["canister half: protocol 3, which reports no Boot outcome: re-run " \
                              "`ruby_wasm_ic_installer setup` to update it"] : [])]
    end

    # The declared target against what the canister runs: a move to another
    # Build or Release. Release 0.0.0 (a CI dry run's module) is no Release.
    def transition_lines(i, target)
      from = [i[:build], (i[:release] if Rules.release?(i[:release]))].compact.join(" ")
      return [] if from.empty? || runs_target?(i, target)

      ["transition: the canister runs #{from}; this is for #{target}"]
    end

    # What the pending and running setups would load that the target refuses.
    def refusal_lines(target, i)
      pairs = (i[:load_paths] + i[:running_paths]).map { _1.split("/").first }.uniq.map { _1.rpartition("-").then { |a, _, v| [a, v] } }
      Rules.refused(target, pairs).map { "refuses #{target}: #{_1}" }
    end

    def known_line = "known releases: #{Rules::OLDEST_KNOWN} to #{Rules::NEWEST_KNOWN} (ruby_wasm_ic_installer #{VERSION})"

    # The Boot outcome, and the load failures read by it: rescued when the
    # boot reported it booted, clues when it reported failing, and failures
    # in their own right when it reported nothing. `hint`: say how to report
    # it, when the canister half could.
    def boot_lines(i, hint: false)
      case i[:boot]
      when nil
        unreported = hint && i[:protocol] >= 4 ? ["boot: not reported (call #{BOOT_CALL} at the end of the boot to report it)"] : []
        unreported + i[:load_failures].map { "load failure: #{_1}" }
      when "booted" then ["boot: booted", *i[:load_failures].map { "rescued during boot: #{_1}" }]
      else ["boot: #{i[:boot]}", *i[:load_failures].map { "before the failure: #{_1}" }]
      end
    end

    # What fails a verify or an upgrade: the boot's own error when it reported
    # one, nothing when it reported it booted, and else each load failure.
    def boot_failures(i)
      case i[:boot]
      when nil then i[:load_failures].size
      when "booted" then 0
      else 1
      end
    end

    def names_of(paths) = paths.map { _1.split("/").first }.uniq

    def pending_note(i)
      return "" if i[:pending].nil? || i[:pending] == i[:running]

      " (takes effect at the next upgrade)"
    end
  end
end
