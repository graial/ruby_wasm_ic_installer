# frozen_string_literal: true

module RubyWasmIcInstaller
  # The Build and Release an install is for. Resolved, highest first, from
  # the --build / --release flags, the config file (the declared target), the
  # canister's own report (what it runs now), and last the assumption that the
  # canister is `minimal`, which is what 0.1.x always assumed.
  Target = Struct.new(:build, :release, :build_source, :release_source, keyword_init: true) do
    def self.resolve(flags:, config:, info:)
      build, bsrc = pick(flags[:build], "--build", config.build, config.path, info[:build], "the canister")
      release, rsrc = pick(flags[:release], "--release", config.release, config.path, info[:release], "the canister")
      if build.nil?
        build = "minimal"
        bsrc = "assumed: no --build, no #{Config::FILE}, and the canister does not report its Build"
      end
      new(build: Config.check_build(build, bsrc), release: release && Config.check_release(release, rsrc),
          build_source: bsrc, release_source: rsrc)
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

    def release_version = release && ::Gem::Version.new(release)
  end
end
