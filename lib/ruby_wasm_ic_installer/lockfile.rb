# frozen_string_literal: true

require "bundler"

module RubyWasmIcInstaller
  class Error < StandardError; end

  # An Application's Gemfile.lock, read with Bundler's own parser (W29, Q8):
  # each locked gem as a name and version, in the lock's order, with the
  # sha256 the lock's CHECKSUMS section gives for its `ruby` platform, if any.
  # Nothing is resolved or installed: the lock is the author's decision.
  class Lockfile
    Gem = Struct.new(:name, :version, :sha256, keyword_init: true) do
      def name_version = "#{name}-#{version}"
    end

    attr_reader :gems

    def self.read(path)
      raise Error, "no lockfile at #{path}: run `bundle lock` first" unless File.file?(path)

      new(File.read(path), path: path)
    end

    def initialize(text, path: "Gemfile.lock")
      @path = path
      parser = Bundler::LockfileParser.new(text)
      @gems = to_gems(parser.specs, checksums(text))
    end

    private

    # One entry per name: its `ruby` platform spec. A gem locked only for a
    # native platform cannot be installed, which pure Ruby only means.
    def to_gems(specs, sums)
      by_name = specs.group_by(&:name)
      by_name.map do |name, list|
        spec = list.find { |s| s.platform.to_s == "ruby" }
        unless spec
          raise Error, "#{name} is locked only for #{list.map { _1.platform.to_s }.uniq.join(', ')} in #{@path}: " \
                       "only pure-Ruby gems can be installed into a canister " \
                       "(run `bundle lock --add-platform ruby`, or drop the gem)"
        end
        source = spec.source
        unless source.is_a?(Bundler::Source::Rubygems)
          raise Error, "#{name} comes from #{source.class.name.split('::').last.downcase} in #{@path}: " \
                       "only gems from a gem server can be installed"
        end
        Gem.new(name: name, version: spec.version.to_s, sha256: sums["#{name}-#{spec.version}"])
      end
    end

    # The CHECKSUMS section's `ruby`-platform sha256 for each name-version.
    def checksums(text)
      section = text[/^CHECKSUMS\n(.*?)(?:\n\S|\z)/m, 1].to_s
      section.lines.each_with_object({}) do |line, h|
        next unless (m = line.match(/\A\s+(\S+) \(([^)\s]+)\) sha256=([0-9a-f]{64})/))

        h["#{m[1]}-#{m[2]}"] = m[3]
      end
    end
  end
end
