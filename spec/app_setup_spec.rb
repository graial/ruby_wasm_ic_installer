# frozen_string_literal: true

require "stringio"

# `ruby_wasm_ic_installer setup <app_dir>` (W29, Q16 and Q17).
RSpec.describe RubyWasmIcInstaller::AppSetup do
  s = described_class

  around do |ex|
    Dir.mktmpdir do |dir|
      @app = File.join(dir, "my_app")
      Dir.mkdir(@app)
      File.write(File.join(@app, "app.rb"), "# frozen_string_literal: true\n\ndef hello = \"hi\"\n")
      File.write(File.join(@app, "ic-interface.rb"), "update :hello, takes: [], returns: Text\n")
      @out = StringIO.new
      ex.run
    end
  end

  def setup(input: "", tty: false) = RubyWasmIcInstaller::AppSetup.new(@app, io: @out, input: StringIO.new(input), tty: tty)
  def read(name) = File.read(File.join(@app, name))
  def vendored = File.join(@app, "vendor/ruby_wasm_ic_installer/ruby_wasm_ic_installer/canister.rb")

  describe "on a fresh Application" do
    it "writes the Declarations block, the app.rb block after the magic comment, and the canister half" do
      written = setup.run.map { _1.path.delete_prefix("#{@app}/") }
      expect(written).to eq(["ic-interface.rb", "app.rb", "vendor/ruby_wasm_ic_installer/ruby_wasm_ic_installer/canister.rb"])
      expect(read("ic-interface.rb")).to eq("update :hello, takes: [], returns: Text\n\n#{s::INTERFACE}")
      expect(read("app.rb")).to eq("# frozen_string_literal: true\n#{s::APP}\ndef hello = \"hi\"\n")
      expect(File.read(vendored)).to eq(File.read(s::CANISTER_SOURCE))
      expect(@out.string).to include("wrote app.rb", "pack the Application again")
    end

    it "asks nothing, since nothing of the author's is replaced" do
      expect(setup(tty: true).run.size).to eq(3)
      expect(@out.string).not_to include("Apply?")
    end

    it "changes nothing when run twice" do
      setup.run
      before = %w[app.rb ic-interface.rb].map { read(_1) }
      expect(setup.run).to eq([])
      expect(%w[app.rb ic-interface.rb].map { read(_1) }).to eq(before)
      expect(@out.string).to include("nothing to change")
    end

    it "keeps a shebang and every magic comment above the block, and handles a file with none" do
      File.write(File.join(@app, "app.rb"), "#!/usr/bin/env ruby\n# encoding: utf-8\n# frozen_string_literal: true\nx = 1\n")
      setup.run
      expect(read("app.rb").lines.first(4)).to eq(["#!/usr/bin/env ruby\n", "# encoding: utf-8\n",
                                                   "# frozen_string_literal: true\n", "#{s::OPEN}#{s::NOTE}\n"])
      File.write(File.join(@app, "ic-interface.rb"), "")
      File.write(File.join(@app, "app.rb"), "x = 1")
      FileUtils.rm_rf(File.join(@app, "vendor"))
      setup.run
      expect(read("ic-interface.rb")).to eq("\n#{s::INTERFACE}")
      expect(read("app.rb")).to eq("#{s::APP}x = 1")
    end

    it "adds a newline before the block when ic-interface.rb has none at its end" do
      File.write(File.join(@app, "ic-interface.rb"), "update :hello, takes: [], returns: Text")
      setup.run
      expect(read("ic-interface.rb")).to eq("update :hello, takes: [], returns: Text\n\n#{s::INTERFACE}")
    end
  end

  describe "when the author's lines differ from what setup writes" do
    before do
      setup.run
      File.write(File.join(@app, "ic-interface.rb"), read("ic-interface.rb").sub("returns: :Installed", "returns: Text"))
      @out.truncate(0)
      @out.rewind
    end

    it "shows the diff and writes nothing unless told yes" do
      expect { setup(input: "n\n", tty: true).run }.to raise_error(s::Aborted, "aborted: nothing was written")
      expect(@out.string).to include("These lines differ", "--- a/ic-interface.rb", "+++ b/ic-interface.rb",
                                     "-query  :installed,      takes: [],                  returns: Text",
                                     "+query  :installed,      takes: [],                  returns: :Installed",
                                     "Apply? [y/N]")
      expect(read("ic-interface.rb")).to include("returns: Text\n#{s::CLOSE}")
    end

    it "writes on y" do
      setup(input: "y\n", tty: true).run
      expect(read("ic-interface.rb")).to include("returns: :Installed")
    end

    it "aborts with no terminal, unless --yes" do
      expect { setup(tty: false).run }.to raise_error(s::Aborted, /no terminal.*--yes/)
      setup(tty: false).run(yes: true)
      expect(read("ic-interface.rb")).to include("returns: :Installed")
    end

    it "treats an edited vendored canister half the same way" do
      setup(tty: false).run(yes: true)
      File.write(vendored, "# mine\n")
      expect { setup(input: "", tty: true).run }.to raise_error(s::Aborted)
      expect(@out.string).to include("--- a/vendor/ruby_wasm_ic_installer/ruby_wasm_ic_installer/canister.rb")
      expect(File.read(vendored)).to eq("# mine\n")
    end

    it "asks whether the input is a terminal when not told" do
      input = StringIO.new("y\n")
      def input.tty? = true
      s.new(@app, io: @out, input: input).run
      expect(read("ic-interface.rb")).to include("returns: :Installed")
    end
  end

  describe "--check" do
    it "exits 1 with the diffs while setup would change something, and 0 once it would not" do
      expect(setup.check).to eq(1)
      expect(@out.string).to include("--- /dev/null", "+++ b/vendor/ruby_wasm_ic_installer", "setup would change 3 file(s)")
      setup.run
      expect(setup.check).to eq(0)
      expect(@out.string).to include("setup is current")
    end
  end

  describe "what it refuses" do
    it "aborts when the Installer's names are declared or defined outside the markers, saying where" do
      File.write(File.join(@app, "ic-interface.rb"), "update :hello, takes: [], returns: Text\nquery :installed, takes: [], returns: Text\n")
      expect { setup.run }.to raise_error(s::Aborted, /ic-interface.rb:2: query :installed/)
      File.write(File.join(@app, "ic-interface.rb"), "type :InstallFile, Text\n")
      expect { setup.run }.to raise_error(s::Aborted, /ic-interface.rb:1: type :InstallFile/)
      File.write(File.join(@app, "ic-interface.rb"), "")
      File.write(File.join(@app, "app.rb"), "def install_put(x) = x\n")
      expect { setup.run }.to raise_error(s::Aborted, /app.rb:1: def install_put/)
    end

    it "refuses a directory without app.rb, and an Application without an Interface file" do
      File.delete(File.join(@app, "ic-interface.rb"))
      expect { setup.run }.to raise_error(RubyWasmIcInstaller::Error, /no ic-interface.rb.*served `run` alone/)
      File.delete(File.join(@app, "app.rb"))
      expect { setup.run }.to raise_error(RubyWasmIcInstaller::Error, /no app.rb: it is not an Application/)
    end
  end

  it "declares the four names the canister half defines, with the types it takes and returns" do
    expect(s::INTERFACE.scan(/^(?:update|query)\s+:(\w+)/).flatten).to eq(s::NAMES)
    expect(s::INTERFACE.scan(/^type :(\w+)/).flatten).to eq(s::TYPES)
    expect(s::INTERFACE).to include("query  :installed")
  end
end
