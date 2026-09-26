# frozen_string_literal: true

require "json"

require_relative "cronwatch/version"
require_relative "cronwatch/js"
require_relative "cronwatch/types"
require_relative "cronwatch/duration"
require_relative "cronwatch/stats"
require_relative "cronwatch/output"
require_relative "cronwatch/schedule"
require_relative "cronwatch/evaluate"
require_relative "cronwatch/format"
require_relative "cronwatch/serialize"
require_relative "cronwatch/job"
require_relative "cronwatch/http"
require_relative "cronwatch/stores/memory"
require_relative "cronwatch/alerts/console"
require_relative "cronwatch/alerts/custom"
require_relative "cronwatch/alerts/slack"
require_relative "cronwatch/alerts/discord"
require_relative "cronwatch/alerts/webhook"
require_relative "cronwatch/client"

# Cron and scheduled-job monitoring that lives inside your app.
#
#   CW = Cronwatch.new(alerts: [Cronwatch::Alerts::Slack.new(webhook_url: ENV.fetch("SLACK_WEBHOOK_URL"))])
#   NIGHTLY = CW.job("nightly-report", schedule: "0 2 * * *", grace: "15m")
#   NIGHTLY.run { |job| job.log("Report written") }
#
# Or configure one client for the whole app and reach it as Cronwatch.client.
module Cronwatch
  # The options Cronwatch.configure sets. Anything left unset takes the client's default.
  class Configuration
    OPTIONS = %i[store alerts triage cron_secret retention defaults now on_error].freeze

    attr_accessor(*OPTIONS)

    def initialize
      @cron_secret = Client::UNSET
    end

    def to_options
      OPTIONS.each_with_object({}) do |option, out|
        value = public_send(option)
        next if value.nil? && option != :cron_secret

        out[option] = value
      end
    end
  end

  @lock = Mutex.new
  @client = nil

  class << self
    # A new client. See Client#initialize for the options.
    def new(**options)
      Client.new(**options)
    end

    # Builds the app's client:
    #
    #   Cronwatch.configure do |c|
    #     c.store = Cronwatch::Stores::ActiveRecord.new
    #     c.alerts = [Cronwatch::Alerts::Slack.new(webhook_url: ENV["SLACK_WEBHOOK_URL"])]
    #   end
    #
    # Configuring again replaces the client and stops the old one's interval.
    def configure
      config = Configuration.new
      yield config if block_given?
      client = Client.new(**config.to_options)
      previous = @lock.synchronize do
        old = @client
        @client = client
        old
      end
      previous&.stop
      client
    end

    # The configured client, or one with the defaults if configure was never called.
    def client
      @lock.synchronize { @client ||= Client.new }
    end

    def client=(client)
      @lock.synchronize { @client = client }
    end
  end
end
