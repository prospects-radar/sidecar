# frozen_string_literal: true

require "json"
require "shellwords"

require_relative "result"

module Sidecar
  # A handler invokes a tool and turns what it said into one of the three result
  # shapes. Open and supported: a project names its own handler object in a
  # sensor entry, and core is not the bottleneck for every tool the four shipped
  # handlers cannot read.
  #
  # A handler receives a runner from core, and that runner is the only thing it
  # is handed that can execute anything. Cancellation lives in the runner — the
  # fast tier dies the moment you type — so a handler reaching for Open3 directly
  # gets a sensor that cannot be stopped mid-run, which keeps burning CPU on a
  # tree that already moved. No static check catches that, since handlers may
  # live in projects this gem never sees. Giving the handler no other tool is the
  # whole enforcement.
  module Handlers
    include HandlerResult

    # Shared plumbing. Subclassing is optional: anything responding to #call with
    # the keyword signature below is a handler.
    class Base
      include HandlerResult

      # @param sensor  [Sensor]        the declaration being run
      # @param targets [Array<String>] repo-relative paths, already scoped
      # @param runner  [#call]         the only thing here that can execute
      def call(sensor:, targets:, runner:)
        raise NotImplementedError, "#{self.class} must implement #call"
      end

      private

      def expand(command, files)
        command.include?("{files}") ? command.sub("{files}", files.shelljoin) : command
      end

      def parse_json(output)
        return nil if output.to_s.strip.empty?

        JSON.parse(output)
      rescue JSON::ParserError
        nil
      end
    end

    # Runs the sensor's own command and reports whether it passed.
    #
    # The default when a sensor names no handler. Honest rather than lossy: a
    # tool core cannot read down to the line still tells you it failed.
    class PassFail < Base
      def call(sensor:, targets:, runner:)
        out, err, status = runner.call(expand(sensor.command, targets))
        Outcome.new(ok: status.success?,
                    summary: (Summary.of(out, err) unless status.success?),
                    targets: Targets.new(considered: targets.size))
      end
    end

    # RuboCop, read down to the line.
    #
    # Parameterised by command rather than subclassed per cop set, which is what
    # lets a project run a forced `--only` list — its design-system gate, say —
    # with zero handler code of its own. The registry command is the one a human
    # types; this is the JSON form whose output can be narrowed to a line.
    class Rubocop < Base
      DEFAULT_COMMAND = "bundle exec rubocop --format json --force-exclusion"

      attr_reader :command

      def initialize(command: DEFAULT_COMMAND)
        super()
        @command = command
      end

      def call(sensor:, targets:, runner:)
        ruby = targets.select { |file| file.end_with?(".rb") }
        counts = Targets.new(considered: targets.size, run: ruby.size)
        return Findings.new(offenses: [], targets: counts) if ruby.empty?

        out, = runner.call("#{command} #{ruby.shelljoin}")
        data = parse_json(out)
        return Unreadable.new(tool: "rubocop", detail: "no parseable JSON", targets: counts) if data.nil?

        Findings.new(offenses: offenses_in(data), targets: counts)
      end

      private

      def offenses_in(data)
        data.fetch("files", []).flat_map do |file|
          file.fetch("offenses", []).map do |offense|
            { file: file["path"],
              line: offense.dig("location", "line") || offense.dig("location", "start_line"),
              rule: offense["cop_name"],
              message: offense["message"] }
          end
        end
      end
    end

    # stylelint, the CSS half of a changed-line gate.
    #
    # A sensor in its own right rather than a branch of the Ruby one because it
    # is the half that needs node: split, a location without node defers the CSS
    # check and still runs the Ruby cops; fused, one missing resource takes both
    # down.
    class Stylelint < Base
      DEFAULT_COMMAND = "npx --no-install stylelint --formatter json"

      attr_reader :command

      def initialize(command: DEFAULT_COMMAND)
        super()
        @command = command
      end

      def call(sensor:, targets:, runner:)
        css = targets.select { |file| file.end_with?(".css") }
        counts = Targets.new(considered: targets.size, run: css.size)
        return Findings.new(offenses: [], targets: counts) if css.empty?

        out, = runner.call("#{command} #{css.shelljoin}")
        data = parse_json(out)
        return Unreadable.new(tool: "stylelint", detail: "no parseable JSON", targets: counts) if data.nil?

        Findings.new(offenses: offenses_in(data), targets: counts)
      end

      private

      # stylelint reports absolute paths where the gate speaks repo-relative, and
      # the gate matches on the string. Normalising here rather than in the gate
      # is deliberate: only a handler knows its tool's path convention, so the
      # gate can require repo-relative paths as a precondition instead of
      # defensively re-normalising everything it is given.
      def offenses_in(data)
        data.flat_map do |result|
          path = relativize(result["source"].to_s)
          result.fetch("warnings", []).map do |warning|
            { file: path, line: warning["line"], rule: warning["rule"], message: warning["text"] }
          end
        end
      end

      def relativize(path)
        prefix = "#{Dir.pwd}/"
        path.start_with?(prefix) ? path[prefix.length..] : path
      end
    end

    # The spec a changed file owes, run on the change rather than on the suite.
    #
    # Rewrites its input before running, which is why it is the one handler whose
    # considered and run counts differ: a rule can name a path that is not on
    # disk, and that is how a broken mapping actually presents.
    #
    # The rules are handed in rather than baked in. A codebase does not have one
    # source-to-test relationship, so this is one sensor's answer rather than the
    # project's, and it composes with the registry's override for free.
    class TargetedSpecs < Base
      attr_reader :rules

      # @param rules [Hash{Regexp => Array<String>}] full-path patterns to
      #   replacement lists, first match wins. The replacement is always a list,
      #   because the relationship genuinely is one-to-many: a model plausibly
      #   owes both a model spec and a request spec.
      def initialize(rules:)
        super()
        @rules = rules
      end

      def call(sensor:, targets:, runner:)
        mapped = targets.flat_map { |file| specs_for(file) }.uniq
        present = mapped.select { |spec| File.file?(spec) }
        counts = Targets.new(considered: targets.size, run: present.size)

        # Nothing failed — something is missing, and the two read differently to
        # whoever is deciding what to do next.
        return Outcome.new(ok: true, summary: summary_for_empty(mapped), targets: counts) if present.empty?

        out, err, status = runner.call(expand(sensor.command, present))
        Outcome.new(ok: status.success?,
                    summary: status.success? ? "#{present.size} spec file(s) passed" : Summary.of(out, err),
                    targets: counts)
      end

      private

      # First match wins, which is load-bearing. If every matching rule fired,
      # `app/lib/foo.rb` would match both the app/ and lib/ rules, producing one
      # correct target alongside a nonsense `app/spec/lib/foo_spec.rb`.
      def specs_for(file)
        pattern, replacements = rules.find { |candidate, _| file.match?(candidate) }
        return [] unless pattern

        replacements.map { |replacement| file.sub(pattern, replacement) }
      end

      def summary_for_empty(mapped)
        return "no rule maps the changed files to a spec" if mapped.empty?

        "mapped to #{mapped.size} spec path(s), none on disk: #{mapped.take(3).join(', ')}"
      end
    end

    # Enough to see what broke without pasting a whole tool run into an agent's
    # context.
    #
    # stdout wins over stderr rather than the two being pooled. Tools report
    # findings on stdout and grumble on stderr, and merging lets the grumbling
    # win: Brakeman in a container emits seven harmless git warnings, which
    # buried the actual security finding when both streams were merged. This is a
    # bug fix rather than a style choice, and it belongs to core's result
    # building rather than to any one handler.
    module Summary
      module_function

      def of(out, err, _status = nil)
        lines = meaningful(out)
        return lines.last(2).join(" · ") if lines.any?

        lines = meaningful(err)
        return lines.last(2).join(" · ") if lines.any?

        "failed with no output"
      end

      def meaningful(stream) = stream.to_s.lines.map(&:strip).reject(&:empty?)
    end
  end
end
