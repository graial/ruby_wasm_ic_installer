# frozen_string_literal: true

module RubyWasmIcInstaller
  # The off-chain half's Candid: only the few fixed types the Installer's own
  # Declarations use, encoded and decoded by hand, so the gem needs no Candid
  # library. Arguments go to `icp canister call --args-format bin` as these
  # bytes, and replies come back from `-o hex`.
  #
  # Encoding writes exactly the types below. Decoding reads any well-formed
  # message whose values are records, opts, vecs, text, blob, bool and the
  # unsigned integers, and gives records as Hashes keyed by field hash (named
  # through #record, below), which is all the canister half replies with.
  module Candid
    class Error < StandardError; end

    MAGIC = "DIDL".b

    # Type opcodes (the Candid spec's negative type codes, as SLEB128).
    NULL = -1
    BOOL = -2
    NAT = -3
    NAT8 = -5
    NAT16 = -6
    NAT32 = -7
    NAT64 = -8
    TEXT = -15
    OPT = -18
    VEC = -19
    RECORD = -20

    module_function

    def leb(n)
      raise Error, "cannot encode a negative number as LEB128: #{n}" if n.negative?

      out = +"".b
      loop do
        byte = n & 0x7f
        n >>= 7
        out << (n.zero? ? byte : byte | 0x80).chr
        return out if n.zero?
      end
    end

    def sleb(n)
      out = +"".b
      loop do
        byte = n & 0x7f
        n >>= 7
        done = (n.zero? && byte & 0x40 == 0) || (n == -1 && byte & 0x40 != 0)
        out << (done ? byte : byte | 0x80).chr
        return out if done
      end
    end

    # The IDL hash of a field name.
    def idl_hash(name)
      name.to_s.bytes.reduce(0) { |h, b| (h * 223 + b) % (2**32) }
    end

    def text_value(s)
      s = s.to_s
      raise Error, "text must be valid UTF-8: #{s.inspect[0, 60]}" unless s.dup.force_encoding("UTF-8").valid_encoding?

      leb(s.bytesize) + s.b
    end

    def blob_value(bytes) = leb(bytes.bytesize) + bytes.b

    # (vec record { path : text; body : blob }): one install_put batch.
    def install_files(files)
      # The table in didc's order, depth first from the argument, so the
      # bytes equal @dfinity/didc's for the same value (spec/fixtures).
      table = types(
        "\x6d".b + sleb(1),                                           # 0: vec InstallFile
        record_type([["path", sleb(TEXT)], ["body", sleb(2)]]),       # 1: InstallFile
        "\x6d".b + sleb(NAT8)                                         # 2: blob
      )
      values = leb(files.size) + files.map do |f|
        record_value("path" => text_value(f.fetch(:path)), "body" => blob_value(f.fetch(:body)))
      end.join.b
      MAGIC + table + leb(1) + sleb(0) + values
    end

    # The size install_files would give one file inside a batch: what the
    # batching counts against a call's budget.
    def install_file_size(path, body)
      leb(path.bytesize).bytesize + path.bytesize + leb(body.bytesize).bytesize + body.bytesize
    end

    # The fixed bytes of an install_files message holding `count` files.
    def install_files_overhead(count) = install_files([]).bytesize - 1 + leb(count).bytesize

    # (text)
    def text_arg(s) = MAGIC + leb(0) + leb(1) + sleb(TEXT) + text_value(s)

    # ()
    def empty_args = MAGIC + leb(0) + leb(0)

    # (record { gems : vec text; setup : opt record { generation : nat64;
    # load_paths : vec text } }): one install_commit.
    def install_commit(gems:, setup: nil)
      table = types(
        record_type([["gems", sleb(1)], ["setup", sleb(2)]]),                         # 0: InstallCommit
        "\x6d".b + sleb(TEXT),                                                        # 1: vec text
        "\x6e".b + sleb(3),                                                           # 2: opt InstallSetup
        record_type([["generation", sleb(NAT64)], ["load_paths", sleb(1)]])           # 3: InstallSetup
      )
      setup_value =
        if setup
          "\x01".b + record_value("generation" => nat64_value(setup.fetch(:generation)),
                                  "load_paths" => texts_value(setup.fetch(:load_paths)))
        else
          "\x00".b
        end
      MAGIC + table + leb(1) + sleb(0) + record_value("gems" => texts_value(gems), "setup" => setup_value)
    end

    def texts_value(list) = leb(list.size) + list.map { text_value(_1) }.join.b

    def nat64_value(n)
      raise Error, "nat64 out of range: #{n}" unless n.is_a?(Integer) && n.between?(0, 2**64 - 1)

      [n].pack("Q<")
    end

    def types(*entries) = leb(entries.size) + entries.join.b

    # A record type entry, its fields sorted by hash.
    def record_type(fields)
      sorted = fields.sort_by { |name, _| idl_hash(name) }
      "\x6c".b + leb(sorted.size) + sorted.map { |name, t| leb(idl_hash(name)) + t }.join.b
    end

    # A record value: its fields' bytes in hash order.
    def record_value(fields) = fields.sort_by { |name, _| idl_hash(name) }.map(&:last).join.b

    # Decodes a reply of one value; records come back keyed by field hash.
    def decode(bytes) = Reader.new(bytes).message

    # A decoded record's fields by name.
    def record(value, *names)
      raise Error, "expected a record, got #{value.class}" unless value.is_a?(Hash)

      names.to_h do |name|
        h = idl_hash(name)
        raise Error, "the record has no field #{name}" unless value.key?(h)

        [name.to_sym, value[h]]
      end
    end

    # The one-message reader. Types are resolved from the type table; values
    # are read by them. Recursion is bounded, so a hostile reply cannot run
    # it away.
    class Reader
      MAX_DEPTH = 32

      def initialize(bytes)
        @b = bytes.b
        @i = 0
      end

      def message
        raise Error, "not a Candid message (no DIDL header)" unless take(4) == MAGIC

        @table = Array.new(uleb) { entry }
        args = Array.new(uleb) { sleb_read }
        values = args.map { |t| value(t, 0) }
        raise Error, "#{@b.bytesize - @i} trailing bytes after the message" unless @i == @b.bytesize

        values
      end

      private

      def take(n)
        raise Error, "the message ends early" if @i + n > @b.bytesize

        @b.byteslice(@i, n).tap { @i += n }
      end

      def byte = take(1).ord

      def uleb
        n = 0
        shift = 0
        loop do
          b = byte
          n |= (b & 0x7f) << shift
          return n if b < 0x80

          shift += 7
          raise Error, "a LEB128 number longer than 10 bytes" if shift > 63
        end
      end

      def sleb_read
        n = 0
        shift = 0
        loop do
          b = byte
          n |= (b & 0x7f) << shift
          shift += 7
          if b < 0x80
            n -= (1 << shift) if b & 0x40 != 0
            return n
          end
          raise Error, "a LEB128 number longer than 10 bytes" if shift > 63
        end
      end

      def entry
        case (op = sleb_read)
        when OPT, VEC then [op, sleb_read]
        when RECORD then [op, Array.new(uleb) { [uleb, sleb_read] }]
        else raise Error, "type #{op} is not one the Installer reads"
        end
      end

      def value(t, depth)
        raise Error, "nested past #{MAX_DEPTH}" if depth > MAX_DEPTH
        return primitive(t) if t.negative?

        op, inner = @table.fetch(t) { raise Error, "type index #{t} is not in the table" }
        case op
        when OPT
          case byte
          when 0 then nil
          when 1 then value(inner, depth + 1)
          else raise Error, "an opt tag that is neither 0 nor 1"
          end
        when VEC
          n = uleb
          return take(n) if inner == NAT8

          Array.new(n) { value(inner, depth + 1) }
        when RECORD
          inner.to_h { |h, ft| [h, value(ft, depth + 1)] }
        end
      end

      def primitive(t)
        case t
        when NULL then nil
        when BOOL then byte == 1
        when NAT then uleb
        when NAT8 then byte
        when NAT16 then take(2).unpack1("S<")
        when NAT32 then take(4).unpack1("L<")
        when NAT64 then take(8).unpack1("Q<")
        when TEXT
          s = take(uleb).force_encoding("UTF-8")
          raise Error, "text that is not UTF-8" unless s.valid_encoding?

          s
        else raise Error, "type #{t} is not one the Installer reads"
        end
      end
    end
  end
end
