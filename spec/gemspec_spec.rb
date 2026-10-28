# frozen_string_literal: true

# The release itself: ruby_wasm_ic_rack and ruby_wasm_ic_minimal 0.1.0 were
# published empty (no spec.files), so this one checks what it packs.
RSpec.describe "the gemspec" do
  root = File.expand_path("..", __dir__)
  spec = Dir.chdir(root) { Gem::Specification.load("ruby_wasm_ic_installer.gemspec") }

  it "packs every lib file, the executable, the README and the LICENSE, and no spec" do
    lib = Dir.chdir(root) { Dir["lib/**/*.rb"] }
    expect(spec.files).to include(*lib, "exe/ruby_wasm_ic_installer", "README.md", "LICENSE")
    expect(lib).to include("lib/ruby_wasm_ic_installer/canister.rb")
    expect(spec.files.grep(/\Aspec\//)).to eq([])
  end

  it "is this version, MIT, with no runtime dependency, and installs the command" do
    expect([spec.name, spec.version.to_s, spec.license]).to eq(["ruby_wasm_ic_installer", RubyWasmIcInstaller::VERSION, "MIT"])
    expect(spec.runtime_dependencies).to eq([])
    expect(spec.executables).to eq(["ruby_wasm_ic_installer"])
  end
end
