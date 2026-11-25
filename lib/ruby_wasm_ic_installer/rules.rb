# frozen_string_literal: true

module RubyWasmIcInstaller
  # What depends on the target Build and Release. Each table is this gem's
  # mirror of the builder's: a change to it is a release of this gem.
  module Rules
    # The C extensions each Build links, by require name, as
    # IC::LINKED_EXTENSIONS reports them. `full` is the same from 0.13.0, its
    # first Release, and a builder Challenge pins it; `minimal` links none.
    LINKED = {
      "full" => %w[bigdecimal cgi/escape continuation coverage date_core digest digest/bubblebabble digest/md5
                   digest/rmd160 digest/sha1 digest/sha2 etc fcntl json/ext/generator json/ext/parser monitor nkf
                   objspace openssl pathname psych rbconfig/sizeof ripper stringio strscan zlib].freeze
    }.freeze

    # A linked require name's gem, where it is not the name's first segment.
    GEM_OF = { "date_core" => "date" }.freeze

    # The version of each linked gem a Build carries: Ruby 3.3.6's, from the
    # builder's Release Bundle. The builder named these nine; a linked gem
    # missing here is skipped with a note, not a warning.
    LINKED_VERSIONS = {
      "full" => { "bigdecimal" => "3.1.5", "date" => "3.3.4", "digest" => "3.1.1", "json" => "2.7.1",
                  "nkf" => "0.1.3", "openssl" => "3.2.0", "psych" => "5.1.2", "stringio" => "3.1.1",
                  "strscan" => "3.0.9" }.freeze
    }.freeze

    # The first Release with a `full` Build.
    FULL_FROM = ::Gem::Version.new("0.13.0")

    # From this Release both Builds link every Ruby 3.3 encoding; before it a
    # canister has three (MagicComment).
    EVERY_ENCODING_FROM = ::Gem::Version.new("0.13.0")

    # The Release a CI dry run's module reports: not a Release.
    NO_RELEASE = "0.0.0"

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

    def linked_gems(names) = names.map { |n| GEM_OF.fetch(n) { n.split("/").first } }.uniq

    def linked_version(build, gem) = LINKED_VERSIONS.fetch(build, {})[gem]

    def release?(release) = !release.nil? && release != NO_RELEASE

    def every_encoding?(release_version) = !release_version.nil? && release_version >= EVERY_ENCODING_FROM
  end
end
