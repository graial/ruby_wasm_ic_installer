# frozen_string_literal: true

require_relative "lib/ruby_wasm_ic_installer/version"

Gem::Specification.new do |s|
  s.name        = "ruby_wasm_ic_installer"
  s.version     = RubyWasmIcInstaller::VERSION
  s.summary     = "Install pure-Ruby gems into a Ruby canister on the Internet Computer, through calls"
  s.description = "The Installer for canisters packed by ruby_wasm_builder: reads an Application's " \
                  "Gemfile.lock, fetches its pure-Ruby gems and sends the ones a canister lacks through " \
                  "`icp canister call`, into /data, where a carried canister half loads them at the next boot. " \
                  "`setup` wires the canister half into an Application."
  s.authors     = ["the ruby_wasm_builder authors"]
  s.license     = "MIT"
  s.homepage    = "https://github.com/graial/ruby_wasm_ic_installer"
  s.metadata    = { "source_code_uri" => "https://github.com/graial/ruby_wasm_ic_installer",
                    "rubygems_mfa_required" => "true" }
  s.files       = Dir["lib/**/*.rb"] + Dir["exe/*"] + %w[README.md LICENSE]
  s.bindir      = "exe"
  s.executables = ["ruby_wasm_ic_installer"]
  s.required_ruby_version = ">= 3.2"
end
