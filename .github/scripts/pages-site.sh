#!/bin/sh
# A repository without a Pages site, such as a fork, still builds the website
# but has nowhere to publish it. Any other lookup failure stops the workflow.
set -eu
if response=$(gh api "repos/$GITHUB_REPOSITORY/pages" --jq .build_type 2>&1); then
    printf 'enabled=true\n' >> "$GITHUB_OUTPUT"
    exit 0
fi
case $response in
*'(HTTP 404)'*)
    printf 'enabled=false\n' >> "$GITHUB_OUTPUT"
    echo "::notice title=GitHub Pages::$GITHUB_REPOSITORY has no Pages site; the website was built but not published."
    ;;
*)
    printf '%s\n' "$response" >&2
    exit 1
    ;;
esac
