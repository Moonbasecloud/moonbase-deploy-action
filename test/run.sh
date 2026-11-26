#!/usr/bin/env bash
# Local tests for the action. No network and no real key: curl is replaced by
# test/fake-curl.sh, which serves recorded responses.
#   bash test/run.sh
set -uo pipefail

here="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(dirname "$here")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; failed=0
ok()  { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL  %s\n' "$1"; }

# A placeholder in the documented shape (mb_live_ + 32 characters), built here so no key-like text sits in the repository.
KEY="mb_live_$(printf "%032d" 0)"

# A small git project to deploy.
proj="$work/proj"
mkdir -p "$proj/site" "$work/bin"
printf '<!doctype html><title>t</title>\n' > "$proj/index.html"
printf '<!doctype html><title>s</title>\n' > "$proj/site/index.html"
git -C "$proj" init -q
git -C "$proj" add -A
git -C "$proj" -c user.name=t -c user.email=t@example.invalid commit -qm init

cp "$here/fake-curl.sh" "$work/bin/curl"; chmod +x "$work/bin/curl"

# run <name> <expected exit> <fixture> <status> <content-type> [VAR=value ...]
run() {
  local name="$1" want="$2" fixture="$3" status="$4" type="$5"; shift 5
  out="$work/$name.out"; outputs="$work/$name.outputs"; record="$work/$name.curl"
  : > "$outputs"
  (
    cd "$proj" || exit 99
    env -i PATH="$work/bin:$PATH" HOME="$work" \
      GITHUB_OUTPUT="$outputs" \
      FAKE_CURL_RECORD="$record" FAKE_CURL_FIXTURE="$here/fixtures/$fixture" \
      FAKE_CURL_STATUS="$status" FAKE_CURL_TYPE="$type" \
      INPUT_API_KEY="$KEY" INPUT_MISSION_ID="proj_abc123" \
      "$@" bash "$root/scripts/deploy.sh"
  ) > "$out" 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then ok "$name: exit $got"; else bad "$name: exit $got, wanted $want"; sed 's/^/      /' "$out"; fi
}
has()    { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3"; fi; }
hasnt()  { if grep -qF -- "$2" "$1"; then bad "$3"; else ok "$3"; fi; }
no_upload() { if [ -e "$work/$1.curl.argv" ]; then bad "$1: nothing uploaded"; else ok "$1: nothing uploaded"; fi; }

# --- a live deploy
run live 0 done.sse 200 text/event-stream
has   "$work/live.outputs" "url=https://my-app.moonbase.host" "live: url output"
has   "$work/live.outputs" "project-id=proj_abc123" "live: project-id output"
has   "$work/live.outputs" "outcome=live" "live: outcome output"
has   "$work/live.out" "::add-mask::$KEY" "live: key is masked"
if [ "$(grep -cF -- "$KEY" "$work/live.out")" -eq 1 ]; then ok "live: key appears only in the mask command"; else bad "live: key appears only in the mask command"; fi
hasnt "$work/live.curl.argv" "$KEY" "live: key is not in curl's arguments"
has   "$work/live.curl.stdin" "Authorization: Bearer $KEY" "live: key goes to curl on stdin"
has   "$work/live.curl.argv" "https://upload.moonbase.cloud/api/projects/upload/stream" "live: documented endpoint"
has   "$work/live.curl.argv" "redeployProjectId=proj_abc123" "live: redeployProjectId field"
has   "$work/live.curl.argv" "User-Agent: moonbase-deploy-action/1.0" "live: User-Agent sent"
if ls "$proj"/mission-*.zip >/dev/null 2>&1; then bad "live: archive removed afterwards"; else ok "live: archive removed afterwards"; fi

# --- a new mission
run create 0 done.sse 200 text/event-stream INPUT_MISSION_ID= INPUT_NAME=my-app "INPUT_DISPLAY_NAME=My App"
has   "$work/create.curl.argv" "name=my-app" "create: name field"
has   "$work/create.curl.argv" "displayName=My App" "create: displayName field"
hasnt "$work/create.curl.argv" "redeployProjectId" "create: no redeployProjectId"

# --- a sub-folder
run subdir 0 done.sse 200 text/event-stream INPUT_WORKING_DIRECTORY=site

# --- outcomes that must fail the job
run not-ready 3 not-ready.sse 200 text/event-stream
has "$work/not-ready.outputs" "outcome=not-ready" "not-ready: outcome output"
has "$work/not-ready.outputs" "url=https://my-app.moonbase.host" "not-ready: url output"
run build-error 1 error.sse 200 text/event-stream
has "$work/build-error.out" "TRK-TEST1" "build-error: reference shown"
has "$work/build-error.outputs" "outcome=failed" "build-error: outcome output"
run truncated 2 truncated.sse 200 text/event-stream
has "$work/truncated.outputs" "outcome=unknown" "truncated: outcome output"
run refused 1 refused.json 401 application/json
run transfer-failed 2 done.sse 200 text/event-stream FAKE_CURL_EXIT=18

# --- bad input: refused before any upload
run no-key 1 done.sse 200 text/event-stream INPUT_API_KEY=;                       no_upload no-key
run bad-key 1 done.sse 200 text/event-stream INPUT_API_KEY=not-a-moonbase-key;    no_upload bad-key
has   "$work/bad-key.out" "::error::api-key does not look like a moonbase API key" "bad-key: says what is wrong"
run key-with-space 1 done.sse 200 text/event-stream "INPUT_API_KEY=mb_live_abc def"; no_upload key-with-space
run key-with-newline 1 done.sse 200 text/event-stream "INPUT_API_KEY=mb_live_abc"$'\n'"X-Injected: 1"; no_upload key-with-newline
hasnt "$work/key-with-newline.out" "X-Injected" "key-with-newline: value not printed"
run no-target 1 done.sse 200 text/event-stream INPUT_MISSION_ID=;                 no_upload no-target
run both-targets 1 done.sse 200 text/event-stream INPUT_NAME=my-app;              no_upload both-targets
run bad-mission-id 1 done.sse 200 text/event-stream "INPUT_MISSION_ID=@/etc/passwd"; no_upload bad-mission-id
run bad-name 1 done.sse 200 text/event-stream INPUT_MISSION_ID= "INPUT_NAME=My App"; no_upload bad-name
run display-without-name 1 done.sse 200 text/event-stream "INPUT_DISPLAY_NAME=X";  no_upload display-without-name
run bad-flag 1 done.sse 200 text/event-stream INPUT_ALLOW_BUILD_OUTPUT=yes;        no_upload bad-flag
run missing-dir 1 done.sse 200 text/event-stream INPUT_WORKING_DIRECTORY=nope;     no_upload missing-dir
run outside-dir 1 done.sse 200 text/event-stream INPUT_WORKING_DIRECTORY=../..;    no_upload outside-dir

# --- a tracked secret file is refused by the packager, before any upload
printf 'TOKEN=x\n' > "$proj/.env"
git -C "$proj" add -f .env
run tracked-env 1 done.sse 200 text/event-stream; no_upload tracked-env
git -C "$proj" rm -q --cached .env; rm -f "$proj/.env"

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
