# frozen_string_literal: true

module RubyWasmIcInstaller
  # A unified diff of two texts by lines, enough for `setup` to show what it
  # would change (W29, Q17). Longest common subsequence; three lines of
  # context; no dependency.
  module Diff
    module_function

    def unified(old_text, new_text, from:, to:, context: 3)
      a = old_text.lines
      b = new_text.lines
      ops = edits(a, b)
      return "" if ops.all? { _1.first == :same }

      out = +"--- #{from}\n+++ #{to}\n"
      hunks(ops, context).each do |h|
        a_start = h.first[2] + 1
        b_start = h.first[3] + 1
        a_len = h.count { _1.first != :add }
        b_len = h.count { _1.first != :del }
        out << "@@ -#{a_len.zero? ? a_start - 1 : a_start},#{a_len} +#{b_len.zero? ? b_start - 1 : b_start},#{b_len} @@\n"
        h.each do |op, line, *|
          mark = { same: " ", del: "-", add: "+" }.fetch(op)
          out << mark << line
          out << "\n\\ No newline at end of file\n" unless line.end_with?("\n")
        end
      end
      out
    end

    # [[op, line, index in a, index in b], ...] in order.
    def edits(a, b)
      lcs = Array.new(a.size + 1) { Array.new(b.size + 1, 0) }
      (a.size - 1).downto(0) do |i|
        (b.size - 1).downto(0) do |j|
          lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : [lcs[i + 1][j], lcs[i][j + 1]].max
        end
      end
      i = j = 0
      ops = []
      while i < a.size || j < b.size
        if i < a.size && j < b.size && a[i] == b[j]
          ops << [:same, a[i], i, j]
          i += 1
          j += 1
        elsif i < a.size && (j == b.size || lcs[i + 1][j] >= lcs[i][j + 1])
          ops << [:del, a[i], i, j] # a deletion first, as diff(1) prints it
          i += 1
        else
          ops << [:add, b[j], i, j]
          j += 1
        end
      end
      ops
    end

    def hunks(ops, context)
      changed = ops.each_index.reject { ops[_1].first == :same }
      groups = []
      changed.each do |k|
        lo = [k - context, 0].max
        hi = [k + context, ops.size - 1].min
        if groups.any? && lo <= groups.last.last + 1
          groups.last[1] = hi
        else
          groups << [lo, hi]
        end
      end
      groups.map { |lo, hi| ops[lo..hi] }
    end
  end
end
