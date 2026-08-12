# frozen_string_literal: true

module Sidecar
  # One thing a tool found, at a place in a file.
  Violation = Data.define(:file, :line, :rule, :message) do
    def to_h = { file:, line:, rule:, message: }
  end

  # How many files a sensor was handed, and how many it actually ran against.
  #
  # On the published contract for every sensor, not just the one that needs it.
  # The counts are not handler-specific — every sensor is handed a set of files —
  # and a handler wanting to say something structural about its run is reporting
  # that the result shape is missing something, which is a core change rather
  # than a private extension.
  #
  # For every shipped handler but one the two are equal. `targeted_specs` is
  # unusual only in that its rewrite can name paths that are not on disk.
  Targets = Data.define(:considered, :run) do
    def initialize(considered: 0, run: nil) = super(considered:, run: run || considered)
    def to_h = { considered:, run: }
    def empty? = run.zero?
  end

  # What a handler hands back. Three shapes, because there are three genuinely
  # different things a tool run can tell you.
  module HandlerResult
    # The tool reported findings at specific lines, so core can narrow them to
    # the change. Core partitions these; the handler does not.
    Findings = Data.define(:offenses, :targets) do
      def initialize(offenses:, targets: Targets.new) = super
    end

    # The tool passed or failed as a whole. Honest rather than lossy: reporting
    # a whole-file failure beats inventing line numbers.
    Outcome = Data.define(:ok, :summary, :targets) do
      def initialize(ok:, summary: nil, targets: Targets.new) = super
      def ok? = ok
    end

    # The tool ran and produced something core could not read. A distinct shape
    # from a failure, because "the linter crashed" and "the linter found a bug"
    # call for different responses, and pooling them means a broken tool reads as
    # a clean run or a real one. What happens next is the sensor's declared
    # `unreadable:` policy, not a rescue buried here.
    Unreadable = Data.define(:tool, :detail, :targets) do
      def initialize(tool:, detail: nil, targets: Targets.new) = super
    end
  end

  # What one sensor found in one pass.
  #
  #   :green     ran clean
  #   :red       ran and found something on a line you touched
  #   :deferred  a resource this location lacks, so it did not run here
  #   :unavailable  the tool itself is not installed
  #   :error     the tool ran and core could not read what it said
  SensorResult = Data.define(
    :id, :name, :group, :tier, :state, :new_violations, :preexisting,
    :summary, :duration_ms, :guidance, :stale, :targets
  ) do
    # Staleness is orthogonal to the verdict. A slow sensor that took four
    # minutes can come back green about a tree that has since moved on; the
    # verdict is still green, it is just no longer about the code in front of
    # you. Folding that into `state` would lose one fact to record the other.
    def initialize(stale: false, new_violations: [], preexisting: [], summary: nil,
                   duration_ms: nil, guidance: nil, targets: Targets.new, **rest)
      super
    end

    def red? = state == :red
    def green? = state == :green
    def deferred? = state == :deferred
    def unavailable? = state == :unavailable
    def error? = state == :error
    def stale? = stale

    # What someone is expected to do something about. A deferred or unavailable
    # sensor is a fact about the machine, not about the change.
    def actionable? = red? || error?

    def to_h
      { id:, name:, group:, tier:, state:, stale:,
        new: new_violations.map(&:to_h), preexisting: preexisting.map(&:to_h),
        summary:, duration_ms:, guidance:, targets: targets.to_h }
    end
  end
end
