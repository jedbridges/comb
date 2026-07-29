#!/bin/sh
#
# Run a build or test command and print only the lines a reader acts on:
# diagnostics with their source context, failures, and the result. The full
# untouched output is kept under .logs/, and the path is printed every run.
#
# Why: a no-op `xcodebuild build` prints ~150 KB and a fully passing
# `swift test` prints ~70 KB, almost all of it per-file compile invocations
# and "passed after 0.001 seconds" lines. That output is free for a human who
# scrolls past it and expensive for an agent, which pays for every byte.
#
# Logs live in .logs/ rather than build/, because build/Logs is Xcode's own
# activity-log store and macOS filesystems are case-insensitive by default:
# build/logs and build/Logs are the same directory.
#
# Usage: scripts/quiet.sh <name> <command> [args...]
#        V=1 scripts/quiet.sh ...   also stream everything, unfiltered

set -u

name=$1
shift

dir=${QUIET_LOG_DIR:-.logs}
mkdir -p "$dir" || exit 1
log="$dir/$name.log"

# Keep the previous run's log. A failure that a rerun overwrites before anyone
# reads it is a failure nobody can diagnose, and concurrent runs of the same
# target do exactly that.
[ -f "$log" ] && mv -f "$log" "$log.prev"

# xcodebuild does not always exit non-zero when it fails. Two concurrent builds
# sharing a derived data directory produce "unable to attach DB: ... database is
# locked", a "** BUILD FAILED **" banner, and an exit status of 0, so a caller
# that trusts the status gets a false green. The banner is the more reliable
# signal: when it is in the log, the run failed whatever the status said.
banner_failed() {
	grep -qE '^\*\* (BUILD|TEST|ARCHIVE) FAILED \*\*' "$log" 2>/dev/null
}

if [ "${V:-0}" != "0" ]; then
	# Still record the log, but let everything through to the terminal.
	# A pipeline's exit status is tee's, not the command's, and POSIX sh has
	# no PIPESTATUS, so the real status travels through a file.
	rc="$log.rc"
	{ "$@" 2>&1; echo $? >"$rc"; } | tee "$log"
	status=$(cat "$rc" 2>/dev/null || echo 1)
	rm -f "$rc"
	[ "$status" -eq 0 ] && banner_failed && status=1
	echo "($name exit $status; full log: $log)"
	exit "$status"
fi

# A clean xcodebuild otherwise prints nothing for several minutes, and silence
# is indistinguishable from a hang. One dot every 5s on stderr, so it stays out
# of anything parsing stdout. Anything quick finishes before the first dot, so
# the fast loop stays completely silent.
start=$(date +%s)
"$@" >"$log" 2>&1 &
cmd=$!

while sleep 5; do
	kill -0 "$cmd" 2>/dev/null || break
	printf '.' >&2
done &
ticker=$!

trap 'kill "$cmd" "$ticker" 2>/dev/null; exit 130' INT TERM

wait "$cmd"
status=$?
[ $status -eq 0 ] && banner_failed && status=1

# Killing the ticker leaves its in-flight `sleep` orphaned for up to 5s. That
# is one short-lived process per invocation and it reaps itself, which is a
# better trade than signalling the whole process group.
kill "$ticker" 2>/dev/null
wait "$ticker" 2>/dev/null
trap - INT TERM

[ $(($(date +%s) - start)) -ge 5 ] && printf '\n' >&2

# What survives:
#   - compiler/linker diagnostics, plus the indented source snippet that
#     follows them, which is the part that makes a diagnostic readable
#   - xcodebuild's ** BUILD FAILED ** banners and tool-level failures
#   - swift-testing and XCTest failures and the run summary
#
# Repeated diagnostics are collapsed (a warning in a header repeats once per
# importing file). Anything dropped past the cap is counted, not hidden.
kept=$(
	awk -v max=200 '
		# n must start as a number. An uninitialized awk variable is the null
		# string, so buf[n] would first write to buf[""] while n++ makes it 1,
		# and the END loop over buf[0..n] would miss that first line.
		BEGIN { n = 0; ctx = 0; indiag = 0; drop = 0 }

		function emit(line) { if (n < max) buf[n] = line; n++ }

		# Source context belonging to the diagnostic just seen. Two formats
		# turn up and both matter: the swift driver prints "5 | return nam"
		# with a "| `- error:" marker, while xcodebuild passes through the
		# frontend format, a raw source line under a "~~~^~~~" caret. Rather
		# than pattern-match either, take everything until the block ends at
		# a blank line or the next build step.
		indiag && !/:[0-9]+:[0-9]+: (error|warning|note):/ {
			if ($0 ~ /^[[:space:]]*$/ ||
			    $0 ~ /^(SwiftCompile|SwiftDriverJobDiscovery|CompileC|Ld|CpResource|Copy|builtin-|ExecuteExternalTool|PhaseScriptExecution|RegisterExecutionPolicyException|Building for|\[[0-9]+\/[0-9]+\])/ ||
			    ctx >= 10) {
				# Block over. Fall through so this line gets judged normally.
				indiag = 0
			} else {
				if (!drop) { emit($0); ctx++ }
				next
			}
		}

		# Diagnostic header: path:line:col: error|warning|note: message
		/:[0-9]+:[0-9]+: (error|warning|note):/ {
			indiag = 1; ctx = 0; drop = 0
			if (seen[$0]++) { drop = 1; next }
			emit($0)
			next
		}

		# Boilerplate printed identically on every single run. Matched as a
		# whole line so a real diagnostic never disappears into this.
		/^note: (Building targets in dependency order|Target dependency graph)/ { next }
		/Executed 0 tests, with 0 failures/ { next }

		/^\*\*/ ||
		/^(ld|clang|swiftc|codesign|xcodebuild|error|warning):/ ||
		/Issue recorded/ ||
		/(Test|Suite) .* (failed|recorded)/ ||
		/Executed [0-9]+ test/ ||
		/Test run with [0-9]+ test/ ||
		/Fatal error|Assertion failed/ {
			if (!seen[$0]++) emit($0)
		}

		END {
			for (i = 0; i < n && i < max; i++) print buf[i]
			if (n > max) printf "... %d more matching lines withheld\n", n - max
		}
	' "$log" 2>/dev/null
)

[ -n "$kept" ] && echo "$kept"

# Only fall back to the raw tail when the filter found nothing to explain a
# failure. When it did find something, the tail is just the last few things
# that happened to succeed.
if [ $status -ne 0 ] && [ -z "$kept" ]; then
	echo "--- last 40 lines of $log ---"
	tail -40 "$log"
fi

echo "($name exit $status; full log: $log)"
exit $status
