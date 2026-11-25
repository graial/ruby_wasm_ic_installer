# frozen_string_literal: true

RSpec.describe RubyWasmIcInstaller::Config do
  def read(text)
    Dir.mktmpdir do |dir|
      path = File.join(dir, described_class::FILE)
      File.write(path, text)
      described_class.read(path)
    end
  end

  it "reads build, release and verify" do
    c = read("build: full\nrelease: 0.13.0\nverify: [roda, ruby_wasm_ic_rack]\n")
    expect([c.build, c.release, c.verify]).to eq(["full", "0.13.0", %w[roda ruby_wasm_ic_rack]])
  end

  it "reads strict, false when absent" do
    expect(read("strict: true\n").strict).to be(true)
    expect(read("").strict).to be(false)
  end

  it "takes a numeric release as written" do
    expect(read("release: 0.13\n").release).to eq("0.13")
  end

  it "is empty when the file is absent or blank" do
    expect(described_class.read("/no/such/file").verify).to eq([])
    expect(read("").build).to be_nil
    expect(described_class.empty.release).to be_nil
  end

  it "says where it is default" do
    expect(described_class.default_path(nil)).to eq("./.ruby_wasm_ic_installer.yml")
    expect(described_class.default_path("/p")).to eq("/p/.ruby_wasm_ic_installer.yml")
  end

  it "refuses what it cannot read" do
    expect { read("build: huge\n") }.to raise_error(RubyWasmIcInstaller::Error, /build must be one of minimal, full/)
    expect { read("release: soon\n") }.to raise_error(RubyWasmIcInstaller::Error, /release must be a version/)
    expect { read("verify: roda\n") }.to raise_error(RubyWasmIcInstaller::Error, /verify must be a list/)
    expect { read("strict: yes please\n") }.to raise_error(RubyWasmIcInstaller::Error, /strict must be true or false/)
    expect { read("buid: full\n") }.to raise_error(RubyWasmIcInstaller::Error, /unknown key buid/)
    expect { read("- a\n") }.to raise_error(RubyWasmIcInstaller::Error, /must be a YAML mapping/)
    expect { read("a: [\n") }.to raise_error(RubyWasmIcInstaller::Error, /not valid YAML/)
  end
end

RSpec.describe RubyWasmIcInstaller::Target do
  def config(text = "")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "c.yml")
      File.write(path, text)
      RubyWasmIcInstaller::Config.read(path)
    end
  end

  it "takes the flags first, then the config, then the canister's report" do
    c = config("build: full\nrelease: 0.13.0\n")
    t = described_class.resolve(flags: { build: "minimal" }, config: c, info: { build: "full", release: "0.14.0" })
    expect([t.build, t.build_source, t.release, t.release_source]).to eq(["minimal", "--build", "0.13.0", c.path])
    t = described_class.resolve(flags: {}, config: config, info: { build: "full", release: "0.14.0" })
    expect(t.describe).to eq("target: full 0.14.0 (build from the canister, release from the canister)")
  end

  it "takes a reported Release 0.0.0 as no Release" do
    t = described_class.resolve(flags: {}, config: config, info: { build: "full", release: "0.0.0" })
    expect([t.release, t.release_version, t.assumed?]).to eq([nil, nil, false])
  end

  it "assumes minimal, and says so, when nothing says otherwise" do
    t = described_class.resolve(flags: {}, config: config, info: {})
    expect([t.build, t.release]).to eq(["minimal", nil])
    expect(t.describe).to start_with("target: minimal (build from assumed: no --build")
    expect(t.release_version).to be_nil
  end
end

RSpec.describe RubyWasmIcInstaller::Rules do
  def target(build, release = nil)
    RubyWasmIcInstaller::Target.new(build: build, release: release)
  end

  it "refuses ruby_wasm_ic_minimal on full, naming the fix" do
    msgs = described_class.refused(target("full", "0.13.0"), [["ruby_wasm_ic_minimal", "0.1.5"], ["rack", "3.1.8"]])
    expect(msgs.size).to eq(1)
    expect(msgs.first).to include("ruby_wasm_ic_minimal-0.1.5", "remove it from the Gemfile: `full` links the real extensions")
  end

  it "refuses ruby_wasm_ic_minimal before 0.1.5 on minimal 0.13.0 and later, and only there" do
    old = [["ruby_wasm_ic_minimal", "0.1.4"]]
    expect(described_class.refused(target("minimal", "0.13.0"), old).first).to include("update it to 0.1.5")
    expect(described_class.refused(target("minimal", "0.12.0"), old)).to eq([])
    expect(described_class.refused(target("minimal"), old)).to eq([])
    expect(described_class.refused(target("minimal", "0.13.0"), [["ruby_wasm_ic_minimal", "0.1.5"]])).to eq([])
  end
end
