# frozen_string_literal: true

# Reading an Application's Gemfile.lock (W29, Q8).
RSpec.describe RubyWasmIcInstaller::Lockfile do
  def lock(specs, platforms: %w[ruby], checksums: nil, extra: "")
    text = +"GEM\n  remote: https://rubygems.org/\n  specs:\n#{specs}\n#{extra}PLATFORMS\n"
    platforms.each { text << "  #{_1}\n" }
    text << "\nDEPENDENCIES\n  roda\n"
    text << "\nCHECKSUMS\n#{checksums}" if checksums
    text << "\nBUNDLED WITH\n   4.0.13\n"
  end

  it "lists each locked gem by name and version, in the lock's order, with its CHECKSUMS sha256" do
    sha = "a" * 64
    l = described_class.new(lock("    rack (3.1.8)\n    roda (3.109.0)\n      rack",
                                 checksums: "  rack (3.1.8) sha256=#{sha}\n  roda (3.109.0)\n"))
    expect(l.gems.map(&:to_h)).to eq([{ name: "rack", version: "3.1.8", sha256: sha },
                                      { name: "roda", version: "3.109.0", sha256: nil }])
    expect(l.gems.first.name_version).to eq("rack-3.1.8")
  end

  it "takes the ruby platform's entry when a gem is locked for several" do
    l = described_class.new(lock("    nokogumbo (2.0.5)\n    nokogumbo (2.0.5-x86_64-linux)",
                                 platforms: %w[ruby x86_64-linux]))
    expect(l.gems.map(&:name_version)).to eq(["nokogumbo-2.0.5"])
  end

  it "refuses a gem locked only for a native platform, saying how to fix the lock" do
    text = lock("    nokogiri (1.18.0-x86_64-linux)", platforms: %w[x86_64-linux])
    expect { described_class.new(text, path: "app/Gemfile.lock") }
      .to raise_error(RubyWasmIcInstaller::Error,
                      /nokogiri is locked only for x86_64-linux in app\/Gemfile.lock: only pure-Ruby.*add-platform ruby/)
  end

  it "refuses a gem from a git or path source" do
    git = "GIT\n  remote: https://github.com/x/y.git\n  revision: abc\n  specs:\n    y (0.1.0)\n\n"
    expect { described_class.new(lock("    rack (3.1.8)", extra: git)) }
      .to raise_error(RubyWasmIcInstaller::Error, /y comes from git .*only gems from a gem server/)
  end

  it "reads a lock from a file, and refuses a missing one" do
    Dir.mktmpdir do |d|
      File.write(File.join(d, "Gemfile.lock"), lock("    rack (3.1.8)"))
      expect(described_class.read(File.join(d, "Gemfile.lock")).gems.map(&:name)).to eq(["rack"])
      expect { described_class.read(File.join(d, "nope.lock")) }.to raise_error(RubyWasmIcInstaller::Error, /bundle lock/)
    end
  end
end
