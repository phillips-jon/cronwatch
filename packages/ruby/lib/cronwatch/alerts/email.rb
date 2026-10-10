# frozen_string_literal: true

module Cronwatch
  module Alerts
    # What every email channel sends: one subject, a plain text body, and a
    # small HTML body, so an alert reads the same whichever provider carries
    # it (the SDK's alerts/email.ts). Resend, Postmark, SendGrid, Mailgun, and
    # SES each take the same options:
    #
    #   from:           the sender, "alerts@example.com" or "CronWatch <alerts@example.com>"
    #   to:             one address or several
    #   subject_prefix: put in front of the title in the subject, "[prod]" say
    #   link:           ->(alert) { "https://app.example.com/cronwatch/jobs/#{alert.job}" }
    #
    # @api private
    module Email
      Message = Struct.new(:from, :to, :subject, :text, :html, keyword_init: true)

      # Not a line terminator, as JavaScript's "." reads it.
      LINE = "[^\\n\\r\\u2028\\u2029]"
      ADDRESS = Regexp.new("\\A[#{JS::WHITESPACE}]*(#{LINE}*?)[#{JS::WHITESPACE}]*<([^<>]+)>[#{JS::WHITESPACE}]*\\z")
      QUOTED = Regexp.new("\\A\"(#{LINE}*)\"\\z")

      module_function

      # Checks the shared options once, when the channel is made. Returns the recipients.
      def recipients(name, from, to)
        raise ArgumentError, "Cronwatch::Alerts::#{name} needs a from address" if from.nil? || from.to_s.empty?

        list = (to.is_a?(Array) ? to : [to]).select { |a| a.is_a?(String) && JS.trim(a) != "" }
        raise ArgumentError, "Cronwatch::Alerts::#{name} needs at least one to address" if list.empty?

        list.map { |a| JS.trim(a) }
      end

      def compose(alert, from:, to:, subject_prefix: nil, link: nil)
        url = safe_link(link&.call(alert))
        # One line: a newline in a subject is a header injection or a rejected send.
        prefix = Provider.present?(subject_prefix) ? "#{subject_prefix} " : ""
        subject = JS.head16("#{prefix}#{alert.title}".gsub(/[\r\n]+/, " "), 250)
        Message.new(from: from.to_s, to: to, subject: subject, text: Provider.plain_text(alert, url), html: html(alert, url))
      end

      # Escapes text for HTML content and double quoted attributes.
      def escape_html(text)
        text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;").gsub("'", "&#39;")
      end

      # Only http and https links are put in a mail; anything else is dropped.
      def safe_link(link)
        return nil unless Provider.present?(link)

        %r{\Ahttps?://}i.match?(link.to_s) ? link.to_s : nil
      end

      def html(alert, link)
        parts = [
          "<!doctype html>",
          '<html><body style="margin:0;padding:16px;font-family:Georgia,serif;color:#1d1b16;background:#ffffff">',
          "<p style=\"margin:0 0 12px;font-size:18px\"><strong>#{escape_html(alert.title)}</strong></p>",
          '<pre style="margin:0 0 12px;padding:12px;background:#f6f3ec;white-space:pre-wrap;word-break:break-word;' \
          "font:13px/1.45 Menlo,Consolas,monospace\">#{escape_html(alert.message)}</pre>",
        ]
        parts << "<p style=\"margin:0 0 12px\"><em>Triage:</em> #{escape_html(alert.triage)}</p>" if Provider.present?(alert.triage)
        parts << "<p style=\"margin:0\"><a href=\"#{escape_html(link)}\">Open #{escape_html(alert.job)}</a></p>" if link
        parts << "</body></html>"
        parts.join("\n")
      end

      # Splits "Name <a@b.c>" into its parts, as JSON-ready hashes; a bare address has no name.
      def parse_address(address)
        match = ADDRESS.match(address)
        return { "email" => JS.trim(address) } unless match

        name = match[1].sub(QUOTED, '\1')
        name.empty? ? { "email" => JS.trim(match[2]) } : { "email" => JS.trim(match[2]), "name" => name }
      end
    end
  end
end
