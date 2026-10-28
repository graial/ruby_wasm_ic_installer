# frozen_string_literal: true

# The one way out to a canister (W29, Q13): `icp canister call` with the
# arguments in a file, raw bytes in and hex out.
RSpec.describe RubyWasmIcInstaller::Runner do
  let(:ok) { instance_double(Process::Status, success?: true) }
  let(:bad) { instance_double(Process::Status, success?: false) }

  it "calls icp canister call with --args-file in bin format and -o hex, passing icp options through" do
    seen = nil
    spawn = lambda do |*argv|
      seen = argv
      i = argv.index("--args-file")
      expect(File.binread(argv[i + 1])).to eq("DIDL\x00\x00".b)
      ["4449444c0000\n", "", ok]
    end
    r = described_class.new(canister: "app", icp: "/bin/icp", icp_args: ["-e", "ic", "--identity", "me"], spawn: spawn)
    expect(r.call("installed", "DIDL\x00\x00".b, query: true)).to eq("DIDL\x00\x00".b)
    expect(seen.values_at(0..4)).to eq(["/bin/icp", "canister", "call", "app", "installed"])
    expect(seen.drop(5).reject { _1.end_with?(".bin") })
      .to eq(["--args-file", "--args-format", "bin", "-o", "hex", "--query", "-e", "ic", "--identity", "me"])
  end

  it "sends an update without --query" do
    seen = nil
    r = described_class.new(canister: "app", spawn: ->(*argv) { seen = argv; ["00", "", ok] })
    r.call("install_put", "x")
    expect(seen).not_to include("--query")
    expect(seen.first).to eq("icp")
  end

  it "raises with the canister's refusal when the call traps with refused:" do
    err = "Error: Canister called `ic0.trap` with message: 'refused: only a controller may install code'.\n"
    r = described_class.new(canister: "app", spawn: ->(*) { ["", err, bad] })
    expect { r.call("install_put", "x") }.to raise_error(described_class::CallError) { |e|
      expect(e.refusal).to eq("only a controller may install code")
      expect(e.message).to start_with("install_put: Error: Canister called")
    }
  end

  it "raises with stdout when stderr is empty, and with no refusal for another failure" do
    r = described_class.new(canister: "app", spawn: ->(*) { ["network unreachable", "", bad] })
    expect { r.call("installed", "x") }.to raise_error(described_class::CallError, "installed: network unreachable") { |e|
      expect(e.refusal).to be_nil
    }
  end

  it "raises when the reply is not hex" do
    r = described_class.new(canister: "app", spawn: ->(*) { ["(\"hello\")", "", ok] })
    expect { r.call("installed", "x") }.to raise_error(described_class::CallError, /not hex/)
  end

  it "runs icp through Open3 by default" do
    expect(Open3).to receive(:capture3).with("icp", "canister", "call", "app", "installed", any_args)
                                       .and_return(["00", "", ok])
    expect(described_class.new(canister: "app").call("installed", "x")).to eq("\x00".b)
  end
end
