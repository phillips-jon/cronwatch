# frozen_string_literal: true

module Cronwatch
  # @api private
  module Format
    NAMED = /\A[A-Za-z_$][A-Za-z0-9_$]*: /

    module_function

    def at_time(at, now)
      return "never" if at.nil?

      iso = Duration.iso_time(at)
      return Duration.beyond_dates(at) if iso.nil?

      "#{iso.tr("T", " ")[0, 19]} UTC (#{Duration.relative(at, now)})"
    end

    def first_lines(text, n)
      return "" if text.nil? || text.empty?

      text.split("\n", -1).first(n).join("\n")
    end

    def tail(text, n)
      return "" if text.nil? || text.empty?

      lines = JS.trim_end(text).split("\n", -1)
      lines.last(n).join("\n")
    end

    # Words joined as an English list, with a serial comma from three on:
    # "a", "a and b", "a, b, and c". Every port joins the same way.
    def and_list(words, conjunction = "and")
      return words.join(" #{conjunction} ") if words.length <= 2

      "#{words[0...-1].join(", ")}, #{conjunction} #{words[-1]}"
    end

    # "Error: x" for a bare message, but not "Error: TypeError: x" for one that already names itself.
    def error_line(error)
      text = first_lines(error, 4)
      NAMED.match?(text) ? text : "Error: #{text}"
    end

    # Turns a draft into the title and message every channel shows.
    def compose_alert(draft, definition, now)
      name = definition.name
      run = draft.run
      details = draft.details
      lines = []

      title =
        case draft.type
        when :missed
          lines << "Due #{at_time(details[:due_at], now)}, and no run had started by #{at_time(details[:deadline], now)} (grace #{Duration.format(details[:grace_ms])})."
          lines << "Schedule: #{definition.schedule.nil? ? "undefined" : definition.schedule}#{definition.timezone.to_s.empty? ? "" : " (#{definition.timezone})"}."
          lines << "Last run: #{run ? "#{run.status} #{at_time(run.started_at, now)}" : "never"}."
          "#{name} missed its scheduled run"
        when :failed
          n = details[:consecutive_failures]
          lines << "#{n} consecutive failures." if n > 1
          if run
            lines << "Started #{at_time(run.started_at, now)}#{run.duration_ms.nil? ? "" : ", ran #{Duration.format(run.duration_ms)}"}."
            lines << error_line(run.error) if run.error && !run.error.empty?
            out = tail(run.output, 8)
            lines << "Output (tail):\n#{out}" unless out.empty?
          end
          "#{name} failed"
        when :stuck
          if run
            lines << "Started #{at_time(run.started_at, now)} and never reported finishing. Marked as timed out after #{Duration.format(run.duration_ms.nil? ? now - run.started_at : run.duration_ms)}."
            out = tail(run.output, 8)
            lines << "Output so far (tail):\n#{out}" unless out.empty?
          end
          lines << "If the process was killed mid-run (a serverless timeout, a deploy), this is what that looks like."
          "#{name} is stuck"
        when :slow
          lines << "Took #{Duration.format(details[:duration_ms])}; the limit is #{Duration.format(details[:threshold_ms])} (#{details[:basis]})."
          lines << "Started #{at_time(run.started_at, now)}." if run
          "#{name} was slow"
        when :over_budget
          details[:breaches].each do |b|
            lines << "#{b[:metric]}: #{Evaluate.format_number(b[:value])}, limit #{Evaluate.format_number(b[:limit])} (#{b[:basis]})."
          end
          lines << "Started #{at_time(run.started_at, now)}." if run
          "#{name} went over budget"
        when :under_floor
          details[:breaches].each do |b|
            value = Evaluate.format_number(b[:value])
            lines << if b[:basis] == "floor"
                       "#{b[:metric]}: #{value}, below the floor of #{Evaluate.format_number(b[:limit])}."
                     else
                       "#{b[:metric]}: #{value} (#{b[:basis]})."
                     end
          end
          lines << "Started #{at_time(run.started_at, now)}." if run
          "#{name} fell short"
        when :recovered
          if details[:reason]&.to_sym == :unscheduled
            since = details[:since]
            lines << "#{since.nil? ? "" : "Missed since #{at_time(since, now)}. "}It has no schedule now, so nothing is due; the missed alert is closed."
            "#{name} is no longer scheduled"
          else
            after = and_list(details[:after].map { |c| c.to_s.sub("_", " ") })
            lines << "A run #{run ? at_time(run.started_at, now) : "just now"} succeeded#{after.empty? ? "" : " after: #{after}"}."
            lines << "Ran #{Duration.format(run.duration_ms)}." if run && !run.duration_ms.nil?
            "#{name} recovered"
          end
        else
          raise ArgumentError, "unknown alert type #{draft.type.inspect}"
        end

      Alert.new(type: draft.type, run: run, details: details, job: name, definition: definition, title: title,
                message: lines.join("\n"), at: now)
    end
  end
end
