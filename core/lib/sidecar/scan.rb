# frozen_string_literal: true

require "open3"

require_relative "change_set"
require_relative "handlers"
require_relative "result"

module Sidecar
  # Runs the sensors a change actually touched and reports what they found,
  # narrowed to the lines that changed.
  #
  # A sensor runs only when the change set intersects its declared scope, so a
  # CSS-only edit never pays for Brakeman. Sensors with no declared scope are
  # whole-repo and always run.
  class Scan
    # Shells out, and is the only thing a handler is given that can. Cancellation
    # lives here rather than in the handlers: the fast tier dies the moment you
    # type, and a handler reaching for Open3 directly would keep burning CPU on a
    # tree that already moved.
    class Runner
      def initialize(cancelled: -> { false })
        @cancelled = cancelled
      end

      def call(command)
        return [ "", "", Cancelled.new ] if @cancelled.call

        Open3.capture3(command)
      end

      def cancelled? = @cancelled.call

      # Stands in for Process::Status when a pass is abandoned mid-flight.
      class Cancelled
        def success? = false
      end
    end

    # @param tier selects which half of the registry this pass is for. The two
    #   are never mixed: the fast tier is cancelled the moment you type and the
    #   slow tier is not, so one pass could not honour both.
    def initialize(change_set:, sensors:, project:, location: :host, tier: :fast,
                   runner: nil, cancelled: -> { false })
      @change_set = change_set
      @sensors = sensors.select { |sensor| sensor.tier == tier }
      @project = project
      @location = location
      @cancelled = cancelled
      @runner = runner || Runner.new(cancelled:)
      @tools = {}
    end

    # Checks for cancellation between sensors as well as inside them. The watcher
    # kills the running child; this stops the pass from calmly starting the next
    # sensor on a tree that has already moved on.
    def run
      results = []

      @sensors.each do |sensor|
        break if @cancelled.call

        result = result_for(sensor)
        results << result if result
      end

      results
    end

    private

    attr_reader :change_set, :runner, :project, :location

    def result_for(sensor)
      targets = targets_for(sensor)
      return nil if targets.nil?

      missing = project.missing_for(sensor, at: location)
      return deferred(sensor, missing) if missing.any?
      return unavailable(sensor) unless tool_available?(sensor)

      timed(sensor) { interpret(sensor, invoke(sensor, targets)) }
    end

    # Anything without a handler is pass/fail on the registry command. Honest
    # rather than lossy: reporting a whole-file failure beats inventing lines.
    def invoke(sensor, targets)
      handler = sensor.handler || Handlers::PassFail.new
      handler.call(sensor:, targets:, runner:)
    end

    # Turns the three handler shapes into one result shape. This is where the
    # change-set narrowing happens, because a handler is not given the gate: what
    # counts as new is one question with one answer, and letting each handler
    # decide would be how two of them come to disagree.
    def interpret(sensor, outcome)
      case outcome
      when HandlerResult::Findings then from_findings(outcome)
      when HandlerResult::Outcome  then from_outcome(outcome)
      when HandlerResult::Unreadable then from_unreadable(sensor, outcome)
      else raise ArgumentError, "#{sensor.id}: handler returned #{outcome.class}, not a HandlerResult"
      end
    end

    def from_findings(findings)
      new_ones = change_set.select_new(findings.offenses)
      preexisting = findings.offenses - new_ones

      { state: new_ones.empty? ? :green : :red,
        new_violations: new_ones.map { |offense| Violation.new(**offense) },
        preexisting: preexisting.map { |offense| Violation.new(**offense) },
        summary: new_ones.empty? ? nil : "#{new_ones.size} new",
        targets: findings.targets }
    end

    def from_outcome(outcome)
      { state: outcome.ok? ? :green : :red, summary: outcome.summary, targets: outcome.targets }
    end

    # The declared policy, not a rescue. A gate is never silently hardened as a
    # side effect of a refactor, and a tool that crashed is visible in the output
    # rather than indistinguishable from a clean run.
    def from_unreadable(sensor, unreadable)
      advisory = sensor.unreadable == :advisory
      { state: advisory ? :green : :error,
        summary: "#{unreadable.tool} produced output core could not read" \
                 "#{" (#{unreadable.detail})" if unreadable.detail}" \
                 "#{' — advisory, so not counted against you' if advisory}",
        targets: unreadable.targets }
    end

    # The changed files this sensor cares about, or nil when it should not run at
    # all. An empty scope means whole-repo, which always runs but scopes to
    # nothing in particular.
    def targets_for(sensor)
      return [] if sensor.whole_repo?

      matched = change_set.matching(sensor.scope)
      matched.empty? ? nil : matched
    end

    # A pack ships sensors for a whole class of codebase without being able to
    # see whether any given member installed the tool. An absent binary belongs
    # on the board as unavailable, not as a red mark against a check nobody
    # declined to run.
    #
    # Probed once per pass and memoised rather than once per config load: the
    # Project is frozen, and a pass is a short enough window that a tool
    # appearing mid-pass is not worth modelling.
    def tool_available?(sensor)
      binary = sensor.command[/\A\s*(?:[A-Z_]+=\S+\s+)*(\S+)/, 1]
      return true if binary.nil?

      @tools.fetch(binary) { @tools[binary] = probe(binary) }
    end

    def probe(binary)
      # A path-ish invocation is checked on disk; a bare name is looked up the
      # way a shell would. Anything else (a shell builtin, a compound command)
      # is assumed present rather than guessed at.
      return File.executable?(binary) if binary.include?("/")

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
         .any? { |dir| File.executable?(File.join(dir, binary)) }
    end

    def timed(sensor)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      attrs = yield
      elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      build(sensor, duration_ms: elapsed, **attrs)
    end

    # A check that did not run must never read like a check that passed.
    def deferred(sensor, missing)
      here = project.location(location)
      wants = missing.map { |resource| here.describe(resource) }.join(" and ")

      build(sensor, state: :deferred, summary: "needs #{wants}, not available in #{location}")
    end

    def unavailable(sensor)
      build(sensor, state: :unavailable, summary: "#{sensor.command.split.first} is not installed here")
    end

    def build(sensor, state:, **rest)
      SensorResult.new(id: sensor.id, name: sensor.name, group: sensor.group,
                       tier: sensor.tier, state:, guidance: sensor.guidance, **rest)
    end
  end
end
