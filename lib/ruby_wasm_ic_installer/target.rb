# frozen_string_literal: true

module RubyWasmIcInstaller
  # The Build and Release an install is for. Resolved, highest first, from
  # the --build / --release flags, the config file (the declared target), the
  # canister's own report (what it runs now), and last the assumption that the
  # canister is `minimal`, which is what 0.1.x always assumed. A canister
  # reporting Release 0.0.0 (a CI dry run's module) reports no Release.
  Target = Struct.new(:build, :release, :build_source, :release_source, :assumed, keyword_init: true) do
    def self.resolve(flags:, config:, info:)
      build, bsrc = pick(flags[:build], "--build", config.build, config.path, info[:build], "the canister")
      reported = Rules.release?(info[:release]) ? info[:release] : nil
      release, rsrc = pick(flags[:release], "--release", config.release, config.path, reported, "the canister")
      assumed = build.nil?
      if assumed
        build = "minimal"
        bsrc = "assumed: no --build, no #{Config::FILE}, and the canister does not report its Build"
      end
      new(build: Config.check_build(build, bsrc), release: release && Config.check_release(release, rsrc),
          build_source: bsrc, release_source: rsrc, assumed: assumed).tap(&:check!)
    end

    def self.pick(flag, flag_name, declared, path, reported, who)
      return [flag, flag_name] if flag
      return [declared, path] if declared
      return [reported, who] if reported

      [nil, nil]
    end

    def to_s = [build, release].compact.join(" ")

    def describe
      src = ["build from #{build_source}", *(release ? ["release from #{release_source}"] : [])].join(", ")
      "target: #{self} (#{src})"
    end

    # nil when the Release is unknown, or 0.0.0.
    def release_version = Rules.release?(release) ? ::Gem::Version.new(release) : nil

    def assumed? = assumed == true

    # What the target's Release says about this Installer's tables: a warning
    # when it is newer than every Known Release.
    def warnings
      return [] unless release_version && !Rules::KNOWN_RELEASES.satisfied_by?(release_version)

      ["release #{release} is newer than this Installer knows (#{Rules::NEWEST_KNOWN} at most): " \
       "its tables may be out of date"]
    end

    def check!
      return unless release_version && release_version < Rules::OLDEST_KNOWN

      raise Error, "#{release_source}: release #{release} is older than this Installer knows " \
                   "(#{Rules::OLDEST_KNOWN} or later)"
    end
  end
end
