# frozen_string_literal: true

module Sidecar
  # One quality check a project runs, declared once and read by everything that
  # runs checks, so local CI and the sidecar loop can never disagree about what
  # "the checks" are.
  #
  # A sensor is a declaration rather than an implementation: what to invoke,
  # which files it cares about, how often it deserves to run, what it cannot run
  # without, and what to tell someone whose change it rejects. The tool behind it
  # is always something that already exists.
  #
  # Fields:
  #   id         Symbol, unique within a registry
  #   name       String shown in CI and on the board
  #   command    String. A "{files}" placeholder means the handler substitutes
  #              the target set; absent means whole-repo.
  #   ci         appears as a step in the project's CI run
  #   sidecar    the always-on loop runs it (false = a build or setup step)
  #   gate       the changed-line gate runs it at merge
  #   tier       :fast (every tick, diff-scoped) | :slow (opportunistic)
  #   kind       :computational (deterministic) | :inferential (LLM)
  #   group      one of GROUPS. Steers run order, dashboard clustering and
  #              digest severity, which is why the vocabulary is closed.
  #   scope      Array<String> globs. Empty means whole-repo, so it always runs.
  #   interval   Integer seconds for slow-tier cadence (nil = not interval-driven)
  #   handler    the object that invokes the tool and reads its output. nil means
  #              raw pass/fail on the exit code. Holds the handler itself rather
  #              than a symbol naming one, so naming a handler that does not
  #              exist is impossible rather than merely caught.
  #   diff_base  Symbol/String git ref for --since scoping
  #   guidance   one line telling someone whose change it rejected what to do
  #   needs      Array<Symbol> resources it cannot run without. Open vocabulary:
  #              what a codebase needs is a property of that codebase. Validated
  #              at config load against what the project's locations provide.
  #   unreadable :advisory (output core cannot parse is reported, not failed) or
  #              :red. Declared per sensor rather than rescued in one place, so a
  #              gate is never silently hardened by a refactor.
  Sensor = Data.define(
    :id, :name, :command, :ci, :sidecar, :gate,
    :tier, :kind, :group, :scope, :interval, :handler,
    :diff_base, :guidance, :needs, :unreadable
  )

  class Sensor
    InvalidSensor = Class.new(ArgumentError)

    TIERS = %i[fast slow].freeze
    KINDS = %i[computational inferential].freeze
    UNREADABLE_POLICIES = %i[advisory red].freeze

    # Closed on purpose, where `needs` is open. `group` describes what kind of
    # check this is — a small vocabulary core itself reasons about to rank
    # severity, cluster the board and sequence a run. A sixth group is one core
    # would not know where to put, and since group now steers sequencing, an
    # unrecognised one would not merely sort oddly, it would run last. Closing is
    # also the reversible direction: loosening later is easy, tightening once
    # projects depend on custom groups is not.
    GROUPS = %i[setup lint test security build].freeze

    class << self
      def build(id, name:, command:, tier:, kind:, group:,
                sidecar: true, ci: true, gate: false, scope: [], interval: nil,
                handler: nil, diff_base: :auto, guidance: nil, needs: [],
                unreadable: :advisory)
        validate!(id:, name:, command:, tier:, kind:, group:, ci:, sidecar:, gate:,
                  scope:, needs:, handler:, unreadable:)
        new(id:, name:, command:, ci:, sidecar:, gate:, tier:, kind:, group:,
            scope:, interval:, handler:, diff_base:, guidance:, needs:, unreadable:)
      end

      private

      def validate!(id:, name:, command:, tier:, kind:, group:, ci:, sidecar:, gate:,
                    scope:, needs:, handler:, unreadable:)
        raise InvalidSensor, "id must be a Symbol, got #{id.inspect}" unless id.is_a?(Symbol)

        validate_strings!(id:, name:, command:)
        validate_enums!(id:, tier:, kind:, group:, unreadable:)
        validate_flags!(id:, ci:, sidecar:, gate:)
        validate_collections!(id:, scope:, needs:)
        validate_handler!(id:, handler:)
      end

      def validate_strings!(id:, name:, command:)
        raise InvalidSensor, "#{id}: name must be a non-empty String" unless name.is_a?(String) && !name.empty?
        return if command.is_a?(String) && !command.empty?

        raise InvalidSensor, "#{id}: command must be a non-empty String"
      end

      def validate_enums!(id:, tier:, kind:, group:, unreadable:)
        raise InvalidSensor, "#{id}: tier must be one of #{TIERS}, got #{tier.inspect}" unless TIERS.include?(tier)
        raise InvalidSensor, "#{id}: kind must be one of #{KINDS}, got #{kind.inspect}" unless KINDS.include?(kind)

        unless GROUPS.include?(group)
          raise InvalidSensor, "#{id}: group must be one of #{GROUPS.inspect}, got #{group.inspect}"
        end
        return if UNREADABLE_POLICIES.include?(unreadable)

        raise InvalidSensor, "#{id}: unreadable must be one of #{UNREADABLE_POLICIES}, got #{unreadable.inspect}"
      end

      def validate_flags!(id:, ci:, sidecar:, gate:)
        { ci:, sidecar:, gate: }.each do |field, value|
          raise InvalidSensor, "#{id}: #{field} must be true or false" unless [ true, false ].include?(value)
        end
      end

      def validate_collections!(id:, scope:, needs:)
        raise InvalidSensor, "#{id}: scope must be an Array" unless scope.is_a?(Array)
        raise InvalidSensor, "#{id}: needs must be an Array" unless needs.is_a?(Array)
        return if needs.all?(Symbol)

        raise InvalidSensor, "#{id}: needs must all be Symbols, got #{needs.inspect}"
      end

      # No check that the handler is one core ships. The extension point is open
      # and supported: a project names its own handler object here.
      def validate_handler!(id:, handler:)
        return if handler.nil? || handler.respond_to?(:call)

        raise InvalidSensor, "#{id}: handler must respond to #call, got #{handler.inspect}"
      end
    end

    # True when the command wants the target set spliced in rather than running
    # against the whole repository.
    def file_scoped? = command.include?("{files}")

    # An empty scope is "no declared scope", which the scan reads as whole-repo.
    def whole_repo? = scope.empty?
  end
end
