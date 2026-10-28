# frozen_string_literal: true

# A stand-in for the builder's wrapper gem, IC, as the canister half sees it
# on a canister (ADR-0060): IC::DATA_DIR, IC.caller with controller?, and
# IC.refuse raising IC::Refusal, which descends from Exception. Tests choose
# whether the caller is a controller.
module IC
  DATA_DIR = "/data-is-set-per-example"

  class Refusal < Exception; end # rubocop:disable Lint/InheritException

  Caller = Struct.new(:controller) do
    def controller? = controller
  end

  class << self
    attr_writer :controller

    def caller = Caller.new(@controller.nil? || @controller)
    def refuse(reason) = raise(Refusal, reason)
  end
end
