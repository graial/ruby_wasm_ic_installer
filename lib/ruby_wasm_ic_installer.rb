# frozen_string_literal: true

# ruby_wasm_ic_installer: the Installer (W29). Its off-chain half, loaded
# here, sends an Application's pure-Ruby gems into a Ruby canister packed by
# ruby_wasm_builder; its canister half, ruby_wasm_ic_installer/canister.rb,
# is carried by the Application and is never loaded by this file.
module RubyWasmIcInstaller
  class Error < StandardError; end
end

require_relative "ruby_wasm_ic_installer/version"
require_relative "ruby_wasm_ic_installer/candid"
require_relative "ruby_wasm_ic_installer/lockfile"
require_relative "ruby_wasm_ic_installer/magic_comment"
require_relative "ruby_wasm_ic_installer/gem_files"
require_relative "ruby_wasm_ic_installer/plan"
require_relative "ruby_wasm_ic_installer/runner"
require_relative "ruby_wasm_ic_installer/installer"
require_relative "ruby_wasm_ic_installer/diff"
require_relative "ruby_wasm_ic_installer/app_setup"
require_relative "ruby_wasm_ic_installer/cli"
