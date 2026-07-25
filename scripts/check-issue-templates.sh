#!/usr/bin/env bash
#
# Checks that every issue form in .github/ISSUE_TEMPLATE will actually render.
#
# GitHub does not fail loudly when an issue form is unusable. It drops the
# template from the chooser and quietly redirects `?template=<file>` to the
# chooser instead, so a link that used to open a form starts opening a menu and
# nothing anywhere says why. That is exactly what happened to
# `list-community.yml`, which the app links to from its Browse screen: it named
# a label, `community listing`, that did not exist in the repository. The YAML
# was valid. The label was the whole problem.
#
# Two things are checked, because those are the two ways a form disappears:
#
#   1. the file parses as YAML and has the keys GitHub requires
#   2. every label it references exists in the repository
#
# The label check needs the API, so it is skipped without a token rather than
# failing: a fork without secrets should still get the parse check.
set -euo pipefail

cd "$(dirname "$0")/.."
directory=".github/ISSUE_TEMPLATE"
status=0

shopt -s nullglob
templates=("$directory"/*.yml "$directory"/*.yaml)
if [ ${#templates[@]} -eq 0 ]; then
    echo "no issue templates found in $directory"
    exit 0
fi

# The repository's labels, once, if we can get them.
labels=""
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    labels="$(gh label list --limit 200 --json name --jq '.[].name' 2>/dev/null || true)"
fi
if [ -z "$labels" ]; then
    echo "note: no gh credentials, skipping the label existence check"
fi

for template in "${templates[@]}"; do
    name="$(basename "$template")"

    # config.yml is the chooser's own configuration, not a form.
    if [ "$name" = "config.yml" ]; then
        continue
    fi

    referenced="$(
        ruby -ryaml -e '
document = begin
  YAML.safe_load(File.read(ARGV[0]))
rescue Psych::SyntaxError => error
  warn "PARSE #{error.message}"
  exit 1
end

unless document.is_a?(Hash)
  warn "PARSE top level is not a mapping"
  exit 1
end

%w[name description body].each do |key|
  next if document.key?(key)
  warn "PARSE missing required key: #{key}"
  exit 1
end

unless document["body"].is_a?(Array) && !document["body"].empty?
  warn "PARSE body must be a non-empty list"
  exit 1
end

labels = document["labels"] || []
labels = labels.split(",").map(&:strip).reject(&:empty?) if labels.is_a?(String)
labels.each { |label| puts label }
' "$template"
    )" || {
        echo "FAIL $name does not parse as a GitHub issue form"
        status=1
        continue
    }

    missing=""
    if [ -n "$labels" ] && [ -n "$referenced" ]; then
        while IFS= read -r label; do
            [ -z "$label" ] && continue
            if ! printf '%s\n' "$labels" | grep -Fxq "$label"; then
                missing="$missing $label"
            fi
        done <<<"$referenced"
    fi

    if [ -n "$missing" ]; then
        echo "FAIL $name references labels that do not exist:$missing"
        echo "     GitHub will hide this template rather than report an error."
        echo "     Create them, e.g. gh label create \"${missing# }\""
        status=1
    else
        echo "ok   $name"
    fi
done

exit $status
