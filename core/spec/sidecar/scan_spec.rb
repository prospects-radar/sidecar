# frozen_string_literal: true

require_relative "../../lib/sidecar/scan"
require_relative "../../lib/sidecar/project"
require_relative "../../lib/sidecar/sensor"

RSpec.describe Sidecar::Scan do
  FakeStatus2 = Struct.new(:ok) { def success? = ok }

  let(:runner) do
    Class.new do
      attr_reader :commands
      attr_accessor :responses

      def initialize
        @commands = []
        @responses = {}
      end

      def call(command)
        @commands << command
        out, ok = @responses.find { |pattern, _| command.include?(pattern) }&.last || [ "", true ]
        [ out, "", FakeStatus2.new(ok) ]
      end
    end.new
  end

  let(:change_set) { instance_double(Sidecar::ChangeSet, base: "HEAD", files: %w[app/x.rb]) }

  let(:project) do
    Sidecar::Project.new(
      root: Dir.pwd,
      registry: Sidecar::Registry.new,
      locations: { host: Sidecar::Location.new(name: :host, provides: %i[node],
                                               descriptions: { browser: "a browser" }),
                   container: Sidecar::Location.new(name: :container, provides: %i[database]) }
    )
  end

  def sensor(id, **overrides)
    Sidecar::Sensor.build(id, **{ name: id.to_s, command: "true", tier: :fast, kind: :computational,
                                  group: :lint, scope: %w[app/**/*.rb] }.merge(overrides))
  end

  def scan(sensors, location: :host, **rest)
    described_class.new(change_set:, sensors:, project:, location:, runner:, **rest).run
  end

  describe "sensor selection" do
    it "runs a sensor whose scope the change set intersects" do
      allow(change_set).to receive(:matching).and_return(%w[app/x.rb])

      expect(scan([ sensor(:brakeman) ]).map(&:id)).to eq(%i[brakeman])
    end

    it "skips a sensor whose scope the change set misses, without a result" do
      allow(change_set).to receive(:matching).and_return([])

      expect(scan([ sensor(:brakeman) ])).to be_empty
    end

    it "always runs a sensor that declares no scope" do
      expect(scan([ sensor(:brakeman, scope: []) ]).map(&:id)).to eq(%i[brakeman])
    end

    it "runs only the requested tier" do
      allow(change_set).to receive(:matching).and_return(%w[app/x.rb])

      expect(scan([ sensor(:fast_one), sensor(:slow_one, tier: :slow) ]).map(&:id)).to eq(%i[fast_one])
    end
  end

  describe "resources" do
    before { allow(change_set).to receive(:matching).and_return(%w[app/x.rb]) }

    # A check that did not run must never read like a check that passed.
    it "defers a sensor needing something this location lacks" do
      result = scan([ sensor(:cuke, needs: %i[browser]) ]).first

      expect(result).to be_deferred
      expect(result.summary).to eq("needs a browser, not available in host")
    end

    it "uses the project's own words for the missing resource" do
      expect(scan([ sensor(:cuke, needs: %i[browser]) ]).first.summary).to include("a browser")
    end

    it "runs the same sensor where the resource exists" do
      expect(scan([ sensor(:specs, needs: %i[database]) ], location: :container).first).to be_green
    end

    it "does not run the tool for a deferred sensor" do
      scan([ sensor(:cuke, needs: %i[browser]) ])

      expect(runner.commands).to be_empty
    end
  end

  describe "a tool that is not installed" do
    before { allow(change_set).to receive(:matching).and_return(%w[app/x.rb]) }

    # A pack ships sensors for a whole class of codebase without seeing whether
    # any given member installed the tool. That belongs on the board as
    # unavailable, not as a red mark against a check nobody declined to run.
    it "is unavailable rather than red" do
      result = scan([ sensor(:brakeman, command: "definitely-not-a-real-binary --quiet") ]).first

      expect(result).to be_unavailable
      expect(result).not_to be_actionable
    end

    it "names the binary it looked for" do
      expect(scan([ sensor(:brakeman, command: "definitely-not-a-real-binary") ]).first.summary)
        .to include("definitely-not-a-real-binary")
    end

    it "looks past leading environment assignments" do
      result = scan([ sensor(:specs, command: "RAILS_ENV=test definitely-not-a-real-binary") ]).first

      expect(result.summary).to include("definitely-not-a-real-binary").or include("RAILS_ENV")
      expect(result).to be_unavailable
    end
  end

  describe "narrowing findings to the change" do
    let(:handler) do
      Class.new do
        def initialize(offenses) = @offenses = offenses

        def call(sensor:, targets:, runner:)
          Sidecar::HandlerResult::Findings.new(offenses: @offenses,
                                               targets: Sidecar::Targets.new(considered: targets.size))
        end
      end
    end

    before { allow(change_set).to receive(:matching).and_return(%w[app/x.rb]) }

    it "is red for an offence on a line the change touched" do
      offense = { file: "app/x.rb", line: 3, rule: "R", message: "m" }
      allow(change_set).to receive(:select_new).and_return([ offense ])

      expect(scan([ sensor(:rubocop, handler: handler.new([ offense ])) ]).first).to be_red
    end

    it "is green for an offence on a line it did not" do
      offense = { file: "app/x.rb", line: 3, rule: "R", message: "m" }
      allow(change_set).to receive(:select_new).and_return([])

      result = scan([ sensor(:rubocop, handler: handler.new([ offense ])) ]).first

      expect(result).to be_green
      expect(result.preexisting.size).to eq(1)
    end

    # The gate is not handed to handlers on purpose: what counts as new is one
    # question with one answer, and letting each handler decide is how two of
    # them come to disagree.
    it "asks the gate, not the handler, what is new" do
      allow(change_set).to receive(:select_new).and_return([])
      scan([ sensor(:rubocop, handler: handler.new([ { file: "app/x.rb", line: 3, rule: "R", message: "m" } ])) ])

      expect(change_set).to have_received(:select_new)
    end
  end

  describe "unreadable tool output" do
    let(:handler) do
      Class.new do
        def call(sensor:, targets:, runner:)
          Sidecar::HandlerResult::Unreadable.new(tool: "rubocop", detail: "no parseable JSON")
        end
      end.new
    end

    before { allow(change_set).to receive(:matching).and_return(%w[app/x.rb]) }

    # Behavioural identity at cutover: a merge gate is not silently hardened as
    # a side effect of moving it into a gem.
    it "is green under the default advisory policy, and says so" do
      result = scan([ sensor(:rubocop, handler:) ]).first

      expect(result).to be_green
      expect(result.summary).to include("advisory")
    end

    it "is an error when the sensor declares it should be" do
      result = scan([ sensor(:rubocop, handler:, unreadable: :red) ]).first

      expect(result).to be_error
      expect(result).to be_actionable
    end
  end

  describe "cancellation" do
    before { allow(change_set).to receive(:matching).and_return(%w[app/x.rb]) }

    # Without the check between sensors, a pass would calmly start the next tool
    # on a tree that has already moved on.
    it "stops between sensors once cancelled" do
      results = scan([ sensor(:a), sensor(:b) ], cancelled: -> { true })

      expect(results).to be_empty
    end
  end

  describe "the result" do
    before { allow(change_set).to receive(:matching).and_return(%w[app/x.rb]) }

    it "carries the sensor's guidance for whoever it just rejected" do
      runner.responses = { "true" => [ "boom", false ] }

      expect(scan([ sensor(:rubocop, guidance: "run -a") ]).first.guidance).to eq("run -a")
    end

    it "times the run" do
      expect(scan([ sensor(:rubocop) ]).first.duration_ms).to be_a(Integer)
    end

    it "reports how many files it considered and ran against" do
      expect(scan([ sensor(:rubocop) ]).first.targets.to_h).to eq({ considered: 1, run: 1 })
    end

    it "refuses a handler that returns something that is not a result shape" do
      rogue = Class.new { def call(sensor:, targets:, runner:) = :fine }.new

      expect { scan([ sensor(:rogue, handler: rogue) ]) }
        .to raise_error(ArgumentError, /not a HandlerResult/)
    end
  end
end
