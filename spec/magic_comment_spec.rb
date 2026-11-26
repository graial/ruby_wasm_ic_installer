# frozen_string_literal: true

# Magic comments, on Releases that link every Ruby 3.3 encoding (0.13.0 on).
RSpec.describe RubyWasmIcInstaller::MagicComment do
  m = described_class

  it "accepts any encoding Ruby knows, as written" do
    ["# encoding: euc-jp\n", "# coding: Shift_JIS\n", "# encoding: iso-8859-1\n", "# -*- encoding: binary -*-\n",
     "# encoding: ascii\n", "# coding: SJIS\n", "x = 1\n", ""].each do |src|
      expect(m.check!("f.rb", src)).to be_nil
    end
  end

  it "refuses a name Ruby does not know, naming the file" do
    expect { m.check!("old-1.0/lib/old.rb", "# encoding: klingon\n") }
      .to raise_error(m::Refused, %r{old-1.0/lib/old.rb names the encoding "klingon", which Ruby does not know})
  end

  it "refuses an encoding Ruby cannot read source in" do
    expect { m.check!("f.rb", "# encoding: utf-16le\n") }.to raise_error(m::Refused, /UTF-16LE.*not ASCII-compatible/)
  end

  it "reads the second line after a shebang, and no further" do
    expect { m.check!("f.rb", "#!/usr/bin/env ruby\n# encoding: klingon\n") }.to raise_error(m::Refused)
    expect(m.check!("f.rb", "x = 1\n# encoding: klingon\n")).to be_nil
  end

  # The check runs on the host's Ruby (4.0 today), not the canister's 3.3:
  # this fails loudly if a host Ruby drops an encoding 3.3 has.
  it "finds the Japanese encodings on the host Ruby" do
    %w[EUC-JP Shift_JIS Windows-31J ISO-2022-JP CP51932 eucJP-ms].each { expect(Encoding.find(_1)).to be_a(Encoding) }
  end
end
