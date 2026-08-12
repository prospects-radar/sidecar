# frozen_string_literal: true

require "fileutils"
require_relative "../../lib/sidecar/handlers"
require_relative "../../lib/sidecar/sensor"

RSpec.describe Sidecar::Handlers do
  # Records what it was asked to run and replays canned output, so nothing here
  # starts a real RuboCop. A plain object rather than an RSpec double: handlers
  # are handed this by core, and the point of the design is that it is the only
  # thing they can execute anything with.
  # Stands in for Process::Status. Named at the top rather than inside the fake,
  # where the assignment would land on Object and warn on every reload.
  FakeStatus = Struct.new(:ok) { def success? = ok }

  class FakeRunner
    attr_reader :commands
    attr_accessor :responses

    def initialize
      @commands = []
      @responses = {}
    end

    def call(command)
      @commands << command
      out, ok = @responses.find { |pattern, _| command.include?(pattern) }&.last || [ "", true ]
      [ out, "", FakeStatus.new(ok) ]
    end
  end

  let(:runner) { FakeRunner.new }

  def sensor(**overrides)
    Sidecar::Sensor.build(:example, **{ name: "Example", command: "true", tier: :fast,
                                        kind: :computational, group: :lint }.merge(overrides))
  end

  describe Sidecar::Handlers::PassFail do
    it "is green when the tool exits zero" do
      result = described_class.new.call(sensor: sensor, targets: %w[a.rb], runner:)

      expect(result).to be_ok
    end

    it "summarises stdout when the tool fails" do
      runner.responses = { "true" => [ "boom on line 3\n", false ] }

      expect(described_class.new.call(sensor: sensor, targets: [], runner:).summary).to eq("boom on line 3")
    end

    it "splices the target set into a command that asks for it" do
      described_class.new.call(sensor: sensor(command: "rspec {files}"), targets: %w[a.rb b.rb], runner:)

      expect(runner.commands.last).to eq("rspec a.rb b.rb")
    end
  end

  describe Sidecar::Handlers::Rubocop do
    let(:offenses_json) do
      { "files" => [ { "path" => "app/x.rb",
                       "offenses" => [ { "location" => { "line" => 7 },
                                         "cop_name" => "Style/Foo",
                                         "message" => "no" } ] } ] }.to_json
    end

    it "reads offences down to the line" do
      runner.responses = { "rubocop" => [ offenses_json, false ] }

      result = described_class.new.call(sensor: sensor, targets: %w[app/x.rb], runner:)

      expect(result.offenses).to eq([ { file: "app/x.rb", line: 7, rule: "Style/Foo", message: "no" } ])
    end

    # This is what lets a project run a forced --only list with zero handler code
    # of its own: the design-system gate is a registry entry, not a subclass.
    it "runs whatever command it was parameterised with" do
      handler = described_class.new(command: "bin/rubocop --only DesignSystem --format json")
      handler.call(sensor: sensor, targets: %w[app/x.rb], runner:)

      expect(runner.commands.last).to eq("bin/rubocop --only DesignSystem --format json app/x.rb")
    end

    it "reports unreadable output as its own shape, not as a failure" do
      runner.responses = { "rubocop" => [ "<html>gateway timeout</html>", false ] }

      result = described_class.new.call(sensor: sensor, targets: %w[app/x.rb], runner:)

      expect(result).to be_a(Sidecar::HandlerResult::Unreadable).and have_attributes(tool: "rubocop")
    end

    it "does not run the tool when nothing in the target set is Ruby" do
      result = described_class.new.call(sensor: sensor, targets: %w[app/x.css], runner:)

      expect(runner.commands).to be_empty
      expect(result.targets).to have_attributes(considered: 1, run: 0)
    end
  end

  describe Sidecar::Handlers::Stylelint do
    # stylelint emits absolute paths; the gate speaks repo-relative and matches
    # on the string. Normalising belongs here because only a handler knows its
    # tool's convention.
    it "relativises the absolute paths stylelint reports" do
      json = [ { "source" => "#{Dir.pwd}/app/a.css",
                 "warnings" => [ { "line" => 2, "rule" => "gm-token", "text" => "raw value" } ] } ].to_json
      runner.responses = { "stylelint" => [ json, false ] }

      result = described_class.new.call(sensor: sensor, targets: %w[app/a.css], runner:)

      expect(result.offenses.first[:file]).to eq("app/a.css")
    end

    it "reports unreadable output rather than guessing" do
      runner.responses = { "stylelint" => [ "not json", false ] }

      expect(described_class.new.call(sensor: sensor, targets: %w[app/a.css], runner:))
        .to be_a(Sidecar::HandlerResult::Unreadable)
    end
  end

  describe Sidecar::Handlers::TargetedSpecs do
    let(:rules) do
      {
        /_spec\.rb\z/ => [ '\0' ],
        %r{(\A|/)app/(.*)\.rb\z} => [ '\1spec/\2_spec.rb' ],
        %r{(\A|/)lib/(.*)\.rb\z} => [ '\1spec/lib/\2_spec.rb' ]
      }
    end

    subject(:handler) { described_class.new(rules:) }

    around { |example| in_a_repo { example.run } }

    it "maps a source file to its spec and runs it" do
      FileUtils.mkdir_p("spec")
      File.write("spec/x_spec.rb", "")

      handler.call(sensor: sensor(command: "rspec {files}"), targets: %w[app/x.rb], runner:)

      expect(runner.commands.last).to eq("rspec spec/x_spec.rb")
    end

    # Anchored at a path boundary so a pack's app/ maps inside the pack rather
    # than to the repo root.
    it "maps a pack's source inside that pack" do
      FileUtils.mkdir_p("packs/prospects/spec")
      File.write("packs/prospects/spec/x_spec.rb", "")

      handler.call(sensor: sensor(command: "rspec {files}"), targets: %w[packs/prospects/app/x.rb], runner:)

      expect(runner.commands.last).to eq("rspec packs/prospects/spec/x_spec.rb")
    end

    # app/lib/foo.rb matches both the app/ and lib/ rules. If every matching rule
    # fired it would produce the correct spec/lib/foo_spec.rb alongside a
    # nonsense app/spec/lib/foo_spec.rb — the double rewrite the ordering comment
    # in the original table existed to prevent.
    it "applies only the first matching rule, so a path is never rewritten twice" do
      FileUtils.mkdir_p("spec/lib")
      FileUtils.mkdir_p("app/spec/lib")
      File.write("spec/lib/foo_spec.rb", "")
      File.write("app/spec/lib/foo_spec.rb", "")

      handler.call(sensor: sensor(command: "rspec {files}"), targets: %w[app/lib/foo.rb], runner:)

      expect(runner.commands.last).to eq("rspec spec/lib/foo_spec.rb")
    end

    it "treats a changed spec as its own target" do
      FileUtils.mkdir_p("spec")
      File.write("spec/x_spec.rb", "")

      handler.call(sensor: sensor(command: "rspec {files}"), targets: %w[spec/x_spec.rb], runner:)

      expect(runner.commands.last).to eq("rspec spec/x_spec.rb")
    end

    # Nothing failed. Something is missing, and the two read differently to
    # whoever is deciding what to do next.
    it "is green with a note when no rule maps the change" do
      result = handler.call(sensor: sensor, targets: %w[README.md], runner:)

      expect(result).to be_ok
      expect(result.summary).to match(/no rule maps/)
    end

    # How a broken mapping actually presents, and why the counts differ.
    it "names the paths it mapped to when none of them exist" do
      result = handler.call(sensor: sensor, targets: %w[app/ghost.rb], runner:)

      expect(result.summary).to include("spec/ghost_spec.rb")
      expect(result.targets).to have_attributes(considered: 1, run: 0)
    end

    it "supports a one-to-many rule" do
      handler = described_class.new(rules: { %r{\Aapp/(.*)\.rb\z} => [ 'spec/\1_spec.rb', 'spec/requests/\1_spec.rb' ] })
      FileUtils.mkdir_p("spec/requests")
      File.write("spec/x_spec.rb", "")
      File.write("spec/requests/x_spec.rb", "")

      handler.call(sensor: sensor(command: "rspec {files}"), targets: %w[app/x.rb], runner:)

      expect(runner.commands.last).to eq("rspec spec/x_spec.rb spec/requests/x_spec.rb")
    end
  end

  describe Sidecar::Handlers::Summary do
    # Pooling the streams let Brakeman's seven harmless git warnings bury the
    # actual security finding. A bug fix, not a style choice.
    it "prefers stdout, where tools report findings, over stderr, where they grumble" do
      expect(described_class.of("the real finding\n", "warning: git\nwarning: git\n"))
        .to eq("the real finding")
    end

    it "falls back to stderr when stdout says nothing" do
      expect(described_class.of("  \n", "segfault\n")).to eq("segfault")
    end

    it "says so when neither stream said anything" do
      expect(described_class.of("", "")).to eq("failed with no output")
    end
  end
end
