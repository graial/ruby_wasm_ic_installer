# frozen_string_literal: true

# What one install run sends (W29, Q10).
RSpec.describe RubyWasmIcInstaller::Plan do
  c = RubyWasmIcInstaller::Candid
  prep = lambda do |nv, files, paths = ["lib"]|
    RubyWasmIcInstaller::GemFiles::Prepared.new(name_version: nv, require_paths: paths, files: files, rewrites: [])
  end
  fresh = { running: nil, pending: nil, gems: [], partial: [], load_paths: [], running_paths: [] }
  decoded = ->(step) { c.decode(step.args).first }

  it "sends every gem the canister lacks, commits it, then writes the setup file last" do
    gems = [prep.("rack-3.1.8", "lib/rack.rb" => "R"), prep.("roda-3.109.0", "lib/roda.rb" => "D")]
    plan = described_class.new(gems, fresh)
    expect(plan.steps.map(&:method)).to eq(%w[install_put install_commit install_commit])
    expect(c.record(decoded.(plan.steps[1]), :gems)[:gems]).to eq(%w[rack-3.1.8 roda-3.109.0])
    setup = c.record(c.record(decoded.(plan.steps[2]), :setup)[:setup], :generation, :load_paths)
    expect(setup).to eq(generation: 1, load_paths: %w[rack-3.1.8/lib roda-3.109.0/lib])
    expect(plan.generation).to eq(1)
    expect(plan.sent.map(&:name_version)).to eq(%w[rack-3.1.8 roda-3.109.0])
  end

  it "compares by name-version, sending nothing the canister already has" do
    gems = [prep.("rack-3.1.8", "lib/rack.rb" => "R"), prep.("roda-3.109.0", "lib/roda.rb" => "D")]
    plan = described_class.new(gems, fresh.merge(gems: ["rack-3.1.8"]))
    expect(plan.sent.map(&:name_version)).to eq(["roda-3.109.0"])
    put = decoded.(plan.steps.first).map { c.record(_1, :path)[:path] }
    expect(put).to eq(["roda-3.109.0/lib/roda.rb"])
  end

  it "plans nothing when every gem is there and the pending setup names the same paths" do
    gems = [prep.("rack-3.1.8", "lib/rack.rb" => "R")]
    plan = described_class.new(gems, fresh.merge(gems: ["rack-3.1.8"], pending: 4, load_paths: ["rack-3.1.8/lib"]))
    expect(plan).to be_empty
    expect(plan.generation).to be_nil
  end

  it "writes a new setup when only the order or the set of paths changes, above both generations" do
    gems = [prep.("rack-3.1.8", "lib/rack.rb" => "R")]
    plan = described_class.new(gems, fresh.merge(gems: ["rack-3.1.8"], pending: 4, running: 6, load_paths: []))
    expect(plan.steps.map(&:method)).to eq(["install_commit"])
    expect(plan.generation).to eq(7)
  end

  it "packs batches by bytes, under the budget, committing each gem after the batch that completes it" do
    big = (1..6).to_h { ["lib/f#{_1}.rb", "x" * 400] }
    gems = [prep.("a-1", big), prep.("b-1", "lib/b.rb" => "y" * 400)]
    plan = described_class.new(gems, fresh, budget: 1_000)
    puts_ = plan.steps.select { _1.method == "install_put" }
    expect(puts_.map { _1.args.bytesize }).to all(be <= 1_000)
    expect(puts_.size).to eq(4)
    expect(plan.steps.map(&:method)).to eq(%w[install_put install_put install_put install_commit install_put
                                              install_commit install_commit])
    sent = puts_.flat_map { decoded.(_1).map { |r| c.record(r, :path)[:path] } }
    expect(sent).to eq(big.keys.map { "a-1/#{_1}" } + ["b-1/lib/b.rb"])
  end

  it "refuses a single file too big for one call" do
    gems = [prep.("a-1", "lib/a.rb" => "x" * 2_000)]
    expect { described_class.new(gems, fresh, budget: 1_000) }.to raise_error(RubyWasmIcInstaller::Error, /more than one call/)
  end

  it "clears a version half-sent by an earlier run before sending it again" do
    gems = [prep.("rack-3.1.8", "lib/rack.rb" => "R")]
    plan = described_class.new(gems, fresh.merge(partial: %w[rack-3.1.8 other-1]))
    expect(plan.steps.first.method).to eq("install_remove")
    expect(c.decode(plan.steps.first.args)).to eq(["rack-3.1.8"])
    expect(plan.steps.map(&:method)).to eq(%w[install_remove install_put install_commit install_commit])
  end

  it "keeps the default budget under the 2 MiB ingress limit, with room for icp-cli's envelope" do
    expect(described_class::DEFAULT_BUDGET).to be < 2 * 1024 * 1024 - 64 * 1024
  end
end
