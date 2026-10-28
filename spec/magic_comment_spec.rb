# frozen_string_literal: true

# Magic comments against the three encodings a canister claims (W29, Q9; W30).
RSpec.describe RubyWasmIcInstaller::MagicComment do
  m = described_class

  it "rewrites an alias of one of the three to its canonical name, and says so" do
    body, r = m.fix("rack-3.1.8/lib/rack/utils.rb", "# -*- encoding: binary -*-\n# frozen_string_literal: true\nx\n")
    expect(body).to eq("# -*- encoding: ascii-8bit -*-\n# frozen_string_literal: true\nx\n")
    expect(r.to_h).to eq(file: "rack-3.1.8/lib/rack/utils.rb", line: 1, from: "binary", to: "ascii-8bit")
  end

  {
    "# encoding: ascii" => "us-ascii", "# coding: CP65001" => "utf-8", "# vim: set fileencoding=BINARY :" => "ascii-8bit",
    "# encoding: ANSI_X3.4-1968" => "us-ascii"
  }.each do |line, to|
    it "rewrites #{line.inspect} to #{to}" do
      body, r = m.fix("f.rb", "#{line}\n")
      expect(r.to).to eq(to)
      expect(body).to eq("#{line.sub(r.from, to)}\n")
    end
  end

  it "leaves a canonical name alone, whatever its case" do
    ["# encoding: utf-8\n", "# encoding: UTF-8\n", "# coding: ASCII-8BIT\n", "# encoding: us-ascii\n"].each do |src|
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

  it "refuses the nine names a canister lists but has no encoding behind, aliases too (W30)" do
    %w[utf-16le UTF-16BE utf-32le UTF-32BE UTF-16 UTF-32 utf8-mac euc-jp Windows-31J].each do |name|
      expect { m.fix("f.rb", "# encoding: #{name}\n") }
        .to raise_error(m::Refused, /lists that name but has no .* behind it, so the file would load as ASCII-8BIT/)
    end
    expect { m.fix("f.rb", "# coding: SJIS\n") }.to raise_error(m::Refused, /Windows-31J .*"SJIS".*load as ASCII-8BIT/)
    expect { m.fix("f.rb", "# coding: eucJP\n") }.to raise_error(m::Refused, /EUC-JP .*"eucJP".*load as ASCII-8BIT/)
  end

  it "refuses a name Ruby does not know" do
    expect { m.fix("f.rb", "# encoding: klingon\n") }.to raise_error(m::Refused, /"klingon", which Ruby does not know/)
  end

  it "holds the three ADR-0053 claims, and the nine W26 observed beside them" do
    expect(m::CLAIMED_ENCODINGS).to eq(%w[ASCII-8BIT UTF-8 US-ASCII])
    expect(m::UNCLAIMED_ENCODINGS.size).to eq(9)
    all = m::CLAIMED_ENCODINGS + m::UNCLAIMED_ENCODINGS
    expect(all.map { Encoding.find(_1).name }).to eq(all)
  end
end
