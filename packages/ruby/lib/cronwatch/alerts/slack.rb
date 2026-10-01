# frozen_string_literal: true

module Cronwatch
  module Alerts
    # Sends alerts to a Slack channel through an incoming webhook.
    #
    #   Cronwatch::Alerts::Slack.new(webhook_url: ENV.fetch("SLACK_WEBHOOK_URL"),
    #                                link: ->(alert) { "https://app.example.com/cronwatch/jobs/#{alert.job}" })
    class Slack
      EMOJI = {
        missed: ":hourglass_flowing_sand:", failed: ":x:", stuck: ":no_entry:", slow: ":turtle:",
        over_budget: ":moneybag:", recovered: ":white_check_mark:",
      }.freeze
      private_constant :EMOJI

      attr_reader :name

      def initialize(webhook_url:, link: nil, http: HTTP.default)
        raise ArgumentError, "Cronwatch::Alerts::Slack needs a webhook_url" if webhook_url.nil? || webhook_url.to_s.empty?

        @name = "slack"
        @webhook_url = webhook_url
        @link = link
        @http = http
      end

      def call(alert)
        url = @link&.call(alert)
        title = "#{EMOJI[alert.type]} *#{Slack.escape(alert.title)}*#{url && !url.empty? ? " (<#{url}|open>)" : ""}"
        body = JS.head16(Slack.code_block_safe(Slack.escape(alert.message)), 2900)
        blocks = [
          { "type" => "section", "text" => { "type" => "mrkdwn", "text" => title } },
          { "type" => "section", "text" => { "type" => "mrkdwn", "text" => "```#{body}```" } },
        ]
        if alert.triage && !alert.triage.empty?
          # Its own block, so a long diagnosis cannot push a block past Slack's 3000 character limit.
          blocks << { "type" => "section", "text" => { "type" => "mrkdwn", "text" => JS.head16("_Triage:_ #{Slack.escape(alert.triage)}", 3000) } }
        end
        payload = {
          # The notification fallback is parsed as mrkdwn too, so it is escaped like the blocks.
          "text" => Slack.escape("#{alert.title}\n#{alert.message}"),
          "blocks" => blocks,
        }
        response = @http.post(@webhook_url, JS.json(payload), { "content-type" => "application/json" })
        raise "Slack webhook answered #{response.status}: #{JS.head16(response.body.to_s, 200)}" unless response.ok?
      end

      # Slack's three control characters. Escaping < and > also stops <!channel> and <url|links>.
      def self.escape(text)
        text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
      end

      # Breaks up ``` so text inside a code block cannot close it.
      def self.code_block_safe(text)
        text.gsub("```", "`\u200b`\u200b`")
      end
    end
  end
end
