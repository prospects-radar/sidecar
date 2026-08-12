# frozen_string_literal: true

require_relative "sensor"

module Sidecar
  # The assembled set of sensors a project runs: what its packs ship, what it
  # changed about them, what it removed, and what it added of its own.
  #
  # An object a project builds and hands to the runner, not a global. A global
  # registry is load-order dependent, leaks between examples in a gem's own
  # suite, and needs a reset hook that exists for no other reason. The one in the
  # commissioning project grew exactly that hook and nothing ever called it.
  class Registry
    UnknownSensor = Class.new(ArgumentError)
    DuplicateSensor = Class.new(ArgumentError)

    # Run order. Derived from `group` so that a project appending to a shipped
    # pack lands in the right place without being able to see the pack's array,
    # which is what the hand-maintained "keep grouped entries adjacent" comment
    # was standing in for.
    #
    # `:setup` leading is load-bearing rather than incidental: a database that is
    # not prepared fails every test sensor behind it, so it runs first. Lint
    # before test is the cheap check first. Registration position breaks ties
    # inside a group.
    GROUP_ORDER = %i[setup lint test security build].freeze

    def initialize
      @entries = []
      @applied_packs = []
    end

    # Add a sensor. Raises on a duplicate id, because two entries answering to
    # one name means every lookup silently picks one of them.
    def sensor(id, **attrs)
      built = Sensor.build(id, **attrs)
      raise DuplicateSensor, "duplicate sensor id #{id.inspect}" if self[id]

      @entries << built
      built
    end

    # Apply a pack: the part every member of a class of codebase would otherwise
    # write identically.
    #
    # The primary form is **data** — a Hash carrying `sensors:` — rather than an
    # object with an #apply method. That is what lets a shipped pack be checked
    # mechanically for defining no methods and shelling out nowhere: a pack that
    # can run code is a pack that can do anything, and the rule that keeps the
    # Rails companion honest is only enforceable if there is nothing to run.
    #
    # An object responding to #apply is still accepted, for a project assembling
    # its own sensors programmatically. That is the project's own risk to take;
    # the gem does not take it.
    def use(pack)
      if pack.respond_to?(:apply)
        pack.apply(self)
      else
        Array(pack.fetch(:sensors, [])).each do |entry|
          attrs = entry.dup
          sensor(attrs.delete(:id), **attrs)
        end
      end
      @applied_packs << pack
      self
    end

    # What a pack suggests for settings a project has not stated. Never applied
    # silently: a pack cannot see the machine, so `provides` is deliberately not
    # among these — a pack asserting node would hand half its consumers a failing
    # sensor where the honest answer is unavailable.
    def self.defaults_in(pack) = pack.respond_to?(:fetch) ? pack.fetch(:defaults, {}) : {}

    # Replace named attributes on an existing sensor, keeping the rest and
    # keeping its position.
    #
    # Raises when the id is absent, where #omit tolerates the same. The asymmetry
    # is deliberate: overriding a sensor that is not there means the change
    # silently did not apply *and the sensor is still running with pack
    # defaults*, which is actively wrong. Omitting one the pack has since removed
    # means the thing you wanted gone is gone, so the statement is redundant
    # rather than wrong, and raising would break a dev's loop for no safety.
    def override(id, **attrs)
      index = @entries.index { |entry| entry.id == id }
      raise UnknownSensor, "cannot override unknown sensor #{id.inspect}; known: #{ids.inspect}" if index.nil?

      current = @entries[index]
      @entries[index] = Sensor.build(id, **current.to_h.except(:id).merge(attrs))
    end

    # Remove a sensor. Tolerates an id that is not there — see #override.
    #
    # Removal rather than an `enabled: false` field: a disabled entry still sits
    # in the list, and every consumer that iterates has to remember to filter it.
    # Whichever one forgets is a silent bug, and removal leaves no shadow state.
    def omit(id)
      @entries.reject! { |entry| entry.id == id }
      self
    end

    def [](id) = @entries.find { |entry| entry.id == id }

    # Run order, like #all. Registration order is an implementation detail of how
    # ties get broken and is never handed out: one object exposing two different
    # orders is a bug waiting for whoever reaches for the wrong one.
    def ids = all.map(&:id)

    def empty? = @entries.empty?
    def size = @entries.size

    # Every sensor, in run order: group first, registration position breaking
    # ties inside a group.
    #
    # The index has to be paired up front rather than taken from sort_by's
    # enumerator — that index counts comparisons, not positions, so it sorts by
    # nothing in particular while looking like it works.
    def all
      @entries.each_with_index
              .sort_by { |entry, position| [ GROUP_ORDER.index(entry.group) || GROUP_ORDER.size, position ] }
              .map(&:first)
    end

    def ci_steps = all.select(&:ci)
    def sidecar_sensors = all.select(&:sidecar)
    def gate_sensors = all.select(&:gate)
    def fast = sidecar_sensors.select { |entry| entry.tier == :fast }
    def slow = sidecar_sensors.select { |entry| entry.tier == :slow }

    # Every resource any sensor declares. What validates these is the project's
    # provides-map, not this class: a registry cannot know what a machine has.
    def declared_needs = @entries.flat_map(&:needs).uniq

    def to_a = all

    def freeze
      @entries.freeze
      @applied_packs.freeze
      super
    end
  end
end
