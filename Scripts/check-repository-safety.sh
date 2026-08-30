#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

forbidden_paths='(^|/)(openloops\.json|personalization\.json|OPEN_LOOPS_CONTEXT\.md|cloud-sync-state\.json)$|(^|/)(Personalization|Codex Runs|support-bundles|exports|qa|audits|dist|install-backups|DerivedData|\.build)/|\.(p8|p12|pem|key|mobileprovision|provisionprofile|log|jsonl|trace|crash)$|(^|/)(GoogleService-Info\.plist|client_secret[^/]*\.json|service-account[^/]*\.json)$'

tracked_forbidden="$(git ls-files | grep -E "$forbidden_paths" || true)"
if [[ -n "$tracked_forbidden" ]]; then
    echo "Repository safety check failed: forbidden files are tracked:"
    echo "$tracked_forbidden"
    exit 1
fi

large_files="$(git ls-files -z | xargs -0 -I{} sh -c 'test -f "$1" && test "$(wc -c < "$1")" -gt 10000000 && echo "$1"' sh {} || true)"
if [[ -n "$large_files" ]]; then
    echo "Repository safety check failed: files larger than 10 MB are tracked:"
    echo "$large_files"
    exit 1
fi

secret_pattern="(gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----|client_secret[[:space:]]*[:=][[:space:]]*[\"'][^\"']{12,})"
secret_hits="$(git grep -nI -E "$secret_pattern" -- . ':(exclude)Scripts/check-repository-safety.sh' || true)"
if [[ -n "$secret_hits" ]]; then
    echo "Repository safety check failed: possible credential material found:"
    echo "$secret_hits"
    exit 1
fi

git diff --check
echo "Repository safety check passed."
