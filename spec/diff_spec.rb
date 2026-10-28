# frozen_string_literal: true

# The unified diff `setup` shows (W29, Q17), checked against diff(1)'s shape.
RSpec.describe RubyWasmIcInstaller::Diff do
  d = described_class

  it "is empty when nothing differs" do
    expect(d.unified("a\nb\n", "a\nb\n", from: "x", to: "y")).to eq("")
  end

  it "shows a change with three lines of context" do
    old = (1..10).map { "l#{_1}\n" }.join
    new = old.sub("l5\n", "five\n")
    expect(d.unified(old, new, from: "a/f", to: "b/f")).to eq(<<~DIFF)
      --- a/f
      +++ b/f
      @@ -2,7 +2,7 @@
       l2
       l3
       l4
      -l5
      +five
       l6
       l7
       l8
    DIFF
  end

  it "keeps far-apart changes in separate hunks, and joins near ones" do
    old = (1..20).map { "l#{_1}\n" }.join
    far = old.sub("l2\n", "two\n").sub("l18\n", "eighteen\n")
    expect(d.unified(old, far, from: "a", to: "b").scan(/^@@/).size).to eq(2)
    near = old.sub("l2\n", "two\n").sub("l6\n", "six\n")
    expect(d.unified(old, near, from: "a", to: "b").scan(/^@@/).size).to eq(1)
  end

  it "diffs from nothing, and marks a last line with no newline" do
    expect(d.unified("", "x\ny", from: "/dev/null", to: "b/f")).to eq(<<~DIFF)
      --- /dev/null
      +++ b/f
      @@ -0,0 +1,2 @@
      +x
      +y
      \\ No newline at end of file
    DIFF
  end

  it "diffs to nothing" do
    expect(d.unified("x\n", "", from: "a", to: "b")).to eq("--- a\n+++ b\n@@ -1,1 +0,0 @@\n-x\n")
  end
end
