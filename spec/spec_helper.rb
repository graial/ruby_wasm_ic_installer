# frozen_string_literal: true

# Layer 2 (W29, Q18): line coverage of lib/, with a floor CI enforces on the
# whole suite. `rake e2e` runs the end-to-end spec alone, which covers lib/
# through a subprocess, so it sets E2E_ONLY and the floor is not applied.
require "simplecov"
SimpleCov.start do
  enable_coverage :line
  add_filter "/spec/"
  minimum_coverage line: 95 unless ENV["E2E_ONLY"]
end

require "tmpdir"
require "fileutils"
require_relative "support/fake_ic"
require "ruby_wasm_ic_installer"
require "ruby_wasm_ic_installer/canister"
require_relative "support/gem_factory"
require_relative "support/in_memory_canister"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # The canister half changes $LOAD_PATH at boot; each example gets its own.
  config.around do |ex|
    saved = $LOAD_PATH.dup
    ex.run
  ensure
    $LOAD_PATH.replace(saved)
    RubyWasmIcInstaller::Canister.data_dir = nil
    IC.controller = true
  end
end
