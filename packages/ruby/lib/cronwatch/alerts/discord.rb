# frozen_string_literal: true

module Cronwatch
  module Alerts
    # Sends alerts to a Discord channel through a webhook (Server Settings,
    # Integrations, Webhooks).
    class Discord
      COLOR = {
        missed: 0xb7791f, failed: 0xc62828, stuck: 0xc62828, slow: 0xb7791f, over_budget: 0xb7791f, under_floor: 0xb7791f,
        recovered: 0x1f8a4c,
      }.freeze

      # The longest embed description Discord takes. The title (under 256)
      # and it stay well inside the embed's 6000.
      DESCRIPTION_MAX = 4096
      private_constant :COLOR, :DESCRIPTION_MAX

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
        embed["description"] = Discord.embed_description(alert)
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

      # The message in a code block, then the triage. Each part has its own
      # cap, and escaping can grow both, so the whole is held to
      # DESCRIPTION_MAX (in UTF-16 units) by cutting the message's block,
      # never the triage: Discord refuses a longer one on every retry.
      #
      # Where a cap cuts a surrogate pair the high half is kept, as the SDK's
      # slice keeps it, and written as JSON.stringify writes it (see
      # JS.lone_surrogate). The cut of the block to the room left leaves out
      # a pair or a lone half, as the SDK's cut does.
      def self.embed_description(alert)
        triage = ""
        triage_units = 0
        if alert.triage && !alert.triage.empty?
          head, lone = JS.slice16(alert.triage, 1000)
          triage = "\n**Triage:** #{escape_markdown(head)}"
          triage_units = JS.length16(triage)
          if lone
            triage += JS.lone_surrogate(lone)
            triage_units += 1
          end
        end
        room = DESCRIPTION_MAX - "```\n".length - "\n```".length - triage_units
        head, lone = JS.slice16(alert.message, 3800)
        block = code_block_safe(head)
        block = lone && JS.length16(block) + 1 <= room ? block + JS.lone_surrogate(lone) : JS.head16(block, room)
        "```\n" + block + "\n```" + triage
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
