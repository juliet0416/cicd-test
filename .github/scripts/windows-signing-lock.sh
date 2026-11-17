#!/bin/sh
set -eu

sign_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
exec /usr/bin/lockf -k -t 600 \
  "${sign_dir}/token.lock" \
  "${sign_dir}/jsign-impl.sh" "$@"
