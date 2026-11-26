#!/usr/bin/env bash
# moonbase deploy action: validate the inputs, package the repository with the
# shipped packager, upload it to the documented deploy endpoint and report the
# result with the shipped parser.
#
# It uses one documented call and nothing else:
#   POST https://upload.moonbase.cloud/api/projects/upload/stream
#   (the upload host from the API reference: app.moonbase.cloud sits behind a
#   proxy whose request size cap is below the larger plans' deploy sizes)
#   form fields: file, redeployProjectId | name (+ displayName)
#   Authorization: Bearer <key>, sent to curl on stdin, never in argv.
#
# Exit: 0 live   1 failed, refused or bad input   2 unknown (check status
#       before uploading again)   3 deployed, app not ready   4 deployed, the
#       page's files do not load.
set -euo pipefail
set +x

readonly DEPLOY_URL="https://upload.moonbase.cloud/api/projects/upload/stream"
readonly USER_AGENT="moonbase-deploy-action/1.0"
# The API reference says to allow at least 10 minutes for a stream.
readonly MAX_SECONDS=1200

fail() { printf '::error::%s\n' "$*"; exit 1; }

set_output() {
  # Values come from the parser, which already strips control characters.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi
}

api_key="${INPUT_API_KEY:-}"
mission_id="${INPUT_MISSION_ID:-}"
name="${INPUT_NAME:-}"
display_name="${INPUT_DISPLAY_NAME:-}"
workdir="${INPUT_WORKING_DIRECTORY:-.}"
allow_build_output="${INPUT_ALLOW_BUILD_OUTPUT:-false}"
script_dir="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# --- 1. The key: mask it before anything else can print, then check its shape.
# A key with a line break is refused without masking: a mask covers one line,
# and a line break could also add a header to the request.
case "$api_key" in
  "") fail "api-key is empty. Add your key as the repository secret MOONBASE_API_KEY and pass it with: api-key: \${{ secrets.MOONBASE_API_KEY }}" ;;
  *$'\n'*|*$'\r'*) fail "api-key contains a line break. Save the key again as a single line." ;;
esac
printf '::add-mask::%s\n' "$api_key"
if [[ ! "$api_key" =~ ^mb_live_[A-Za-z0-9_.-]+$ ]]; then
  fail "api-key does not look like a moonbase API key. A key starts with mb_live_ and has no spaces."
fi

# --- 2. The target: an existing project, or the address of a new one.
if [ -n "$mission_id" ] && [ -n "$name" ]; then
  fail "Give mission-id (ship a new version) or name (create a new project), not both."
fi
if [ -z "$mission_id" ] && [ -z "$name" ]; then
  fail "mission-id is empty. Find the project id in the project's link (https://app.moonbase.cloud/missions/<id>) and pass it, or pass name to create a new project."
fi
if [ -n "$mission_id" ] && [[ ! "$mission_id" =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then
  fail "mission-id may hold only letters, digits, '-' and '_'."
fi
if [ -n "$name" ] && [[ ! "$name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  fail "name may hold only lowercase letters, digits and '-', and must start and end with a letter or digit."
fi
if [ -n "$display_name" ]; then
  [ -n "$name" ] || fail "display-name applies to a new project only. Use it together with name."
  if [[ "$display_name" =~ [[:cntrl:]] ]] || [ "${#display_name}" -gt 100 ]; then
    fail "display-name must be one line of at most 100 characters."
  fi
fi
case "$allow_build_output" in
  true|false) : ;;
  *) fail "allow-build-output must be true or false." ;;
esac

# --- 3. Tools, helpers and the folder, all checked before any upload.
for tool in bash jq zip unzip curl git; do
  command -v "$tool" >/dev/null 2>&1 || fail "Missing tool on the runner: $tool"
done
for helper in package-mission.sh parse-deploy-result.sh; do
  [ -f "$script_dir/$helper" ] || fail "Missing helper in the action: scripts/$helper"
done
case "$workdir" in
  /*|..|../*|*/..|*/../*) fail "working-directory must be a folder inside the repository." ;;
esac
[ -d "$workdir" ] || fail "working-directory does not exist: $workdir"
cd "$workdir"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail "The folder is not a git checkout. Run actions/checkout before this action."

# --- 4. Package: the shipped packager builds a fresh archive from the
# git-tracked files and refuses secrets, node_modules, databases and logs.
log=""; archive=""; report=""
cleanup() { rm -f -- ${log:+"$log"} ${archive:+"$archive"} ${report:+"$report"}; }
trap cleanup EXIT

packager_args=()
if [ "$allow_build_output" = "true" ]; then packager_args+=(--allow-build-output); fi
echo "Packaging the project"
archive="$(bash "$script_dir/package-mission.sh" ${packager_args[@]+"${packager_args[@]}"})" \
  || fail "Packaging failed. See the messages above."
{ [ -n "$archive" ] && [ -f "$archive" ] && [ -s "$archive" ]; } \
  || fail "The packager produced no archive."

# --- 5. Upload. The response stream stays in a private file that is deleted
# on exit; only sanitised, structured fields are printed.
log="$(mktemp)"; chmod 600 "$log"
report="$(mktemp)"; chmod 600 "$report"

form=(-F "file=@${archive}")
if [ -n "$mission_id" ]; then
  form+=(--form-string "redeployProjectId=${mission_id}")
else
  form+=(--form-string "name=${name}")
  if [ -n "$display_name" ]; then form+=(--form-string "displayName=${display_name}"); fi
fi

echo "Uploading to moonbase and following the deploy"
curl_rc=0
meta="$(printf 'Authorization: Bearer %s\n' "$api_key" | curl -sSN -X POST "$DEPLOY_URL" \
  --header @- \
  -H "User-Agent: ${USER_AGENT}" \
  --max-time "$MAX_SECONDS" \
  "${form[@]}" \
  -o "$log" -w '%{http_code} %{content_type}')" || curl_rc=$?

# --- 6. Report with the shipped parser. It passes only on one complete final
# `done` with a usable live address.
rc=0
bash "$script_dir/parse-deploy-result.sh" "$log" "${meta%% *}" "${meta#* }" "$curl_rc" > "$report" || rc=$?
cat "$report"

url="$(sed -n -E 's/^(Live|Deployed, NOT READY): (https:\/\/[^[:space:]]+)$/\2/p' "$report" | head -n 1)"
project_id="$(sed -n -E 's/^project_id: ([^[:space:]]+)$/\1/p' "$report" | head -n 1)"
set_output "url" "$url"
set_output "project-id" "$project_id"

case "$rc" in
  0) outcome="live" ;;
  3) outcome="not-ready" ;;
  4) outcome="assets-not-loading" ;;
  2) outcome="unknown" ;;
  *) outcome="failed" ;;
esac
set_output "outcome" "$outcome"

case "$rc" in
  0) echo "Deployed and live." ;;
  3) printf '::error::%s\n' "Deployed, but the app reports it is not ready. Do not run the upload again: check the project, finish its configuration, and re-run only after a change." ;;
  4) printf '::error::%s\n' "Deployed, but the page's files do not load. Waiting will not fix this: change the project and push again." ;;
  2) printf '::error::%s\n' "The outcome is unknown. Check the project's status before running the deploy again, so a deploy that landed is not uploaded twice." ;;
  *) printf '::error::%s\n' "The deploy failed. See the message above." ;;
esac
exit "$rc"
