# frozen_string_literal: true

require "json"

# The Installer's own Candid (W29, Q13), held byte for byte to what
# @dfinity/didc 0.0.4 encodes for the same values (spec/fixtures/didc-vectors.json,
# written by didc against the Installer's .did), so the encoder is checked by
# a tool outside the gem.
RSpec.describe RubyWasmIcInstaller::Candid do
  c = described_class
  vectors = JSON.parse(File.read(File.expand_path("fixtures/didc-vectors.json", __dir__)))
  hex = ->(name) { [vectors.fetch(name)].pack("H*") }

  describe "encoding, byte for byte against didc" do
    it "encodes an install_put batch" do
      files = [{ path: "rack-3.1.8/lib/rack.rb", body: "module Rack; end\n" },
               { path: "rack-3.1.8/lib/rack/version.rb", body: "\x00\xff".b }]
      expect(c.install_files(files)).to eq(hex.("install_files_two"))
      expect(c.install_files([])).to eq(hex.("install_files_empty"))
    end

    it "encodes an install_commit with gems and no setup, and with a setup and no gems" do
      expect(c.install_commit(gems: %w[rack-3.1.8 roda-3.109.0])).to eq(hex.("commit_gems"))
      expect(c.install_commit(gems: [], setup: { generation: 7, load_paths: %w[rack-3.1.8/lib roda-3.109.0/lib] }))
        .to eq(hex.("commit_setup"))
    end

    it "encodes a text argument and no arguments" do
      expect(c.text_arg("rack-3.1.7")).to eq(hex.("text_remove"))
      expect(c.empty_args).to eq(hex.("empty"))
    end
  end

  describe "decoding" do
    it "reads didc's Installed record, opts and all" do
      v = c.record(c.decode(hex.("installed_reply")).first, :running, :pending, :gems, :partial, :load_paths,
                   :running_paths)
      expect(v).to eq(running: 2, pending: 3, gems: ["rack-3.1.8"], partial: [], load_paths: ["rack-3.1.8/lib"],
                      running_paths: ["rack-3.1.7/lib"])
      none = c.record(c.decode(hex.("installed_none")).first, :running, :pending, :gems)
      expect(none).to eq(running: nil, pending: nil, gems: [])
    end

    it "reads what it encodes, blobs as binary Strings" do
      files = c.decode(c.install_files([{ path: "a-1/x", body: "\xfe".b }])).first
      expect(c.record(files.first, :path, :body)).to eq(path: "a-1/x", body: "\xfe".b)
      commit = c.record(c.decode(c.install_commit(gems: [], setup: { generation: 2**63, load_paths: [] })).first,
                        :gems, :setup)
      expect(c.record(commit[:setup], :generation, :load_paths)).to eq(generation: 2**63, load_paths: [])
      expect(c.decode(c.text_arg("é"))).to eq(["é"])
      expect(c.decode(c.empty_args)).to eq([])
    end

    it "reads bool, nat, the sized nats and null" do
      msg = "DIDL".b + c.leb(0) + c.leb(6) + [c::BOOL, c::NAT, c::NAT8, c::NAT16, c::NAT32, c::NULL].map { c.sleb(_1) }.join +
            "\x01".b + c.leb(300) + "\x07".b + [513].pack("S<") + [70_000].pack("L<")
      expect(c.decode(msg)).to eq([true, 300, 7, 513, 70_000, nil])
    end

    {
      "no header" => "XXXX\x00\x00",
      "trailing bytes" => "DIDL\x00\x00\x00",
      "an early end" => "DIDL\x00\x01\x71\x05ab",
      "an unread primitive type" => "DIDL\x00\x01\x73\x00\x00\x00\x00",
      "an unread constructor" => "DIDL\x01\x6b\x00\x01\x00",
      "a type index not in the table" => "DIDL\x00\x01\x05",
      "an opt tag of 2" => "DIDL\x01\x6e\x71\x01\x00\x02",
      "text that is not UTF-8" => "DIDL\x00\x01\x71\x01\xff",
      "a LEB128 past 10 bytes" => "DIDL\x00\x01\x7d" + ("\x80" * 11) + "\x00",
      "an SLEB128 past 10 bytes" => "DIDL\x00\x01" + ("\x80" * 11) + "\x00"
    }.each do |what, bytes|
      it "refuses #{what}" do
        expect { c.decode(bytes.b) }.to raise_error(c::Error)
      end
    end

    it "refuses an opt nested past 32" do
      table = c.types("\x6e".b + c.sleb(0))
      bytes = "DIDL".b + table + c.leb(1) + c.sleb(0) + ("\x01".b * 40)
      expect { c.decode(bytes) }.to raise_error(c::Error, /nested past 32/)
    end

    it "names a missing field and a value that is not a record" do
      expect { c.record({}, :gems) }.to raise_error(c::Error, /no field gems/)
      expect { c.record([], :gems) }.to raise_error(c::Error, /expected a record/)
    end
  end

  describe "numbers" do
    it "writes LEB128 and SLEB128 at their edges" do
      expect(c.leb(0)).to eq("\x00".b)
      expect(c.leb(127)).to eq("\x7f".b)
      expect(c.leb(128)).to eq("\x80\x01".b)
      expect(c.sleb(-1)).to eq("\x7f".b)
      expect(c.sleb(63)).to eq("\x3f".b)
      expect(c.sleb(64)).to eq("\xc0\x00".b)
      expect(c.sleb(-20)).to eq("\x6c".b)
    end

    it "refuses a negative LEB128, a nat64 out of range and text that is not UTF-8" do
      expect { c.leb(-1) }.to raise_error(c::Error, /negative/)
      expect { c.nat64_value(2**64) }.to raise_error(c::Error, /out of range/)
      expect { c.nat64_value(-1) }.to raise_error(c::Error, /out of range/)
      expect { c.text_arg("\xff".b) }.to raise_error(c::Error, /UTF-8/)
    end

    it "hashes field names as the IDL does (the LEB128 didc writes: a5cbc7d204, a2f5ed8804)" do
      expect(c.idl_hash("path")).to eq(0x4a51e5a5)
      expect(c.idl_hash("body")).to eq(0x411b7aa2)
      expect(c.leb(c.idl_hash("path")).unpack1("H*")).to eq("a5cbc7d204")
    end

    it "sizes a file in a batch as the batch encodes it" do
      files = [{ path: "a-1/lib/a.rb", body: "x" * 200 }, { path: "a-1/lib/b.rb", body: "y" }]
      sizes = files.sum { c.install_file_size(_1[:path], _1[:body]) }
      expect(c.install_files(files).bytesize).to eq(sizes + c.install_files_overhead(2))
    end
  end
end
