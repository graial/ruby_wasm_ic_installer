# frozen_string_literal: true

# Magic comments against a canister's twelve encodings (W29, Q9).
RSpec.describe RubyWasmIcInstaller::MagicComment do
  m = described_class

  it "rewrites an alias of one of the twelve to its canonical name, and says so" do
    body, r = m.fix("rack-3.1.8/lib/rack/utils.rb", "# -*- encoding: binary -*-\n# frozen_string_literal: true\nx\n")
    expect(body).to eq("# -*- encoding: ascii-8bit -*-\n# frozen_string_literal: true\nx\n")
    expect(r.to_h).to eq(file: "rack-3.1.8/lib/rack/utils.rb", line: 1, from: "binary", to: "ascii-8bit")
  end

  {
    "# encoding: ascii" => "us-ascii", "# coding: CP65001" => "utf-8", "# vim: set fileencoding=BINARY :" => "ascii-8bit",
    "# encoding: SJIS" => "windows-31j", "# coding: eucJP" => "euc-jp"
  }.each do |line, to|
    it "rewrites #{line.inspect} to #{to}" do
      body, r = m.fix("f.rb", "#{line}\n")
      expect(r.to).to eq(to)
      expect(body).to eq("#{line.sub(r.from, to)}\n")
    end
  end

  it "leaves a canonical name alone, whatever its case" do
    ["# encoding: utf-8\n", "# encoding: UTF-8\n", "# coding: ASCII-8BIT\n", "# encoding: utf-16le\n"].each do |src|
      expect(m.fix("f.rb", src)).to eq([src, nil])
    end
  end

  it "reads the second line after a shebang, and no further" do
    body, r = m.fix("f.rb", "#!/usr/bin/env ruby\n# encoding: binary\n")
    expect([body, r.line]).to eq(["#!/usr/bin/env ruby\n# encoding: ascii-8bit\n", 2])
    expect(m.fix("f.rb", "x = 1\n# encoding: binary\n")).to eq(["x = 1\n# encoding: binary\n", nil])
    expect(m.fix("f.rb", "")).to eq(["", nil])
  end

  it "refuses an encoding a canister lacks, naming the file and the encoding" do
    expect { m.fix("old-1.0/lib/old.rb", "# encoding: iso-8859-1\n") }
      .to raise_error(m::Refused, /old-1.0\/lib\/old.rb is written in ISO-8859-1 .*does not have/)
    expect { m.fix("f.rb", "# coding: Shift_JIS\n") }.to raise_error(m::Refused, /Shift_JIS/)
  end

  it "refuses a name Ruby does not know" do
    expect { m.fix("f.rb", "# encoding: klingon\n") }.to raise_error(m::Refused, /"klingon", which Ruby does not know/)
  end

  it "holds the table W26 observed" do
    expect(m::CANISTER_ENCODINGS.size).to eq(12)
    expect(m::CANISTER_ENCODINGS.map { Encoding.find(_1).name }).to eq(m::CANISTER_ENCODINGS)
  end
end
