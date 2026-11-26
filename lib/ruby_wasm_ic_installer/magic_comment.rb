# frozen_string_literal: true

module RubyWasmIcInstaller
  # A file's magic comment. Every Release this Installer knows (0.13.0 on)
  # links every Ruby 3.3 encoding on both Builds, with its aliases, so any
  # encoding Ruby knows is accepted as written. The comment is read in C
  # before any Ruby runs, so a name Ruby does not know, or an encoding Ruby
  # cannot read source in (UTF-16, UTF-32: not ASCII-compatible), refuses the
  # gem.
  module MagicComment
    # Ruby reads a magic comment on the first line, or the second after a
    # shebang. `coding: x`, `coding=x`, `-*- coding: x -*-` and
    # `encoding: x` all match.
    PATTERN = /\A(#.*?coding[:=][ \t]*)([\w.\-]+)/

    class Refused < Error; end

    module_function

    # Raises Refused when `body`'s magic comment names an encoding Ruby does
    # not know or cannot read source in.
    def check!(file, body)
      lines = body.b.lines
      idx = comment_line(lines) or return
      name = lines[idx][PATTERN, 2]
      enc = find!(file, name)
      return if enc.ascii_compatible?

      raise Refused, "#{file} is written in #{enc.name} (its magic comment says #{name.inspect}), which is not " \
                     "ASCII-compatible: Ruby cannot read source in it"
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
  end
end
