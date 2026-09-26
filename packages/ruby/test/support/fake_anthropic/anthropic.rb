# frozen_string_literal: true

# Stands in for the anthropic gem when it is not installed: the gem is an
# optional dependency, and the triage tests pass their own client anyway.
# Only what cronwatch/triage/anthropic touches without a client is here.
module Anthropic
  FAKE = true

  class Client
    attr_reader :options

    def initialize(**options)
      @options = options
    end
  end
end
