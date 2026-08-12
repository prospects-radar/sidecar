# frozen_string_literal: true

require "set"
require "open3"

module Sidecar
  # Which files a change touched, and which lines within them are new.
  #
  # This is what makes every report changed-line first: an offence on a line you
  # did not touch is pre-existing debt, not something to answer for. It answers
  # "did this change add this line?" against git history, which is why it can be
  # fooled by nothing — where a baseline gate depends on a committed record being
  # kept honest.
  #
  # Two constructors, because there are two genuinely different questions:
  #
  #   from_git(base:)          what the working tree has touched, including edits
  #                            not yet committed. The always-on loop's question.
  #   from_range(base:, head:) what a range of commits touched. The merge gate's.
  #
  # The git plumbing lives here rather than being borrowed from a project script,
  # so the loop and the gate cannot disagree about what "a changed line" means.
  #
  # Paths are repo-relative, as a precondition rather than something re-normalised
  # defensively. Only a handler knows its tool's path convention — stylelint emits
  # absolute paths, RuboCop repo-relative — so normalising belongs there.
  class ChangeSet
    # A gate that cannot see the change must never report clean. Raised rather
    # than returning an empty set, because an empty set is indistinguishable from
    # a genuinely clean run at exactly the moment the guardrail is not working.
    BlindGate = Class.new(StandardError)

    DEFAULT_BASE = "HEAD"
    FNM_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH

    attr_reader :base, :files, :untracked

    class << self
      # The working tree against a base ref. `HEAD` is the right default and a
      # legitimate answer here: the question is what you have edited since your
      # last commit, so an empty range is the expected steady state rather than a
      # blind gate.
      def from_git(base: DEFAULT_BASE, git: Git.new)
        git.resolve!(base)
        new(base:, tracked: git.tracked_changes(base), untracked: git.untracked, git:)
      end

      # A commit range, as the merge gate sees it. Unlike the working tree, an
      # unresolvable base or one that resolves to head means the gate is looking
      # at nothing, and it refuses rather than reporting clean.
      def from_range(base:, head: "HEAD", git: Git.new)
        base_sha = git.resolve!(base)
        head_sha = git.resolve!(head)
        if base_sha == head_sha
          raise BlindGate, "base #{base.inspect} resolves to #{head.inspect} (#{short(base_sha)}); " \
                           "the range is empty and the gate would inspect nothing"
        end

        range = "#{base}...#{head}"
        new(base: range, tracked: git.changed_in_range(range), git:)
      end

      def short(sha) = sha.to_s[0, 8]
    end

    def initialize(base: DEFAULT_BASE, tracked: [], untracked: [], git: Git.new)
      @base = base
      @git = git
      @untracked = untracked.select { |file| File.file?(file) }.to_set
      @files = (tracked.select { |file| File.file?(file) } + @untracked.to_a).uniq.sort
      @added_lines = {}
    end

    def empty? = files.empty?

    # Files matching any of `globs`. An empty glob list means "no declared
    # scope", which the scan reads as whole-repo — so it returns nothing here and
    # the caller decides.
    def matching(globs)
      patterns = Array(globs).map { |glob| normalize_glob(glob) }
      return [] if patterns.empty?

      files.select { |file| patterns.any? { |pattern| File.fnmatch?(pattern, file, FNM_FLAGS) } }
    end

    def intersects?(globs) = matching(globs).any?

    # Line numbers, as numbered in the file on disk, that this change added or
    # modified. An untracked file has no committed counterpart, so all of it is
    # new.
    def added_lines(file)
      @added_lines[file] ||= untracked.include?(file) ? all_lines(file) : @git.added_lines(file, base)
    end

    # Keep only the offences sitting on lines this change touched.
    #
    # Grouped by file first. Line 42 being new in one file says nothing about
    # line 42 in another, and unioning the sets across files would let one file's
    # edits vouch for another's.
    def select_new(offenses)
      offenses.group_by { |offense| offense[:file] }
              .flat_map { |file, group| group.select { |o| o[:line] && added_lines(file).include?(o[:line]) } }
    end

    private

    # Ruby's fnmatch only gives "**" its any-depth meaning when a slash follows,
    # so a bare directory glob like "zapier_app/**" would miss nested files.
    # Expanding the trailing form fixes that; every other glob passes through.
    def normalize_glob(glob)
      glob.end_with?("/**") ? "#{glob}/*" : glob
    end

    def all_lines(file)
      (1..File.foreach(file).count).to_set
    rescue SystemCallError, IOError
      Set.new
    end

    # The only thing in core that shells out to git. Kept small and separate so
    # the arithmetic above can be read without it.
    class Git
      def initialize(dir: nil)
        @dir = dir
      end

      # Returns the sha, or raises. This is the check that makes a blind gate
      # loud: an unfetched ref, a typo, or a clone too shallow to reach the base
      # all present identically here, and all used to present as a clean run.
      def resolve!(ref)
        out, ok = sh("git", "rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
        raise BlindGate, "cannot resolve #{ref.inspect}: unfetched, misspelled, or outside a shallow clone" unless ok

        out.strip
      end

      def tracked_changes(base)
        out, ok = sh("git", "diff", "--name-only", "--diff-filter=d", base)
        ok ? out.lines.map(&:chomp) : []
      end

      def changed_in_range(range)
        out, ok = sh("git", "diff", "--name-only", "--diff-filter=d", range)
        ok ? out.lines.map(&:chomp) : []
      end

      def untracked
        out, ok = sh("git", "ls-files", "--others", "--exclude-standard")
        ok ? out.lines.map(&:chomp) : []
      end

      def added_lines(file, base)
        out, ok = sh("git", "diff", "--unified=0", base, "--", file)
        ok ? self.class.parse_added_lines(out) : Set.new
      end

      # Parse a `git diff --unified=0` body into the set of line numbers it added,
      # numbered in the new file. Pure, so the arithmetic is testable on its own
      # as well as through a real repository.
      def self.parse_added_lines(diff_text)
        added = Set.new
        new_line = nil
        diff_text.each_line do |line|
          if (match = line.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/))
            new_line = match[1].to_i
          elsif line.start_with?("+++")
            next
          elsif line.start_with?("+") && new_line
            added << new_line
            new_line += 1
          end
          # '-' and '\' lines do not advance the new-file counter, and unified=0
          # emits no context lines, so nothing else needs handling.
        end
        added
      end

      private

      def sh(*cmd)
        cmd = [ cmd.first, "-C", @dir, *cmd[1..] ] if @dir
        out, _err, status = Open3.capture3(*cmd)
        [ out, status.success? ]
      end
    end
  end
end
