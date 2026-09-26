# frozen_string_literal: true

module Cronwatch
  # The app's environment, read one way everywhere: Rails.env when Rails is
  # loaded, otherwise RAILS_ENV, then RACK_ENV. The SDK reads NODE_ENV.
  module Environment
    DEVELOPMENT = %w[development test].freeze

    module_function

    # "production", "development", ... or nil when nothing names one.
    def name
      if defined?(::Rails) && ::Rails.respond_to?(:env)
        env = ::Rails.env.to_s
        return env unless env.empty?
      end
      [ENV.fetch("RAILS_ENV", nil), ENV.fetch("RACK_ENV", nil)].find { |value| value && !value.empty? }
    end

    # Development or test: Cronwatch::Web without a token serves only then.
    def development?
      DEVELOPMENT.include?(name)
    end

    def production?
      name == "production"
    end
  end
end
