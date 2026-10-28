# frozen_string_literal: true

require "rubygems/package"

# Builds real .gem files for the specs, and a fetcher that hands them out as
# `gem fetch` would, so GemFiles and the Installer run on genuine packages
# with no network.
class GemFactory
  attr_reader :dir, :fetched

  def initialize(dir)
    @dir = dir
    @fetched = []
  end

  # files: { "lib/x.rb" => "source" }, braced or not (a braceless one arrives
  # as keywords with String keys).
  def build(name, version, files = nil, require_paths: ["lib"], extensions: [], platform: "ruby", **more)
    files = (files || {}).merge(more.transform_keys(&:to_s))
    src = File.join(@dir, "src", "#{name}-#{version}")
    files.each do |rel, body|
      FileUtils.mkdir_p(File.dirname(File.join(src, rel)))
      File.binwrite(File.join(src, rel), body)
    end
    spec = Gem::Specification.new do |s|
      s.name = name
      s.version = version
      s.summary = "a test gem"
      s.authors = ["test"]
      s.files = files.keys
      s.require_paths = require_paths
      s.extensions = extensions
      s.platform = platform
    end
    out = Dir.chdir(src) { Gem::Package.build(spec) }
    FileUtils.mkdir_p(File.join(@dir, "server"))
    FileUtils.mv(File.join(src, out), File.join(@dir, "server", "#{name}-#{version}.gem"))
    File.join(@dir, "server", "#{name}-#{version}.gem")
  end

  def fetcher
    lambda do |name, version, into|
      @fetched << "#{name}-#{version}"
      from = File.join(@dir, "server", "#{name}-#{version}.gem")
      raise RubyWasmIcInstaller::GemFiles::Refused, "no such gem #{name}-#{version}" unless File.file?(from)

      FileUtils.cp(from, into)
    end
  end
end
