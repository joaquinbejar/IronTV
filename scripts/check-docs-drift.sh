#!/usr/bin/env bash
# Fails when README.md, CLAUDE.md, or SPEC.md contradict project.yml on the
# facts that rot silently: platform minimums, the bundle identifier, and the
# Swift version. Convention (CLAUDE.md): a project.yml change to any of these
# updates the docs in the same PR.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
err() { echo "docs-drift: $*" >&2; fail=1; }

# --- facts from project.yml -------------------------------------------------
macos=$(awk -F'"' '$1 ~ /^[[:space:]]*macOS:[[:space:]]*$/ { print $2; exit }' project.yml)
ios=$(awk -F'"' '$1 ~ /^[[:space:]]*iOS:[[:space:]]*$/ { print $2; exit }' project.yml)
tvos=$(awk -F'"' '$1 ~ /^[[:space:]]*tvOS:[[:space:]]*$/ { print $2; exit }' project.yml)
swift=$(awk -F'"' '$1 ~ /SWIFT_VERSION:[[:space:]]*$/ { print $2; exit }' project.yml)
bundle=$(awk '$1 == "PRODUCT_BUNDLE_IDENTIFIER:" { print $2; exit }' project.yml)

for var in macos ios tvos swift bundle; do
  [ -n "${!var}" ] || { err "could not extract '$var' from project.yml — update this script"; }
done
[ "$fail" -eq 0 ] || exit 1

# The doc token for a minimum: "14" for 14.0, but "14.1" if a target ever
# lands on a non-.0 minor — docs must not round a real minor away.
doc_token() {
  case "$1" in
    *.0) echo "${1%%.*}" ;;
    *) echo "$1" ;;
  esac
}
macos_major=$(doc_token "$macos")
ios_major=$(doc_token "$ios")
tvos_major=$(doc_token "$tvos")
swift_major=${swift%%.*}

# --- README.md (authoritative) ----------------------------------------------
grep -q "macOS ${macos_major}+" README.md \
  || err "README.md does not state 'macOS ${macos_major}+' (project.yml says ${macos})"
grep -q "iOS / iPadOS ${ios_major}+" README.md \
  || err "README.md does not state 'iOS / iPadOS ${ios_major}+' (project.yml says ${ios})"
grep -q "tvOS ${tvos_major}+" README.md \
  || err "README.md does not state 'tvOS ${tvos_major}+' (project.yml says ${tvos})"
grep -q "Swift ${swift_major} language mode" README.md \
  || err "README.md does not state 'Swift ${swift_major} language mode' (project.yml says SWIFT_VERSION ${swift})"

# --- CLAUDE.md (untracked local convention file — checked only if present) ---
if [ -f CLAUDE.md ]; then
  grep -q "macOS ${macos_major}+" CLAUDE.md \
    || err "CLAUDE.md does not state 'macOS ${macos_major}+' (project.yml says ${macos})"
  grep -Eq "iOS(/iPadOS)? ${ios_major}\+" CLAUDE.md \
    || err "CLAUDE.md does not state 'iOS ${ios_major}+' (project.yml says ${ios})"
  grep -q "tvOS ${tvos_major}+" CLAUDE.md \
    || err "CLAUDE.md does not state 'tvOS ${tvos_major}+' (project.yml says ${tvos})"
  grep -q "Swift ${swift_major} language mode" CLAUDE.md \
    || err "CLAUDE.md does not state 'Swift ${swift_major} language mode' (project.yml says SWIFT_VERSION ${swift})"
fi

# --- SPEC.md (historical, but stated current facts must not mislead) ---------
grep -q "$bundle" SPEC.md \
  || err "SPEC.md does not carry the real bundle id '${bundle}'"
grep -q "macOS ${macos_major}+" SPEC.md \
  || err "SPEC.md's banner does not state 'macOS ${macos_major}+' (project.yml says ${macos})"
grep -Eq "iOS(/iPadOS)? ${ios_major}\+" SPEC.md \
  || err "SPEC.md's banner does not state 'iOS/iPadOS ${ios_major}+' (project.yml says ${ios})"
grep -q "tvOS ${tvos_major}+" SPEC.md \
  || err "SPEC.md's banner does not state 'tvOS ${tvos_major}+' (project.yml says ${tvos})"
docs=(SPEC.md README.md)
[ -f CLAUDE.md ] && docs+=(CLAUDE.md)
if grep -q "com.quantkernel" "${docs[@]}"; then
  err "a doc still references the pre-rename 'com.quantkernel' bundle id"
fi

if [ "$fail" -ne 0 ]; then
  echo "docs-drift: fix the doc(s) or project.yml so they agree (see CLAUDE.md convention)." >&2
  exit 1
fi
echo "docs-drift: ${docs[*]} agree with project.yml (${macos}/${ios}/${tvos}, Swift ${swift}, ${bundle})."
