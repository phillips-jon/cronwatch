# frozen_string_literal: true

module Cronwatch
  module Alerts
    # Sends alerts to a Discord channel through a webhook (Server Settings,
    # Integrations, Webhooks).
    class Discord
      COLOR = {
        missed: 0xb7791f, failed: 0xc62828, stuck: 0xc62828, slow: 0xb7791f, over_budget: 0xb7791f, recovered: 0x1f8a4c,
      }.freeze

      attr_reader :name

      def initialize(webhook_url:, link: nil, http: HTTP.default)
        raise ArgumentError, "Cronwatch::Alerts::Discord needs a webhook_url" if webhook_url.nil? || webhook_url.to_s.empty?

        @name = "discord"
        @webhook_url = webhook_url
        @link = link
        @http = http
      end

      def call(alert)
        url = @link&.call(alert)
        embed = { "title" => alert.title }
        embed["url"] = url if url && !url.empty?
        triage = alert.triage && !alert.triage.empty? ? "\n**Triage:** #{Discord.escape_markdown(JS.head16(alert.triage, 1000))}" : ""
        embed["description"] = "```\n#{Discord.code_block_safe(JS.head16(alert.message, 3800))}\n```#{triage}"
        embed["color"] = COLOR[alert.type]
        embed["timestamp"] = JS.iso(alert.at)
        payload = {
          "content" => alert.title,
          # Job output can hold anything, "@everyone" included; ping no one.
          "allowed_mentions" => { "parse" => [] },
          "embeds" => [embed],
        }
        response = @http.post(@webhook_url, JS.json(payload), { "content-type" => "application/json" })
        raise "Discord webhook answered #{response.status}: #{JS.head16(response.body.to_s, 200)}" unless response.ok?
      end

      # Breaks up ``` so text inside a code block cannot close it.
      def self.code_block_safe(text)
        text.gsub("```", "`\u200b`\u200b`")
      end

      # Escapes the characters Discord reads as markdown, links included.
      def self.escape_markdown(text)
        text.gsub(/[\\`*_~|\[\]()<>]/) { |c| "\\#{c}" }
      end
    end
  end
end
