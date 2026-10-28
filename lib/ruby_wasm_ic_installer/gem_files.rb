# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "rubygems/package"
require "tmpdir"

module RubyWasmIcInstaller
  # One locked gem made ready to send (W29, Q8 and Q9): its `.gem` fetched
  # for platform `ruby` (or found in the cache), checked against the lock's
  # sha256 when the lock has one, refused if it has extensions, and opened
  # for its require_paths alone, with magic comments fixed.
  class GemFiles
    Prepared = Struct.new(:name_version, :require_paths, :files, :rewrites, keyword_init: true) do
      def bytes = files.sum { _2.bytesize }
    end

    class Refused < Error; end

    # `fetcher` is called as fetcher.(name, version, dir) and must leave
    # "<name>-<version>.gem" in dir; the default runs `gem fetch`.
    def initialize(cache:, fetcher: nil)
      @cache = cache
      @fetcher = fetcher || method(:gem_fetch)
    end

    def prepare(locked)
      path = fetch(locked)
      check_sum!(locked, path)
      package = ::Gem::Package.new(path)
      spec = package.spec
      check_spec!(locked, spec)
      files, rewrites = read_files(locked, package, spec)
      paths = spec.require_paths.select { |rp| files.keys.any? { _1.start_with?("#{rp}/") } }
      raise Refused, "#{locked.name_version} has no files under #{spec.require_paths.join(', ')}" if paths.empty?

      Prepared.new(name_version: locked.name_version, require_paths: paths, files: files, rewrites: rewrites)
    end

    # The stand-ins a fetched ruby_wasm_ic_minimal carries: the libraries it
    # stands in for, so the locked gems of those names are skipped.
    def standins(locked)
      package = ::Gem::Package.new(fetch(locked))
      Dir.mktmpdir do |dir|
        package.extract_files(dir, "lib/ruby_wasm_ic_minimal/standins/*.rb")
        Dir.children(File.join(dir, "lib/ruby_wasm_ic_minimal/standins")).map { File.basename(_1, ".rb") }
           .reject { _1 == "encoding_constants" }.sort
      end
    rescue Errno::ENOENT
      []
    end

    private

    def fetch(locked)
      FileUtils.mkdir_p(@cache)
      path = File.join(@cache, "#{locked.name_version}.gem")
      return path if File.file?(path)

      Dir.mktmpdir do |dir|
        @fetcher.call(locked.name, locked.version, dir)
        got = File.join(dir, "#{locked.name_version}.gem")
        raise Refused, "fetching #{locked.name_version} left no #{File.basename(got)}" unless File.file?(got)

        FileUtils.mv(got, path)
      end
      path
    end

    def gem_fetch(name, version, dir)
      out, status = Open3.capture2e("gem", "fetch", name, "--version", version, "--platform", "ruby", chdir: dir)
      raise Refused, "gem fetch #{name} #{version} failed:\n#{out}" unless status.success?
    end

    def check_sum!(locked, path)
      return unless locked.sha256

      have = Digest::SHA256.file(path).hexdigest
      return if have == locked.sha256

      raise Refused, "#{locked.name_version}.gem has sha256 #{have}, and the lock says #{locked.sha256}"
    end

    def check_spec!(locked, spec)
      unless spec.platform.to_s == "ruby"
        raise Refused, "#{locked.name_version} was fetched for #{spec.platform}, not ruby: only pure-Ruby gems " \
                       "can be installed into a canister"
      end
      return if spec.extensions.empty?

      raise Refused, "#{locked.name_version} has a C extension (#{spec.extensions.join(', ')}): only pure-Ruby " \
                     "gems can be installed into a canister, which cannot load compiled code"
    end

    def read_files(locked, package, spec)
      files = {}
      rewrites = []
      Dir.mktmpdir do |dir|
        # extract_files matches without FNM_PATHNAME, so "*" crosses "/":
        # "lib/*" is every file at every depth under lib/ ("lib/**/*" would
        # miss lib/rack.rb itself).
        spec.require_paths.each { |rp| package.extract_files(dir, "#{rp}/*") }
        spec.require_paths.each do |rp|
          base = File.join(dir, rp)
          next unless File.directory?(base)

          Dir.glob("**/*", File::FNM_DOTMATCH, base: base).sort.each do |rel|
            full = File.join(base, rel)
            next unless File.file?(full)

            body = File.binread(full)
            path = "#{rp}/#{rel}"
            if rel.end_with?(".rb")
              body, rewrite = MagicComment.fix("#{locked.name_version}/#{path}", body)
              rewrites << rewrite if rewrite
            end
            files[path] = body
          end
        end
      end
      [files, rewrites]
    end
  end
end
