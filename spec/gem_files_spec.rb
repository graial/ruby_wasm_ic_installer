# frozen_string_literal: true

require "digest"

# A locked gem made ready to send (W29, Q8 and Q9), on real .gem files built
# by the specs and handed out by a fake `gem fetch`.
RSpec.describe RubyWasmIcInstaller::GemFiles do
  locked = ->(name, version, sha = nil) { RubyWasmIcInstaller::Lockfile::Gem.new(name: name, version: version, sha256: sha) }

  around do |ex|
    Dir.mktmpdir do |dir|
      @factory = GemFactory.new(dir)
      @files = described_class.new(cache: File.join(dir, "cache"), fetcher: @factory.fetcher)
      ex.run
    end
  end

  it "opens only the gem's require_paths, fixing magic comments on the way" do
    @factory.build("rack", "3.1.8", "lib/rack.rb" => "module Rack; end\n",
                                    "lib/rack/utils.rb" => "# -*- encoding: binary -*-\nx\n",
                                    "lib/rack/data.txt" => "# encoding: binary\n",
                                    "README.md" => "# Rack", "test/t.rb" => "t")
    p = @files.prepare(locked.("rack", "3.1.8"))
    expect(p.name_version).to eq("rack-3.1.8")
    expect(p.require_paths).to eq(["lib"])
    expect(p.files).to eq("lib/rack.rb" => "module Rack; end\n", "lib/rack/data.txt" => "# encoding: binary\n",
                          "lib/rack/utils.rb" => "# -*- encoding: ascii-8bit -*-\nx\n")
    expect(p.rewrites.map(&:to_h)).to eq([{ file: "rack-3.1.8/lib/rack/utils.rb", line: 1, from: "binary",
                                            to: "ascii-8bit" }])
    expect(p.bytes).to eq(p.files.values.sum(&:bytesize))
  end

  it "keeps every require_path that holds files, and drops one that holds none" do
    @factory.build("two", "1.0.0", { "lib/two.rb" => "1", "ext_lib/two_ext.rb" => "2" },
                   require_paths: %w[lib ext_lib empty])
    expect(@files.prepare(locked.("two", "1.0.0")).require_paths).to eq(%w[lib ext_lib])
  end

  it "refuses a gem with no files under its require_paths" do
    @factory.build("hollow", "1.0.0", "README.md" => "nothing")
    expect { @files.prepare(locked.("hollow", "1.0.0")) }.to raise_error(described_class::Refused, /no files under lib/)
  end

  it "refuses a gem with a C extension, naming it" do
    @factory.build("json", "2.9.1", { "lib/json.rb" => "", "ext/json/extconf.rb" => "" },
                   extensions: ["ext/json/extconf.rb"])
    expect { @files.prepare(locked.("json", "2.9.1")) }
      .to raise_error(described_class::Refused, /json-2.9.1 has a C extension \(ext\/json\/extconf.rb\): only pure-Ruby/)
  end

  it "refuses a gem built for a native platform" do
    @factory.build("native", "1.0.0", { "lib/n.rb" => "" }, platform: "x86_64-linux")
    expect { @files.prepare(locked.("native", "1.0.0")) }.to raise_error(described_class::Refused, /x86_64-linux, not ruby/)
  end

  it "refuses a gem whose bytes are not the lock's sha256, and accepts the right one" do
    path = @factory.build("rack", "3.1.8", "lib/rack.rb" => "R")
    sha = Digest::SHA256.file(path).hexdigest
    expect { @files.prepare(locked.("rack", "3.1.8", "0" * 64)) }.to raise_error(described_class::Refused, /the lock says 0000/)
    expect(@files.prepare(locked.("rack", "3.1.8", sha)).files).to eq("lib/rack.rb" => "R")
  end

  it "fetches each version once, then reads it from the cache" do
    @factory.build("rack", "3.1.8", "lib/rack.rb" => "R")
    2.times { @files.prepare(locked.("rack", "3.1.8")) }
    expect(@factory.fetched).to eq(["rack-3.1.8"])
  end

  it "says so when a fetch leaves no .gem" do
    files = described_class.new(cache: Dir.mktmpdir, fetcher: ->(*) {})
    expect { files.prepare(locked.("ghost", "1.0.0")) }.to raise_error(described_class::Refused, /left no ghost-1.0.0.gem/)
  end

  it "fetches with `gem fetch` by default, for platform ruby, and reports its failure" do
    files = described_class.new(cache: Dir.mktmpdir)
    status = instance_double(Process::Status, success?: false)
    expect(Open3).to receive(:capture2e)
      .with("gem", "fetch", "ghost", "--version", "1.0.0", "--platform", "ruby", chdir: kind_of(String))
      .and_return(["ERROR: could not find ghost", status])
    expect { files.prepare(locked.("ghost", "1.0.0")) }.to raise_error(described_class::Refused, /could not find ghost/)
  end

  it "reads the stand-ins ruby_wasm_ic_minimal carries, leaving out encoding_constants" do
    @factory.build("ruby_wasm_ic_minimal", "0.1.3",
                   %w[date encoding_constants stringio strscan].to_h { ["lib/ruby_wasm_ic_minimal/standins/#{_1}.rb", ""] })
    expect(@files.standins(locked.("ruby_wasm_ic_minimal", "0.1.3"))).to eq(%w[date stringio strscan])
  end

  it "reads no stand-ins from a ruby_wasm_ic_minimal without them" do
    @factory.build("ruby_wasm_ic_minimal", "0.1.0", "README.md" => "")
    expect(@files.standins(locked.("ruby_wasm_ic_minimal", "0.1.0"))).to eq([])
  end
end
