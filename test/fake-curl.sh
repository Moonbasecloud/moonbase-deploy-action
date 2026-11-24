#!/usr/bin/env bash
# A stand-in for curl, used by test/run.sh only. It never touches the network.
# It records its arguments and the header it was given on stdin, copies a
# fixture to the -o file and prints "<status> <content-type>" like -w does.
set -euo pipefail
printf '%s\n' "$@" > "$FAKE_CURL_RECORD.argv"
cat > "$FAKE_CURL_RECORD.stdin"
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cp "$FAKE_CURL_FIXTURE" "$out"
printf '%s %s' "$FAKE_CURL_STATUS" "$FAKE_CURL_TYPE"
exit "${FAKE_CURL_EXIT:-0}"
