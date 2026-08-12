# frozen_string_literal: true

require "time"
require_relative "../../lib/sidecar/dashboard"

RSpec.describe Sidecar::Dashboard do
  let(:liveness) do
    instance_double(Sidecar::Liveness, headline: "✓ SIDECAR FRESH — last pass 2s ago", version_skew: nil)
  end

  def sensor(id, **overrides)
    { "id" => id.to_s, "name" => id.to_s, "group" => "lint", "tier" => "fast",
      "state" => "green", "stale" => false, "duration_ms" => 120 }.merge(overrides)
  end

  def status(sensors, **overrides)
    { "changed_files" => %w[app/x.rb], "base" => "HEAD", "mode" => "WATCH",
      "sensors" => sensors }.merge(overrides)
  end

  def render(sensors, **overrides)
    described_class.new(status: status(sensors, **overrides), liveness:).render
  end

  # Where the digest is red-only and token-capped, this shows the whole board. A
  # person watching wants to know that twelve things are being checked and eleven
  # are fine — exactly what the digest spends its budget leaving out.
  describe "the board" do
    it "shows green sensors, which the digest omits" do
      expect(render([ sensor(:rubocop) ])).to include("rubocop")
    end

    it "summarises the counts by state" do
      expect(render([ sensor(:a), sensor(:b, "state" => "red") ])).to include("1 green").and include("1 red")
    end

    it "says plainly when no pass has landed yet" do
      expect(described_class.new(status: nil, liveness:).render).to include("no pass yet")
    end
  end

  # Most urgent first, matching the digest's reading order so the two do not
  # disagree about what matters. Deliberately not the registry's run order, which
  # puts setup first for a different reason.
  describe "grouping" do
    it "orders test above security above lint" do
      output = render([ sensor(:c, "group" => "lint"),
                        sensor(:a, "group" => "test"),
                        sensor(:b, "group" => "security") ])

      expect(output.index("test")).to be < output.index("security")
      expect(output.index("security")).to be < output.index("lint")
    end

    it "puts a group it does not recognise last rather than dropping it" do
      output = render([ sensor(:known, "group" => "test"), sensor(:odd, "group" => "chores") ])

      expect(output).to include("odd")
      expect(output.index("chores")).to be > output.index("test")
    end
  end

  describe "the icons" do
    # A green that no longer describes the tree is the row on this board most
    # likely to mislead someone, so staleness outranks the verdict.
    it "marks a stale sensor as stale even when its verdict was green" do
      expect(render([ sensor(:full, "stale" => true) ])).to include("⚠")
    end

    # A resource this location lacks and a tool nobody installed look identical
    # on a board that conflates them, and they have different fixes.
    it "distinguishes unavailable from deferred" do
      output = render([ sensor(:a, "state" => "deferred"), sensor(:b, "state" => "unavailable") ])

      expect(output).to include("⏸").and include("○")
    end

    it "falls back to a question mark rather than rendering nothing" do
      expect(render([ sensor(:odd, "state" => "invented") ])).to include("?")
    end
  end

  describe "the detail column" do
    it "shows a red sensor's summary, which is what the reader needs" do
      expect(render([ sensor(:a, "state" => "red", "summary" => "3 new") ])).to include("3 new")
    end

    it "shows a green sensor's duration, the only thing worth the space" do
      expect(render([ sensor(:a) ])).to include("120ms")
    end

    it "explains a stale sensor with no summary" do
      expect(render([ sensor(:a, "stale" => true, "summary" => nil) ]))
        .to include("the tree moved while it ran")
    end
  end

  describe "the footer" do
    it "reports the change set and mode" do
      expect(render([ sensor(:a) ])).to include("1 file(s) changed vs HEAD · WATCH")
    end

    # The only lever keeping the cheap-pass tenet honest across consumers core
    # will never see: a config that boots Rails shows up as the number it is.
    it "surfaces a slow config load" do
      expect(render([ sensor(:a) ], "config" => { "load_ms" => 900 })).to include("config 900ms")
    end

    it "stays quiet about a config load that is not worth mentioning" do
      expect(render([ sensor(:a) ], "config" => { "load_ms" => 2 })).not_to include("config")
    end
  end

  # A stale image is one rebuild away, so this is a warning rather than a refusal.
  describe "version skew" do
    it "shows the warning when the two sides disagree" do
      allow(liveness).to receive(:version_skew).and_return("core 0.0.1 wrote this")

      expect(render([ sensor(:a) ])).to include("core 0.0.1 wrote this")
    end
  end
end
