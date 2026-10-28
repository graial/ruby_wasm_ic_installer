# frozen_string_literal: true

# The canister half (W29, Q7, Q10, Q11, Q16) on MRI, over a temporary
# IC::DATA_DIR and the stand-in IC: what a canister would do with each call.
RSpec.describe RubyWasmIcInstaller::Canister do
  k = described_class

  around do |ex|
    Dir.mktmpdir do |dir|
      @data = File.join(dir, "data")
      Dir.mkdir(@data)
      k.data_dir = @data
      $LOAD_PATH.unshift("/app")
      @rest = $LOAD_PATH.drop(1)
      k.boot!
      ex.run
    end
  end

  def put(*files) = install_put(files.map { |p, b| { path: p, body: b } })
  def commit(gems = [], setup = nil) = install_commit({ gems: gems, setup: setup })
  def refused(&blk) = expect(&blk).to(raise_error(IC::Refusal))
  def gems_dir = File.join(@data, "gems")

  describe "install_put" do
    it "writes into .partial/<name-version>/, making directories, and says what it wrote" do
      expect(put(["rack-3.1.8/lib/rack.rb", "R"], ["rack-3.1.8/lib/rack/a/b.rb", "AB"]))
        .to eq("wrote 2 files, 3 bytes")
      expect(File.read(File.join(gems_dir, ".partial/rack-3.1.8/lib/rack/a/b.rb"))).to eq("AB")
      expect(installed[:gems]).to eq([])
      expect(installed[:partial]).to eq(["rack-3.1.8"])
    end

    it "is for controllers only, and writes nothing for anyone else" do
      IC.controller = false
      expect { put(["rack-3.1.8/lib/rack.rb", "R"]) }.to raise_error(IC::Refusal, "only a controller may install code")
    end

    {
      "/etc/passwd" => /relative/, "rack-3.1.8/../../x.rb" => /\.\./, "rack-3.1.8//x.rb" => /empty segment/,
      "rack-3.1.8/./x.rb" => /\. or \.\./, "rack-3.1.8" => /<name-version>\/<file>/,
      "rack/lib/rack.rb" => /not a gem version/, ".partial/lib/x.rb" => /not a gem version/,
      "../rack-3.1.8/x.rb" => /\.\./
    }.each do |path, why|
      it "refuses the path #{path.inspect}" do
        expect { put([path, "x"]) }.to raise_error(IC::Refusal, why)
      end
    end
  end

  describe "install_commit" do
    before { put(["rack-3.1.8/lib/rack.rb", "R"], ["roda-3.109.0/lib/roda.rb", "D"]) }

    it "renames each named .partial directory into place" do
      expect(commit(%w[rack-3.1.8])).to eq("committed 1 gems")
      expect(installed).to include(gems: ["rack-3.1.8"], partial: ["roda-3.109.0"])
    end

    it "writes the setup file, last, naming its generation and load paths" do
      reply = commit(%w[rack-3.1.8 roda-3.109.0], { generation: 1, load_paths: %w[rack-3.1.8/lib roda-3.109.0/lib] })
      expect(reply).to eq("committed 2 gems; wrote setup generation 1")
      expect(installed).to include(pending: 1, running: nil, load_paths: %w[rack-3.1.8/lib roda-3.109.0/lib])
      expect(File.read(File.join(@data, "setup.rb"))).to start_with(k::SETUP_HEAD)
    end

    it "refuses a version with nothing in .partial, one already installed, and a bad name" do
      expect { commit(%w[sinatra-4.0.0]) }.to raise_error(IC::Refusal, /nothing in .partial/)
      commit(%w[rack-3.1.8])
      put(["rack-3.1.8/lib/rack.rb", "R2"])
      expect { commit(%w[rack-3.1.8]) }.to raise_error(IC::Refusal, /already installed/)
      expect { commit(["../x-1"]) }.to raise_error(IC::Refusal, /not a gem version/)
    end

    it "refuses a setup naming a load path that is not inside an installed gem" do
      commit(%w[rack-3.1.8])
      expect { commit([], { generation: 1, load_paths: %w[roda-3.109.0/lib] }) }
        .to raise_error(IC::Refusal, /roda-3.109.0\/lib is not inside an installed gem/)
      expect { commit([], { generation: 1, load_paths: %w[rack-3.1.8/nope] }) }
        .to raise_error(IC::Refusal, /not inside an installed gem/)
      expect { commit([], { generation: 1, load_paths: %w[../etc] }) }.to raise_error(IC::Refusal)
    end

    it "refuses a generation that does not go up, past the pending one and the running one" do
      commit(%w[rack-3.1.8], { generation: 2, load_paths: %w[rack-3.1.8/lib] })
      expect { commit([], { generation: 2, load_paths: %w[rack-3.1.8/lib] }) }.to raise_error(IC::Refusal, /above/)
      expect { commit([], { generation: 0, load_paths: [] }) }.to raise_error(IC::Refusal, /above/)
      k.boot!
      expect(installed[:running]).to eq(2)
    end

    it "is for controllers only" do
      IC.controller = false
      expect { commit(%w[rack-3.1.8]) }.to raise_error(IC::Refusal, /only a controller/)
    end
  end

  describe "the boot" do
    before do
      put(["rack-3.1.8/lib/rack.rb", "R"], ["roda-3.109.0/lib/roda.rb", "D"])
      commit(%w[rack-3.1.8 roda-3.109.0], { generation: 1, load_paths: %w[rack-3.1.8/lib roda-3.109.0/lib] })
    end

    it "takes effect at the next boot, not at once" do
      expect(installed).to include(running: nil, pending: 1)
      expect($LOAD_PATH).to eq(["/app", *@rest])
    end

    it "puts the load paths after /app and before the rest (the Shipped library), in the lock's order" do
      k.boot!
      expect($LOAD_PATH).to eq(["/app", File.join(gems_dir, "rack-3.1.8/lib"), File.join(gems_dir, "roda-3.109.0/lib"),
                                *@rest])
      expect(installed).to include(running: 1, pending: 1, running_paths: %w[rack-3.1.8/lib roda-3.109.0/lib])
    end

    it "puts them first when there is no /app, and adds none twice" do
      $LOAD_PATH.delete("/app")
      k.boot!
      k.boot!
      expect($LOAD_PATH).to eq([File.join(gems_dir, "rack-3.1.8/lib"), File.join(gems_dir, "roda-3.109.0/lib"), *@rest])
    end

    it "boots with nothing installed when there is no setup file" do
      File.delete(File.join(@data, "setup.rb"))
      k.boot!
      expect(installed).to include(running: nil, pending: nil, load_paths: [], running_paths: [])
    end

    it "reads no generation and no paths from a setup file without them" do
      File.write(File.join(@data, "setup.rb"), "# nothing\n")
      expect(installed).to include(pending: nil, load_paths: [])
    end
  end

  describe "install_remove" do
    before do
      put(["rack-3.1.7/lib/rack.rb", "old"], ["rack-3.1.8/lib/rack.rb", "new"])
      commit(%w[rack-3.1.7], { generation: 1, load_paths: %w[rack-3.1.7/lib] })
      k.boot! # running: 3.1.7
      commit(%w[rack-3.1.8], { generation: 2, load_paths: %w[rack-3.1.8/lib] }) # pending: 3.1.8
    end

    it "refuses a version the running boot names, and one the pending setup names" do
      expect { install_remove("rack-3.1.7") }.to raise_error(IC::Refusal, /running boot \(generation 1\)/)
      expect { install_remove("rack-3.1.8") }.to raise_error(IC::Refusal, /pending setup \(generation 2\)/)
    end

    it "removes a version once neither names it, files and directories" do
      k.boot! # running: 3.1.8
      expect(install_remove("rack-3.1.7")).to eq("removed rack-3.1.7")
      expect(installed[:gems]).to eq(["rack-3.1.8"])
      expect(Dir.exist?(File.join(gems_dir, "rack-3.1.7"))).to be(false)
    end

    it "removes a half-sent version from .partial" do
      put(["sinatra-4.0.0/lib/sinatra.rb", "S"])
      expect(install_remove("sinatra-4.0.0")).to eq("removed sinatra-4.0.0 from .partial")
      expect(installed[:partial]).to eq([])
    end

    it "refuses a version that is not installed, a bad name, and a stranger" do
      expect { install_remove("rails-8.0.0") }.to raise_error(IC::Refusal, /not installed/)
      expect { install_remove("..") }.to raise_error(IC::Refusal, /not a gem version/)
      expect { install_remove(nil) }.to raise_error(IC::Refusal, /not a gem version/)
      IC.controller = false
      expect { install_remove("rack-3.1.7") }.to raise_error(IC::Refusal, /only a controller/)
    end

    it "removes a symlink as a file, without following it" do
      k.boot!
      target = File.join(File.dirname(@data), "outside")
      Dir.mkdir(target)
      File.symlink(target, File.join(gems_dir, "rack-3.1.7/lib/link"))
      install_remove("rack-3.1.7")
      expect(Dir.exist?(target)).to be(true)
    end
  end

  describe "on a minimal canister" do
    src = File.read(File.expand_path("../lib/ruby_wasm_ic_installer/canister.rb", __dir__))
    code = src.lines.reject { _1.lstrip.start_with?("#") }.join

    it "names no Encoding constant, which a canister lacks (ADR-0060)" do
      expect(code).not_to match(/Encoding::/)
    end

    it "requires nothing, so it loads with core Ruby and the builder's IC alone" do
      expect(code).not_to match(/\brequire(_relative)?\b/)
    end

    it "defines the four handlers its Declarations name, at the top level" do
      %i[install_put install_commit install_remove installed].each do |m|
        expect(Object.private_method_defined?(m)).to be(true), m.to_s
      end
    end

    it "boots on require only where IC::DATA_DIR is defined" do
      expect(src).to end_with("RubyWasmIcInstaller::Canister.boot! if defined?(IC::DATA_DIR)\n")
    end
  end
end
