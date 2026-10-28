# frozen_string_literal: true

module RubyWasmIcInstaller
  # A file's magic comment, against the twelve encodings a `minimal` canister
  # knows, each by one name and no alias (W26; ADR-0053's amendment of
  # 28 October 2026). The comment is read in C before any Ruby runs, so no
  # stand-in can help: an alias of one of the twelve is rewritten to its
  # canonical name, found with MRI's own Encoding.find; any other encoding
  # refuses the gem (W29, Q9). A change to the table is a release of this gem.
  module MagicComment
    CANISTER_ENCODINGS = %w[
      ASCII-8BIT UTF-8 US-ASCII UTF-16BE UTF-16LE UTF-32BE UTF-32LE UTF-16 UTF-32 UTF8-MAC EUC-JP Windows-31J
    ].freeze

    # Ruby reads a magic comment on the first line, or the second after a
    # shebang. `coding: x`, `coding=x`, `-*- coding: x -*-` and
    # `encoding: x` all match.
    PATTERN = /\A(#.*?coding[:=][ \t]*)([\w.\-]+)/

    Rewrite = Struct.new(:file, :line, :from, :to, keyword_init: true)

    class Refused < Error; end

    module_function

    # [new_body, rewrite or nil]; raises Refused for an encoding a canister
    # lacks or one MRI does not know.
    def fix(file, body)
      lines = body.b.lines
      idx = comment_line(lines) or return [body, nil]
      m = lines[idx].match(PATTERN)
      name = m[2]
      canonical = canonical!(file, name)
      return [body, nil] if canonical.casecmp?(name)

      lines[idx] = lines[idx].sub(PATTERN) { "#{m[1]}#{canonical.downcase}" }
      [lines.join, Rewrite.new(file: file, line: idx + 1, from: name, to: canonical.downcase)]
    end

    def comment_line(lines)
      return 0 if lines[0]&.match?(PATTERN)
      return 1 if lines[0]&.start_with?("#!") && lines[1]&.match?(PATTERN)

      nil
    end

    def canonical!(file, name)
      enc = begin
        Encoding.find(name)
      rescue ArgumentError
        raise Refused, "#{file} names the encoding #{name.inspect}, which Ruby does not know"
      end
      known = CANISTER_ENCODINGS.find { _1.casecmp?(enc.name) }
      return known if known

      raise Refused, "#{file} is written in #{enc.name} (its magic comment says #{name.inspect}), which a " \
                     "minimal canister does not have: it knows #{CANISTER_ENCODINGS.join(', ')}, and transcodes nothing"
    end
  end
end
