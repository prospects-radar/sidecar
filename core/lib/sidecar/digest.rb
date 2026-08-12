# frozen_string_literal: true

module Sidecar
  # Renders the agent-facing digest: what is red, on lines you touched, in the
  # order worth reading, inside a token budget.
  #
  # The budget is the whole point. An agent that pastes raw tool output into its
  # own context pays for every green check and every piece of untouched debt;
  # this pays only for what changed and needs a decision. Nothing is ever dropped
  # silently — anything that will not fit is counted in a "+N more".
  class Digest
    # ~600 tokens is roughly 30 lines, the ceiling the design settled on.
    TOKEN_CAP = 600
    CHARS_PER_TOKEN = 4

    # Reading order: a failing test beats a security finding beats a lint offence
    # beats a build step. A sensor that could not run at all sorts above
    # everything, because a broken sensor invalidates its own green.
    #
    # Ties inside a group fall back to registry order, which the project
    # controls. The original carried a hardcoded `STYLE_SENSORS = %i[prettier
    # stylelint]` to sort formatting below other lint — three project sensor ids
    # compiled into what is meant to be a generic core. A project wanting
    # formatting last says so by registering it last.
    ERROR_RANK = 0
    GROUP_SEVERITY = { test: 1, security: 2, lint: 3, build: 4, setup: 5 }.freeze
    UNRANKED = 9

    # Room kept back so a truncated sensor can always afford its "+N more" line.
    # Without it the cap could cut a list and say nothing.
    OVERFLOW_RESERVE_TOKENS = 8

    def initialize(results:, change_set:, generated_at: Time.now, mode: "ONCE")
      @results = results
      @change_set = change_set
      @generated_at = generated_at
      @mode = mode
    end

    def to_s
      body, unshown = render_blocks
      ([ *header, "", *body ].compact + [ "", footer(unshown) ].compact).join("\n").strip + "\n"
    end

    private

    attr_reader :results, :change_set, :generated_at, :mode

    def actionable = results.select(&:actionable?)
    def green = results.select(&:green?)
    def deferred = results.select(&:deferred?)
    def unavailable = results.select(&:unavailable?)

    def preexisting_count = results.sum { |result| result.preexisting.size }

    def header
      count = actionable.size
      headline = count.zero? ? "all green" : "#{count} red"
      [
        "# Sidecar — #{headline}   (fast: ran #{generated_at.strftime('%H:%M:%S')})",
        "status: #{mode} · base #{change_set.base} · #{change_set.files.size} file(s) changed"
      ]
    end

    def ordered
      actionable.each_with_index
                .sort_by { |result, index| [ severity(result), index ] }
                .map(&:first)
    end

    def severity(result)
      return ERROR_RANK if result.error?

      GROUP_SEVERITY.fetch(result.group, UNRANKED)
    end

    # Fills the budget in severity order. A sensor that cannot fit its heading is
    # counted rather than rendered, and the count reaches the reader.
    def render_blocks
      remaining = TOKEN_CAP - estimate(header) - estimate([ footer_template ])
      lines = []
      unshown = 0

      ordered.each do |result|
        heading = heading_for(result)
        if estimate([ heading ]) > remaining
          unshown += 1
          next
        end

        remaining -= estimate([ heading ])
        block, remaining = fill_items(result, remaining)
        lines.concat([ "", heading, *block ])
      end

      [ lines.drop(1), unshown ]
    end

    def fill_items(result, remaining)
      items = item_lines(result)
      taken = []

      items.each_with_index do |line, index|
        reserve = index < items.size - 1 ? OVERFLOW_RESERVE_TOKENS : 0
        break if estimate([ line ]) + reserve > remaining

        remaining -= estimate([ line ])
        taken << line
      end

      if taken.size < items.size
        overflow = "  +#{items.size - taken.size} more"
        taken << overflow
        remaining -= estimate([ overflow ])
      end

      [ taken, remaining ]
    end

    def heading_for(result)
      icon = result.error? ? "⚠" : "🔴"
      "## #{icon} #{result.id} (#{result.group}) — #{label_for(result)}"
    end

    def label_for(result)
      return "#{result.new_violations.size} new" if result.new_violations.any?
      return "sensor failed" if result.error?

      "failed"
    end

    # Guidance rides under the first item only. It comes from the registry, so it
    # is the same hint for every violation the sensor reports — repeating it per
    # line would buy nothing and cost tokens. A sensor with no line-level handler
    # gets it too: a pass/fail result is exactly where a hint about what to run
    # next earns its keep.
    def item_lines(result)
      lines = if result.new_violations.empty?
        [ "- #{result.summary}" ]
      else
        result.new_violations
              .sort_by { |violation| [ violation.file.to_s, violation.line.to_i ] }
              .map { |violation| violation_line(result, violation) }
      end
      lines.insert(1, "  ↳ #{result.guidance}") if result.guidance
      lines
    end

    # The rule name is enough to act on for a lint or boundary sensor. A failing
    # test is not — its message carries the assertion, so it stays.
    def violation_line(result, violation)
      line = "- #{violation.file}:#{violation.line} — #{violation.rule}"
      result.group == :test && violation.message ? "#{line}: #{violation.message}" : line
    end

    def footer_template = "—— #{'x' * 60} ——"

    def footer(unshown)
      parts = []
      parts << "#{unshown} more sensor(s) not shown (token cap)" if unshown.positive?
      parts << "#{preexisting_count} pre-existing on untouched lines hidden" if preexisting_count.positive?
      parts << "#{green.size} green" if green.any?
      # Counted, never hidden: a check that did not run must not read like one
      # that passed. Why each was deferred is in status.json.
      parts << "#{deferred.size} deferred" if deferred.any?
      # Separate from deferred, because the fix is different: deferred means run
      # it somewhere else, unavailable means install the tool.
      parts << "#{unavailable.size} unavailable" if unavailable.any?
      return nil if parts.empty?

      "—— #{parts.join(' · ')} ——"
    end

    def estimate(lines)
      (lines.compact.sum { |line| line.length + 1 }.to_f / CHARS_PER_TOKEN).ceil
    end
  end
end
