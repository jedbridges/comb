#!/usr/bin/env bash
#
# Looks for UI that compiles, tests green, and can never appear.
#
# The app target has no automated coverage, and the defect that motivated this
# script proved what that costs: a whole feature shipped whose control was never
# offered. It compiled. Its view was correct. Its preview would have looked
# right. Nothing in the app could reach it.
#
# Two rules, both taken from the shape of that defect rather than invented:
#
#   1. A `@State` optional that is only ever assigned nil. If the only writes
#      are the dismissals a presentation binding performs for you, the sheet it
#      drives can never open.
#
#   2. A stored property on a `View` that appears in the module only as its own
#      declaration and as argument labels at call sites. Every caller passes it;
#      the view never reads it.
#
# Both are deliberately narrow. A checker that guesses costs more than it saves,
# so where a rule cannot tell, it stays quiet: an identifier shared with
# anything else in the module is treated as used. Expect false negatives, not
# false positives.
#
# `periphery scan` is the principled version of rule two and was tried first, on
# the same commit. It took 73 seconds and a full Xcode build, reported 134
# findings of which the great majority were live code, and missed both members
# this script was written to catch: it counts a memberwise-init argument as a
# use, and a binding handed to a presentation modifier as a read. A tool that
# needs a build, floods the log, and misses the defect is not worth the minute,
# so this is the whole check rather than half of one.
#
# Put `// dead-ui:allow <why>` on the declaration to silence one case.
set -euo pipefail

cd "$(dirname "$0")/.."
directory="${1:-Comb}"

if [ ! -d "$directory" ]; then
    echo "no such directory: $directory"
    exit 1
fi

ruby -e '
directory = ARGV[0]
files = Dir.glob(File.join(directory, "**", "*.swift")).sort
if files.empty?
  warn "no Swift files under #{directory}"
  exit 1
end

sources = files.map { |path| [path, File.readlines(path, chomp: true, encoding: "UTF-8")] }

findings = []

# Comments are stripped before any identifier is counted, so a name that
# survives only in prose does not read as a use. `://` is spared so a URL in a
# string literal does not eat the rest of its line.
def uncommented(line)
  line.sub(%r{(?<!:)//.*$}, "")
end

# The modifiers that take an `item:` binding and write through it exactly once,
# to nil, when the presentation goes away. A binding handed to one of these is
# not evidence that anything ever sets it.
DISMISS_ONLY = /\.(?:sheet|fullScreenCover|popover|alert|confirmationDialog|navigationDestination|inspector)\s*\(\s*item:/

# Rule 1: a @State optional nothing ever fills in.
sources.each do |path, lines|
  lines.each_with_index do |line, index|
    next unless line =~ /@State\b/
    next if line.include?("dead-ui:allow")
    match = uncommented(line).match(/\bvar\s+([A-Za-z_]\w*)\s*:\s*([^=]+?)\s*(?:=\s*(.+?))?\s*$/)
    next unless match

    name, type, initial = match[1], match[2], match[3]
    next unless type.end_with?("?")
    next if initial && initial != "nil"

    filled = false
    dismiss_only_binding = true
    binding_used = false

    lines.each_with_index do |other, other_index|
      next if other_index == index
      body = uncommented(other)

      body.scan(/(?<![\w$.])#{Regexp.escape(name)}\s*=\s*(?!=)\s*(.*)$/) do |(rest)|
        filled = true unless rest.strip.start_with?("nil")
      end

      if body.include?("$#{name}")
        binding_used = true
        dismiss_only_binding = false unless body =~ DISMISS_ONLY
      end
    end

    next if filled
    next if binding_used && !dismiss_only_binding

    reason = binding_used ?
      "`#{name}` drives a presentation but is only ever set to nil, so it never opens" :
      "`#{name}` is only ever nil"
    findings << [path, index + 1, reason]
  end
end

# Rule 2: a stored property on a View that no one in the module reads.
#
# Occurrences followed by a colon are argument labels, other declarations, or
# dictionary keys. Discounting them is what makes "every call site passes it and
# nothing consumes it" visible.
def used_anywhere?(sources, name, home_path, home_line)
  pattern = /(?<![\w$.])#{Regexp.escape(name)}\b(?!\s*:)/
  sources.any? do |path, lines|
    lines.each_with_index.any? do |line, index|
      next false if path == home_path && index == home_line
      uncommented(line) =~ pattern
    end
  end
end

sources.each do |path, lines|
  depth = 0
  view_depth = nil

  lines.each_with_index do |line, index|
    body = uncommented(line)

    if view_depth.nil? && body =~ /^\s*(?:\w+\s+)*struct\s+\w+\s*(?:<[^>]*>)?\s*:\s*([^{]+)\{/
      conformances = $1.split(",").map { |item| item.strip.sub(/<.*/, "") }
      view_depth = depth if conformances.include?("View")
    end

    if view_depth && depth == view_depth + 1 && !line.include?("dead-ui:allow")
      # An annotated declaration, an inferred one, or both. A trailing brace
      # means a computed property, which reads its own dependencies and is not
      # what this rule is about.
      declaration = body.match(
        /^\s*(?:(?:private|fileprivate|internal|public|final|weak|unowned)\s+)*(?:let|var)\s+([A-Za-z_]\w*)\s*(?::\s*[^={]+?)?\s*(?:=[^{]*)?$/
      )
      if declaration && !body.include?("@") && declaration[1] != "body"
        name = declaration[1]
        findings << [path, index + 1, "`#{name}` is passed by every caller and read by nobody"] \
          unless used_anywhere?(sources, name, path, index)
      end
    end

    depth += body.count("{") - body.count("}")
    view_depth = nil if view_depth && depth <= view_depth
  end
end

findings.sort_by! { |path, line, _| [path, line] }

findings.each { |path, line, reason| puts "FAIL #{path}:#{line} #{reason}" }

if findings.empty?
  puts "ok   #{files.count} files, no unreachable UI found"
  exit 0
end

puts
puts "#{findings.count} member(s) that compile and cannot be reached."
puts "Wire it up, delete it, or mark the declaration // dead-ui:allow <why>."
exit 1
' "$directory"
