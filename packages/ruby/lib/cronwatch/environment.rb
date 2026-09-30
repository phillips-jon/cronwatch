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

    # Whether development or test was named by the app rather than by its
    # server, for the dashboard's own token (Cronwatch::Web). Puma, Unicorn,
    # Thin and rackup set RACK_ENV to "development" when nothing names an
    # environment, so under one of them, in production too, RACK_ENV alone
    # reads "development". There it takes Rails.env, RAILS_ENV or APP_ENV
    # (Sinatra's) to say development; RACK_ENV "test" still counts, as no
    # server sets it.
    def stated_development?
      return false unless development?
      return true if defined?(::Rails) && ::Rails.respond_to?(:env) && !::Rails.env.to_s.empty?

      stated = [ENV.fetch("RAILS_ENV", nil), ENV.fetch("APP_ENV", nil)].find { |value| value && !value.empty? }
      return DEVELOPMENT.include?(stated) unless stated.nil?

      name == "test" || !defaulting_server?
    end

    # A server that sets RACK_ENV when it is unset is running this process.
    def defaulting_server?
      return true if defined?(::Puma::Server) || defined?(::Puma::Launcher) || defined?(::Unicorn::HttpServer) ||
                     defined?(::Thin::Server) || defined?(::Rackup::Server)

      # Rack 2 autoloads its server: counted only once it has loaded.
      defined?(::Rack) && ::Rack.const_defined?(:Server, false) && ::Rack.autoload?(:Server).nil?
    end
  end
end
