# frozen_string_literal: true

# The Installer's mirror of the builder's tables (the builder's reply on the
# linked list by Release, 25 November 2026).
RSpec.describe RubyWasmIcInstaller::Rules do
  r = described_class

  def target(build, release = nil) = RubyWasmIcInstaller::Target.new(build: build, release: release)

  it "mirrors the 26 require names full links, and none for minimal" do
    expect(r.linked(target("full")).size).to eq(26)
    expect(r.linked(target("full"))).to include("json/ext/parser", "date_core", "digest/sha2", "stringio", "zlib")
    expect(r.linked(target("minimal"))).to eq([])
  end

  it "maps require names to gem names: the first segment, and date_core to date" do
    expect(r.linked_gems(%w[json/ext/generator json/ext/parser date_core digest digest/sha2 cgi/escape ripper]))
      .to eq(%w[json date digest cgi ripper])
  end

  it "knows the version full links of the gems the builder named, and not of the others" do
    expect(r.linked_version("full", "json")).to eq("2.7.1")
    expect(r.linked_version("full", "psych")).to eq("5.1.2")
    expect(r.linked_version("full", "zlib")).to be_nil
  end

  it "accepts every encoding from Release 0.13.0, and not before or when the Release is unknown" do
    expect(r.every_encoding?(Gem::Version.new("0.13.0"))).to be(true)
    expect(r.every_encoding?(Gem::Version.new("0.14.0"))).to be(true)
    expect(r.every_encoding?(Gem::Version.new("0.12.0"))).to be(false)
    expect(r.every_encoding?(nil)).to be(false)
  end

  it "treats 0.0.0, a CI dry run's module, as no Release" do
    expect(r.release?("0.0.0")).to be(false)
    expect(r.release?(nil)).to be(false)
    expect(r.release?("0.13.0")).to be(true)
  end
end
