# frozen_string_literal: true

# The end-to-end Application: roda_on_minimal's Books app (0.7.0), with Rack,
# Roda and both ruby_wasm_ic gems installed through calls by the Installer, not
# packed. Until they are installed and an upgrade has loaded them, the
# gateway answers 503. setup writes the Installer's block above this comment.
W28_APP =
  begin
    require "ruby_wasm_ic_minimal" # first: the Encoding constants and the stand-ins
    require "ruby_wasm_ic_rack"
    require "roda"

    $books = { 1 => { title: "Noli Me Tangere", author: "Rizal" } }

    class Books < Roda
      route do |r|
        response["content-type"] = "text/plain"
        r.on "books" do
          r.get "search" do
            "q=#{r.params['q']}"
          end
          r.is { r.get { $books.map { |id, b| "#{id}: #{b[:title]}" }.join("\n") } }
        end
      end
    end

    module RubyWasmIcRack
      def self.input(bytes) = StringIO.new(bytes.b)
    end

    Books.app
  rescue LoadError
    nil
  end

NOT_YET = { status_code: 503, headers: [["content-type", "text/plain"]], body: "w28 app not installed".b,
            upgrade: nil }.freeze

def http_request(req) = W28_APP ? RubyWasmIcRack.query(W28_APP, req) : NOT_YET
def http_request_update(req) = W28_APP ? RubyWasmIcRack.update(W28_APP, req) : NOT_YET
