# frozen_string_literal: true

require "yaml"

module RubyWasmIcInstaller
  # The developer's declaration of what the canister is meant to run, read
  # from `.ruby_wasm_ic_installer.yml` in the icp project (or --config):
  #
  #   build: full          # minimal | full
  #   release: 0.13.0      # the ruby_wasm_builder Release
  #   verify: [roda]       # require names `verify` checks on the canister
  #   strict: true         # refuse, not warn, on a linked version or an assumed target
  #
  # Every key is optional. The file is the desired state; the canister is the
  # observed state; the Installer reconciles them and keeps no state of its own.
  class Config
    FILE = ".ruby_wasm_ic_installer.yml"
    BUILDS = %w[minimal full].freeze
    KEYS = %w[build release verify strict].freeze

    attr_reader :build, :release, :verify, :strict, :path

    def self.default_path(project_root) = File.join(project_root || ".", FILE)

    def self.empty = new({}, path: nil)

    # An absent file is an empty Config; a malformed one is an Error.
    def self.read(path)
      return empty unless File.file?(path)

      data = YAML.safe_load_file(path) || {}
      raise Error, "#{path} must be a YAML mapping" unless data.is_a?(Hash)

      new(data, path: path)
    rescue Psych::Exception => e
      raise Error, "#{path} is not valid YAML: #{e.message}"
    end

    def initialize(data, path:)
      @path = path
      unknown = data.keys.map(&:to_s) - KEYS
      raise Error, "#{path}: unknown key #{unknown.join(', ')} (known: #{KEYS.join(', ')})" unless unknown.empty?

      @build = self.class.check_build(data["build"], path)
      @release = self.class.check_release(data["release"], path)
      @verify = check_verify(data["verify"])
      @strict = check_strict(data["strict"])
    end

    def self.check_build(value, where)
      return nil if value.nil?
      return value.to_s if BUILDS.include?(value.to_s)

      raise Error, "#{where}: build must be one of #{BUILDS.join(', ')}, not #{value.inspect}"
    end

    def self.check_release(value, where)
      return nil if value.nil?
      return value.to_s if ::Gem::Version.correct?(value.to_s)

      raise Error, "#{where}: release must be a version such as 0.13.0, not #{value.inspect}"
    end

    private

    def check_verify(value)
      return [] if value.nil?
      return value if value.is_a?(Array) && value.all?(String)

      raise Error, "#{@path}: verify must be a list of require names"
    end

    def check_strict(value)
      return false if value.nil?
      return value if [true, false].include?(value)

      raise Error, "#{@path}: strict must be true or false, not #{value.inspect}"
    end
  end
end
