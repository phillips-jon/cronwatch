# frozen_string_literal: true

module Cronwatch
  # The app's environment, read as every CronWatch library reads it: the
  # first of CRONWATCH_ENV, APP_ENV, then the app's own (Rails.env when Rails
  # is loaded, else RAILS_ENV, then RACK_ENV) that holds more than spaces,
  # trimmed and lowercased, with "prod" read as "production" and "dev",
  # "local", "test", and "testing" as "development". None set is neither,
  # which is the safe reading. The SDK reads NODE_ENV where this reads the
  # app's own.
  #
  # @api private
  module Environment
    # The variables read before the app's own, in order.
    SHARED = %w[CRONWATCH_ENV APP_ENV].freeze
    ALIASES = {
      "prod" => "production", "dev" => "development", "local" => "development", "test" => "development",
      "testing" => "development",
    }.freeze
    private_constant :SHARED, :ALIASES

    module_function

    # "production", "development", "staging", ... or nil when nothing names one.
    def environment
      _, value = source
      return nil if value.nil?

      value = JS.trim(value).downcase
      ALIASES.fetch(value, value)
    end

    # Where the environment was read from and its value as set:
    # ["CRONWATCH_ENV", " dev"], ["Rails.env", "test"], or nil.
    def source
      SHARED.each do |variable|
        value = ENV.fetch(variable, nil)
        return [variable, value] if present?(value)
      end
      if defined?(::Rails) && ::Rails.respond_to?(:env)
        env = ::Rails.env.to_s
        return ["Rails.env", env] if present?(env)
      end
      %w[RAILS_ENV RACK_ENV].each do |variable|
        value = ENV.fetch(variable, nil)
        return [variable, value] if present?(value)
      end
      nil
    end

    def present?(value)
      !value.nil? && !blank?(value)
    end

    # Whether a String is empty or only whitespace, as JavaScript's
    # String.prototype.trim sees it (JS::WHITESPACE). Bytes that are not
    # UTF-8 are not whitespace.
    def blank?(value)
      JS.trim(value.dup.force_encoding(Encoding::UTF_8).scrub).empty?
    end

    # A secret from the environment (CRONWATCH_TOKEN, CRON_SECRET): nil when
    # the variable is unset, empty, or only whitespace, so a blank value counts
    # as not set and the routes fail closed. Any other value is used as it
    # is, untrimmed.
    def secret(variable)
      value = ENV.fetch(variable, nil)
      present?(value) ? value : nil
    end

    # A token or secret passed in code: a String, or nil. A String that is
    # empty or only whitespace counts as not given (nil here; the caller
    # tells that from nil the opt-out). Anything else (false, a number, a
    # Symbol) raises TypeError naming the option, so it never becomes a
    # password.
    def secret_option(value, what)
      return nil if value.nil?
      unless value.is_a?(String)
        kind = [true, false].include?(value) ? value.to_s : value.class.name
        raise TypeError, "#{what} must be a String, or nil to opt out, not #{kind}"
      end

      blank?(value) ? nil : value
    end

    # The framework's own name for the environment, as it sets it: Rails.env
    # when Rails is loaded, otherwise RAILS_ENV, then RACK_ENV, or nil. The
    # section of a Solid Queue file is chosen by it, as Solid Queue does.
    def name
      if defined?(::Rails) && ::Rails.respond_to?(:env)
        env = ::Rails.env.to_s
        return env unless env.empty?
      end
      [ENV.fetch("RAILS_ENV", nil), ENV.fetch("RACK_ENV", nil)].find { |value| value && !value.empty? }
    end

    # Development (including test): Cronwatch::Web without a token serves only then.
    def development?
      environment == "development"
    end

    def production?
      environment == "production"
    end

    # Whether development was named by the app rather than by its server,
    # for the dashboard's own token (Cronwatch::Web). Puma, Unicorn, Thin,
    # and rackup set RACK_ENV to "development" when nothing names an
    # environment, so under one of them, in production too, RACK_ENV alone
    # reads "development". There it takes CRONWATCH_ENV, APP_ENV, Rails.env,
    # or RAILS_ENV to say development; any other value of RACK_ENV that reads
    # as development ("test", "dev") still counts, as no server sets it.
    def stated_development?
      return false unless development?

      variable, value = source
      return true unless variable == "RACK_ENV" && JS.trim(value).downcase == "development"

      !defaulting_server?
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
