# frozen_string_literal: true

module RubyWasmIcInstaller
  # What depends on the target Build and Release. Each table is this gem's
  # mirror of the builder's: a change to it is a release of this gem.
  module Rules
    # C extensions each Build links in itself, so the lock's gems of these
    # names are skipped, not sent (and not refused as C extensions).
    LINKED = { "full" => %w[stringio strscan].freeze }.freeze

    # A gem (and versions of it) that refuses to load on a target.
    Refusal = Struct.new(:gem, :build, :gem_versions, :releases, :message, keyword_init: true)

    REFUSALS = [
      Refusal.new(gem: "ruby_wasm_ic_minimal", build: "full",
                  message: "ruby_wasm_ic_minimal is for `minimal` and refuses to load on `full`: remove it from the " \
                           "Gemfile: `full` links the real extensions"),
      Refusal.new(gem: "ruby_wasm_ic_minimal", build: "minimal", gem_versions: "< 0.1.5", releases: ">= 0.13.0",
                  message: "ruby_wasm_ic_minimal before 0.1.5 refuses to load on minimal 0.13.0 or later: " \
                           "update it to 0.1.5 or later")
    ].freeze

    module_function

    # The messages of every Refusal the `gems` ([name, version] pairs) hit on
    # `target`.
    def refused(target, gems)
      gems.flat_map do |name, version|
        REFUSALS.select { hit?(_1, target, name, version) }.map { "#{name}-#{version}: #{_1.message}" }
      end
    end

    def hit?(rule, target, name, version)
      return false unless rule.gem == name && rule.build == target.build
      return false if rule.gem_versions && !::Gem::Requirement.new(rule.gem_versions).satisfied_by?(::Gem::Version.new(version))
      return true unless rule.releases

      rel = target.release_version
      !rel.nil? && ::Gem::Requirement.new(rule.releases).satisfied_by?(rel)
    end

    def linked(target) = LINKED.fetch(target.build, [])
  end
end
