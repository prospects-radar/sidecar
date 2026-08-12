# frozen_string_literal: true

require "time"
require_relative "../../lib/sidecar/digest"
require_relative "../../lib/sidecar/result"
# Digest itself does not require the gate — it only reads two attributes off
# whatever it is handed. Required here for the verifying double, not by the
# subject.
require_relative "../../lib/sidecar/change_set"

RSpec.describe Sidecar::Digest do
  let(:change_set) { instance_double(Sidecar::ChangeSet, base: "HEAD", files: %w[app/x.rb]) }
  let(:generated_at) { Time.utc(2026, 8, 12, 9, 30, 0) }

  def violation(file: "app/x.rb", line: 3, rule: "Style/Foo", message: "no")
    Sidecar::Violation.new(file:, line:, rule:, message:)
  end

  def result(id, **overrides)
    Sidecar::SensorResult.new(**{ id:, name: id.to_s, group: :lint, tier: :fast,
                                  state: :green }.merge(overrides))
  end

  def render(results) = described_class.new(results:, change_set:, generated_at:).to_s

  describe "the header" do
    it "leads with all green when nothing is actionable" do
      expect(render([ result(:rubocop) ])).to include("all green")
    end

    it "leads with the count when something is" do
      expect(render([ result(:a, state: :red), result(:b, state: :red) ])).to include("2 red")
    end
  end

  # Reading order: a failing test beats a security finding beats a lint offence.
  # A sensor that could not run at all sorts above everything, because a broken
  # sensor invalidates its own green.
  describe "ordering" do
    it "puts a failing test above a lint offence" do
      output = render([ result(:rubocop, state: :red, group: :lint),
                        result(:specs, state: :red, group: :test) ])

      expect(output.index("specs")).to be < output.index("rubocop")
    end

    it "puts an unreadable sensor above everything" do
      output = render([ result(:specs, state: :red, group: :test),
                        result(:rubocop, state: :error, group: :lint) ])

      expect(output.index("rubocop")).to be < output.index("specs")
    end

    # The original sorted formatting sensors last via a hardcoded
    # %i[prettier stylelint] list — three project sensor ids compiled into a
    # generic core. Registration order replaces it, which a project controls.
    it "falls back to the order it was given inside a group" do
      output = render([ result(:first, state: :red), result(:second, state: :red) ])

      expect(output.index("first")).to be < output.index("second")
    end
  end

  describe "violations" do
    it "names the file, line and rule" do
      red = result(:rubocop, state: :red, new_violations: [ violation ])

      expect(render([ red ])).to include("app/x.rb:3 — Style/Foo")
    end

    # The rule name is enough to act on for a lint sensor. A failing test is not:
    # its message carries the assertion.
    it "keeps a test's message, where the assertion lives" do
      red = result(:specs, state: :red, group: :test, new_violations: [ violation(message: "expected 1") ])

      expect(render([ red ])).to include("expected 1")
    end

    it "drops a lint message, which the rule name already covers" do
      red = result(:rubocop, state: :red, new_violations: [ violation(message: "verbose prose") ])

      expect(render([ red ])).not_to include("verbose prose")
    end

    # Guidance rides under the first item only: it comes from the registry, so it
    # is the same hint for every violation and repeating it would cost tokens.
    it "shows guidance once, not per violation" do
      red = result(:rubocop, state: :red, guidance: "run -a",
                             new_violations: [ violation(line: 1), violation(line: 2) ])

      expect(render([ red ]).scan("run -a").size).to eq(1)
    end
  end

  # Nothing is ever dropped silently. Anything that will not fit is counted.
  describe "the token budget" do
    it "stays within the cap" do
      many = Array.new(80) { |i| violation(file: "app/file#{i}.rb", line: i) }
      red = result(:rubocop, state: :red, new_violations: many)

      estimated = (render([ red ]).length / described_class::CHARS_PER_TOKEN.to_f).ceil

      expect(estimated).to be <= described_class::TOKEN_CAP
    end

    it "counts what it could not show rather than truncating in silence" do
      many = Array.new(80) { |i| violation(file: "app/file#{i}.rb", line: i) }

      expect(render([ result(:rubocop, state: :red, new_violations: many) ])).to match(/\+\d+ more/)
    end

    it "counts whole sensors it had no room for" do
      results = Array.new(40) do |i|
        result(:"sensor#{i}", state: :red, new_violations: [ violation(file: "app/#{i}.rb") ])
      end

      expect(render(results)).to match(/more sensor\(s\) not shown/)
    end
  end

  describe "the footer" do
    it "counts pre-existing debt without listing it" do
      red = result(:rubocop, state: :green, preexisting: [ violation, violation ])

      expect(render([ red ])).to include("2 pre-existing on untouched lines hidden")
    end

    # A check that did not run must not read like one that passed.
    it "counts deferred sensors" do
      expect(render([ result(:cuke, state: :deferred) ])).to include("1 deferred")
    end

    # Separate from deferred, because the fix differs: deferred means run it
    # somewhere else, unavailable means install the tool.
    it "counts unavailable sensors apart from deferred" do
      output = render([ result(:cuke, state: :deferred), result(:brakeman, state: :unavailable) ])

      expect(output).to include("1 deferred").and include("1 unavailable")
    end

    it "says nothing when there is nothing to say" do
      expect(render([ result(:rubocop, state: :red, new_violations: [ violation ]) ])).not_to include("——")
    end
  end
end
