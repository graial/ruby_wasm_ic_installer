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

    # The version of each linked gem a Build carries: Ruby 3.3.3's, read by
    # the builder from its Release Bundle's default gemspecs.
    LINKED_VERSIONS = {
      "full" => { "bigdecimal" => "3.1.5", "cgi" => "0.4.1", "date" => "3.3.4", "digest" => "3.1.1",
                  "etc" => "1.4.3", "fcntl" => "1.1.0", "json" => "2.7.1", "nkf" => "0.1.3", "openssl" => "3.2.0",
                  "pathname" => "0.3.0", "psych" => "5.1.2", "stringio" => "3.1.1", "strscan" => "3.0.9",
                  "zlib" => "3.1.1" }.freeze
    }.freeze

    # Linked names that Ruby 3.3.3 ships as part of Ruby, with no gemspec: a
    # lock that pins a gem of one of these names gets a note, never a warning.
    PART_OF_RUBY = %w[continuation coverage monitor objspace rbconfig ripper].freeze

    # Built-in gems: compiled into the Ruby both Builds carry (3.3.3), not
    # linked as an extension, so `require` finds them with nothing sent. A
    # locked version is another gem, which cannot replace the built-in one.
    BUILT_IN = { "prism" => "0.19.0" }.freeze

    # The builder Releases these tables were checked against (ADR 0001). A
    # target before the oldest is refused; one after the newest is warned of.
    OLDEST_KNOWN = ::Gem::Version.new("0.13.0")
    NEWEST_KNOWN = ::Gem::Version.new("0.15.0")
    KNOWN_RELEASES = ::Gem::Requirement.new(">= #{OLDEST_KNOWN}", "<= #{NEWEST_KNOWN}")

    # The Release a CI dry run's module reports: not a Release.
    NO_RELEASE = "0.0.0"

    # A gem (and versions of it) that refuses to load on a target, on one
    # Build, or on every Build when `build` is nil.
    Refusal = Struct.new(:gem, :build, :gem_versions, :message, keyword_init: true)

    REFUSALS = [
      Refusal.new(gem: "ruby_wasm_ic_minimal", build: "full",
                  message: "ruby_wasm_ic_minimal is for `minimal` and refuses to load on `full`: remove it from the " \
                           "Gemfile: `full` links the real extensions"),
      Refusal.new(gem: "ruby_wasm_ic_minimal", build: "minimal", gem_versions: "< 0.1.5",
                  message: "ruby_wasm_ic_minimal before 0.1.5 refuses to load on minimal 0.13.0 or later: " \
                           "update it to 0.1.5 or later"),
      *BUILT_IN.map do |gem, version|
        Refusal.new(gem: gem, message: "Ruby 3.3.3 has #{gem.capitalize} #{version} built in, which " \
                                       "`require \"#{gem}\"` loads; the locked version cannot replace it: remove " \
                                       "#{gem} from the lock, or leave it out of what you install")
      end
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
      return false unless rule.gem == name && (rule.build.nil? || rule.build == target.build)

      !rule.gem_versions || ::Gem::Requirement.new(rule.gem_versions).satisfied_by?(::Gem::Version.new(version))
    end

    def linked(target) = LINKED.fetch(target.build, [])

    def linked_gems(names) = names.map { |n| GEM_OF.fetch(n) { n.split("/").first } }.uniq

    def linked_version(build, gem) = LINKED_VERSIONS.fetch(build, {})[gem]

    def part_of_ruby?(gem) = PART_OF_RUBY.include?(gem)

    def release?(release) = !release.nil? && release != NO_RELEASE
  end
end
