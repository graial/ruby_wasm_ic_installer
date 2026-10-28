# frozen_string_literal: true

require "fileutils"

module RubyWasmIcInstaller
  # `ruby_wasm_ic_installer setup <app_dir>` (W29, Q16 and Q17): wires an
  # Application in. It writes a marked block of Declarations into its
  # ic-interface.rb, a marked block at the top of its app.rb that requires the
  # canister half, and the canister half itself under
  # vendor/ruby_wasm_ic_installer/. Idempotent: run twice, it changes nothing
  # the second time.
  #
  # When what is there differs from what it would write (the author's edit,
  # or an older version's block), it shows the diff and asks before writing;
  # with no terminal it aborts unless told `yes`. The Installer's names
  # declared or defined outside the markers abort it, since it cannot merge
  # into the author's own lines. `check` only reports. All files are written,
  # or none.
  class AppSetup
    OPEN = "# >>> ruby_wasm_ic_installer"
    CLOSE = "# <<< ruby_wasm_ic_installer"
    NOTE = " (written by `ruby_wasm_ic_installer setup`; edit outside these lines)"
    BLOCK = /^#{Regexp.escape(OPEN)}.*?^#{Regexp.escape(CLOSE)}\n?/m
    NAMES = %w[install_put install_commit install_remove installed].freeze
    TYPES = %w[InstallFile InstallSetup InstallCommit Installed].freeze
    VENDOR = File.join("vendor", "ruby_wasm_ic_installer")
    CANISTER_SOURCE = File.expand_path("canister.rb", __dir__)

    INTERFACE = <<~RUBY
      #{OPEN}#{NOTE}
      type :InstallFile,   record(path: Text, body: Blob)
      type :InstallSetup,  record(generation: Nat64, load_paths: Vec[Text])
      type :InstallCommit, record(gems: Vec[Text], setup: Opt[:InstallSetup])
      type :Installed,     record(running: Opt[Nat64], pending: Opt[Nat64], gems: Vec[Text], partial: Vec[Text],
                                  load_paths: Vec[Text], running_paths: Vec[Text])
      update :install_put,    takes: [Vec[:InstallFile]], returns: Text
      update :install_commit, takes: [:InstallCommit],    returns: Text
      update :install_remove, takes: [Text],              returns: Text
      query  :installed,      takes: [],                  returns: :Installed
      #{CLOSE}
    RUBY

    APP = <<~RUBY
      #{OPEN}#{NOTE}
      $LOAD_PATH.unshift(File.join(__dir__, "#{VENDOR}"))
      require "ruby_wasm_ic_installer/canister"
      #{CLOSE}
    RUBY

    Change = Struct.new(:path, :old, :new, :edited, keyword_init: true) do
      def diff(root)
        rel = path.delete_prefix("#{root}/")
        Diff.unified(old.to_s, new, from: old ? "a/#{rel}" : "/dev/null", to: "b/#{rel}")
      end
    end

    class Aborted < Error; end

    # `io`: where it writes; `input`: where it reads an answer; `tty`: whether
    # it may ask.
    def initialize(app_dir, io: $stdout, input: $stdin, tty: nil)
      @root = File.expand_path(app_dir)
      @io = io
      @input = input
      @tty = tty.nil? ? input.respond_to?(:tty?) && input.tty? : tty
    end

    def changes
      @changes ||= begin
        check_application!
        [interface_change, app_change, vendor_change].compact
      end
    end

    # Exit status for --check: 0 when nothing would change.
    def check
      changes.each { @io.puts(_1.diff(@root)) }
      @io.puts(changes.empty? ? "setup is current in #{@root}" : "setup would change #{changes.size} file(s)")
      changes.empty? ? 0 : 1
    end

    def run(yes: false)
      if changes.empty?
        @io.puts("nothing to change: #{@root} is set up")
        return []
      end
      edited = changes.select(&:edited)
      unless edited.empty?
        @io.puts("These lines differ from what setup writes (your edit, or an older setup's):")
        edited.each { @io.puts(_1.diff(@root)) }
        confirm!(yes)
      end
      changes.each do |c|
        FileUtils.mkdir_p(File.dirname(c.path))
        File.write(c.path, c.new)
        @io.puts("wrote #{c.path.delete_prefix("#{@root}/")}")
      end
      @io.puts("pack the Application again, and deploy it, for the Installer's methods to exist")
      changes
    end

    private

    def check_application!
      raise Error, "#{@root} has no app.rb: it is not an Application" unless File.file?(file("app.rb"))
      return if File.file?(file("ic-interface.rb"))

      raise Error, "#{@root} has no ic-interface.rb: the Installer's methods are Declarations, and an " \
                   "Application without an Interface file is served `run` alone (ADR-0056); write one first"
    end

    def file(name) = File.join(@root, name)

    def interface_change
      path = file("ic-interface.rb")
      old = File.read(path)
      conflicts!(path, old, /^\s*(?:update|query)\s+:(#{NAMES.join('|')})\b|^\s*type\s+:(#{TYPES.join('|')})\b/)
      replace_or_add(path, old, INTERFACE, at_top: false)
    end

    def app_change
      path = file("app.rb")
      old = File.read(path)
      conflicts!(path, old, /^\s*def\s+(?:self\.)?(#{NAMES.join('|')})\b/)
      replace_or_add(path, old, APP, at_top: true)
    end

    def vendor_change
      path = File.join(@root, VENDOR, "ruby_wasm_ic_installer", "canister.rb")
      new = File.read(CANISTER_SOURCE)
      old = File.file?(path) ? File.read(path) : nil
      return nil if old == new

      Change.new(path: path, old: old, new: new, edited: !old.nil?)
    end

    # The Installer's names outside the markers: abort, with where they are.
    def conflicts!(path, text, pattern)
      outside = text.gsub(BLOCK) { |b| "\n" * b.count("\n") }
      hits = outside.lines.each_with_index.select { |l, _| l.match?(pattern) }
      return if hits.empty?

      where = hits.map { |l, i| "  #{path.delete_prefix("#{@root}/")}:#{i + 1}: #{l.strip}" }.join("\n")
      raise Aborted, "the Installer's names are already declared or defined outside its markers, and setup cannot " \
                     "merge into your own lines; remove them, or move them inside the markers:\n#{where}"
    end

    def replace_or_add(path, old, block, at_top:)
      if old.match?(BLOCK)
        new = old.sub(BLOCK, block)
        return nil if new == old

        return Change.new(path: path, old: old, new: new, edited: true)
      end
      new = at_top ? insert_at_top(old, block) : "#{old}#{old.end_with?("\n") || old.empty? ? '' : "\n"}\n#{block}"
      Change.new(path: path, old: old, new: new, edited: false)
    end

    # After a shebang and any magic comments, which must stay first.
    def insert_at_top(old, block)
      lines = old.lines
      n = 0
      n += 1 while n < lines.size && (lines[n].start_with?("#!") || lines[n].match?(/\A#.*(?:coding[:=]|frozen_string_literal|warn_indent|shareable_constant_value)/))
      (lines[0, n] + [block] + lines[n..]).join
    end

    def confirm!(yes)
      return if yes
      raise Aborted, "aborted: no terminal to ask on; run again with --yes to write these changes" unless @tty

      @io.print("Apply? [y/N] ")
      answer = @input.gets.to_s.strip.downcase
      raise Aborted, "aborted: nothing was written" unless %w[y yes].include?(answer)
    end
  end
end
