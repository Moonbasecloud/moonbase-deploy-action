#!/usr/bin/env bash
# Fails when the two helper scripts in scripts/ differ from the moonbase Skill's
# copies at one pinned commit of the public repository Moonbasecloud/moonbase-skill.
#   bash test/check-skill-drift.sh
#
# The pin is a full commit id, so the reference copies cannot change under it.
# To take a newer Skill release: copy its two scripts into scripts/, set
# SKILL_COMMIT below to that release's commit, and run this check.
set -euo pipefail

SKILL_REPO="Moonbasecloud/moonbase-skill"
SKILL_COMMIT="9914d42ab2d2c81393e0fadf233f5c54e4749b99" # tag r83, 26 Nov 2026
SKILL_DIR="moonbase/scripts"
FILES=(package-mission.sh parse-deploy-result.sh)

here="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(dirname "$here")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

drift=0
for file in "${FILES[@]}"; do
  url="https://raw.githubusercontent.com/$SKILL_REPO/$SKILL_COMMIT/$SKILL_DIR/$file"
  if ! curl -fsSL --retry 3 --max-time 60 -o "$work/$file" "$url"; then
    printf 'FAIL  could not download %s\n' "$url"
    exit 2
  fi
  if cmp -s "$work/$file" "$root/scripts/$file"; then
    printf 'ok    scripts/%s matches %s@%s\n' "$file" "$SKILL_REPO" "${SKILL_COMMIT:0:12}"
  else
    printf 'FAIL  scripts/%s differs from %s\n' "$file" "$url"
    diff -u "$work/$file" "$root/scripts/$file" | head -40 || true
    drift=1
  fi
done
exit "$drift"
