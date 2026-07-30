#!/bin/bash
# Lightweight credential scan over tracked files.
#
# Deliberately narrow: it looks for shapes that are almost never legitimate in
# this repo rather than trying to be a general secret scanner. False positives
# cost more than they save on a repo this size, and the real defence is that
# credentials live in the Keychain and in the gitignored .env.
#
# Usage: scripts/secret-scan.sh
# Exit: 0 clean, 1 something that looks like a credential is tracked.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

fail=0
report() {
    echo "✗ $1" >&2
    fail=1
}

# 1. Files that must never be tracked, whatever .gitignore says right now.
#    `.env.example` and friends are templates with placeholder values and are
#    meant to be tracked — they are what tell a new checkout which keys to set.
while IFS= read -r pattern; do
    matches=$(git ls-files -- "$pattern" | grep -vE '\.(example|sample|template)$' || true)
    if [[ -n "$matches" ]]; then
        report "tracked file matching '$pattern':"
        echo "$matches" | sed 's/^/    /' >&2
    fi
done <<'PATTERNS'
.env
.env.*
*.p12
*.pem
*.key
*.mobileprovision
*.provisionprofile
*.cer
PATTERNS

# 2. Private key blocks and Apple/GitHub token shapes in tracked text.
#    Fixtures and tests are sanitized by policy, so they are scanned too.
if git grep -nI -E -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
                  -e '\bghp_[A-Za-z0-9]{20,}' \
                  -e '\bgithub_pat_[A-Za-z0-9_]{20,}' \
                  -e '\bxox[baprs]-[A-Za-z0-9-]{10,}' \
                  -- . >/dev/null 2>&1; then
    report "private key or access token found in tracked files:"
    git grep -nI -E -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
                    -e '\bghp_[A-Za-z0-9]{20,}' \
                    -e '\bgithub_pat_[A-Za-z0-9_]{20,}' \
                    -e '\bxox[baprs]-[A-Za-z0-9-]{10,}' \
                    -- . | sed 's/^/    /' >&2
fi

# 3. Xtream credential-bearing URLs. A playlist URL carries username and
#    password in its query, so any tracked one is a leak — except the
#    placeholder forms the UI and docs legitimately show.
#    Placeholders: example hosts, and elided or fixture-style values.
if git grep -nI -E 'https?://[^[:space:]"]+[?&](username|password)=' -- . \
    | grep -viE 'example\.(com|org|net)|host\.example|\{|(username|password)=(…|\.\.\.|USER|PASS|U&|P&|user1|pass1|fixture)' \
    | grep -v '^scripts/secret-scan.sh:' >/dev/null 2>&1; then
    report "credential-bearing playlist URL in tracked files:"
    git grep -nI -E 'https?://[^[:space:]"]+[?&](username|password)=' -- . \
        | grep -viE 'example\.(com|org|net)|host\.example|\{|(username|password)=(…|\.\.\.|USER|PASS|U&|P&|user1|pass1|fixture)' \
        | grep -v '^scripts/secret-scan.sh:' | sed 's/^/    /' >&2
fi

# 4. The playback path form, which embeds credentials as path segments.
if git grep -nI -E 'https?://[^[:space:]"/]+/(live|movie|series|timeshift)/[^/[:space:]"]+/[^/[:space:]"]+/' -- . \
    | grep -viE 'example\.(com|org|net)|host\.example|\{|REDACTED|us/er|topsecret|user1|pass1' \
    | grep -v '^scripts/secret-scan.sh:' >/dev/null 2>&1; then
    report "credential-bearing playback URL in tracked files:"
    git grep -nI -E 'https?://[^[:space:]"/]+/(live|movie|series|timeshift)/[^/[:space:]"]+/[^/[:space:]"]+/' -- . \
        | grep -viE 'example\.(com|org|net)|host\.example|\{|REDACTED|us/er|topsecret|user1|pass1' \
        | grep -v '^scripts/secret-scan.sh:' | sed 's/^/    /' >&2
fi

# 5. .env must stay ignored, so an accidental `git add` is refused rather than
#    silently staged. Uses a temp file so the check works on a clean checkout.
#    Only ever creates the probe when there is no real .env to clobber, and
#    removes it from an EXIT trap: under `set -e` an unexpected failure — or an
#    interrupt — must not leave a stray .env behind in someone's checkout.
if [[ ! -f .env ]]; then
    printf 'PROBE=1\n' > .env
    trap 'rm -f "$REPO/.env"' EXIT
fi
if git check-ignore -q .env; then
    echo "✓ .env is ignored"
else
    report ".env is NOT covered by .gitignore"
fi

if [[ $fail -eq 0 ]]; then
    echo "✓ secret scan clean"
fi
exit $fail
