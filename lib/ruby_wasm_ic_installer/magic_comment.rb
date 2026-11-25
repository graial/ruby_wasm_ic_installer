# frozen_string_literal: true

module RubyWasmIcInstaller
  # A file's magic comment, against the three encodings a `minimal` canister
  # claims: UTF-8, US-ASCII and ASCII-8BIT (ADR-0053). The comment is read in
  # C before any Ruby runs, so no stand-in can help: an alias of one of the
  # three is rewritten to its canonical name, found with MRI's own
  # Encoding.find (W29, Q9), and any other encoding refuses the gem.
  #
  # That includes the nine other names a canister lists (UTF-16 and UTF-32
  # and their byte orders, UTF8-MAC, EUC-JP, Windows-31J): they are names
  # with no encoding behind them, so a file whose comment names one loads
  # with no error and is read as ASCII-8BIT, its literals wrong (W30, 28
  # October 2026). A change to the table is a release of this gem.
  #
  # From Release 0.13.0 both Builds link every Ruby 3.3 encoding, with its
  # aliases, so any encoding Ruby knows is accepted as written and nothing is
  # rewritten. Ruby itself still cannot read source in an encoding that is not
  # ASCII-compatible (UTF-16, UTF-32), so those are refused on every Release.
  module MagicComment
    CLAIMED_ENCODINGS = %w[ASCII-8BIT UTF-8 US-ASCII].freeze

    # Listed by a `minimal` canister and not claimed: refused with their own
    # reason, since an author may expect them to work.
    UNCLAIMED_ENCODINGS = %w[UTF-16BE UTF-16LE UTF-32BE UTF-32LE UTF-16 UTF-32 UTF8-MAC EUC-JP Windows-31J].freeze

    # Ruby reads a magic comment on the first line, or the second after a
    # shebang. `coding: x`, `coding=x`, `-*- coding: x -*-` and
    # `encoding: x` all match.
    PATTERN = /\A(#.*?coding[:=][ \t]*)([\w.\-]+)/

    Rewrite = Struct.new(:file, :line, :from, :to, keyword_init: true)

    class Refused < Error; end

    module_function

    # [new_body, rewrite or nil]; raises Refused for an encoding a canister
    # lacks or one MRI does not know. `release`: the target Release's
    # Gem::Version, or nil when it is not known.
    def fix(file, body, release: nil)
      lines = body.b.lines
      idx = comment_line(lines) or return [body, nil]
      m = lines[idx].match(PATTERN)
      name = m[2]
      return [body, nil] if Rules.every_encoding?(release) && readable!(file, name)

      canonical = canonical!(file, name, hint: release.nil?)
      return [body, nil] if canonical.casecmp?(name)

      lines[idx] = lines[idx].sub(PATTERN) { "#{m[1]}#{canonical.downcase}" }
      [lines.join, Rewrite.new(file: file, line: idx + 1, from: name, to: canonical.downcase)]
    end

    def comment_line(lines)
      return 0 if lines[0]&.match?(PATTERN)
      return 1 if lines[0]&.start_with?("#!") && lines[1]&.match?(PATTERN)

      nil
    end

    def find!(file, name)
      Encoding.find(name)
    rescue ArgumentError
      raise Refused, "#{file} names the encoding #{name.inspect}, which Ruby does not know"
    end

    def readable!(file, name)
      enc = find!(file, name)
      return true if enc.ascii_compatible?

      raise Refused, "#{file} is written in #{enc.name} (its magic comment says #{name.inspect}), which is not " \
                     "ASCII-compatible: Ruby cannot read source in it"
    end

    def canonical!(file, name, hint: false)
      enc = find!(file, name)
      known = CLAIMED_ENCODINGS.find { _1.casecmp?(enc.name) }
      return known if known

      said = "#{file} is written in #{enc.name} (its magic comment says #{name.inspect})"
      tail = hint ? "; if the canister runs Release #{Rules::EVERY_ENCODING_FROM} or later, declare `release:`: " \
                    "from #{Rules::EVERY_ENCODING_FROM} it has every Ruby 3.3 encoding" : ""
      if UNCLAIMED_ENCODINGS.any? { _1.casecmp?(enc.name) }
        raise Refused, "#{said}: a minimal canister lists that name but has no #{enc.name} behind it, so the file " \
                       "would load as ASCII-8BIT; only #{CLAIMED_ENCODINGS.join(', ')} are claimed#{tail}"
      end
      raise Refused, "#{said}, which a minimal canister does not have: it has #{CLAIMED_ENCODINGS.join(', ')}, " \
                     "and transcodes nothing#{tail}"
    end
  end
end
