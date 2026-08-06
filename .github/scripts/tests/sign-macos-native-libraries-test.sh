#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SIGNER="${SCRIPT_DIR}/../sign-macos-native-libraries.sh"
EXTRA_JAR="${1:-}"
TEST_ROOT=$(mktemp -d)
MOCK_BIN="${TEST_ROOT}/bin"
MOCK_CODESIGN_LOG="${TEST_ROOT}/codesign.log"
MOCK_CODESIGN_HANG_STATE="${TEST_ROOT}/codesign-hang-once"
MOCK_FILE_LOG="${TEST_ROOT}/file.log"
IDENTITY="Developer ID Application: Test Signing (TESTTEAM)"
EXPECTED_SIGNING_CALLS=4

cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  echo "[error] $1" >&2
  exit 1
}

make_macho() {
  local output_file="$1"
  printf '\xcf\xfa\xed\xfe\x0c\x00\x00\x01\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' > "${output_file}"
}

mkdir -p \
  "${MOCK_BIN}" \
  "${TEST_ROOT}/input/lib" \
  "${TEST_ROOT}/outer/native" \
  "${TEST_ROOT}/outer/plain" \
  "${TEST_ROOT}/outer/dependencies" \
  "${TEST_ROOT}/nested/bin"

cat > "${MOCK_BIN}/security" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$*" = "find-identity -v -p codesigning" ]; then
  echo '  1) 0123456789ABCDEF "Developer ID Application: Test Signing (TESTTEAM)"'
  echo '     1 valid identities found'
  exit 0
fi
echo "unexpected security arguments: $*" >&2
exit 1
EOF

cat > "${MOCK_BIN}/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --force)
    target_file="${!#}"
    if [[ "${target_file}" == *"libtest.dylib" ]] \
      && [ ! -f "${MOCK_CODESIGN_HANG_STATE}" ]; then
      touch "${MOCK_CODESIGN_HANG_STATE}"
      sleep 5
    fi
    printf '%s\n' "$*" >> "${MOCK_CODESIGN_LOG}"
    printf '\nMOCK-CODESIGNED-RUNTIME\n' >> "${target_file}"
    ;;
  --verify)
    ;;
  --display)
    target_file="${!#}"
    echo "Executable=${target_file}" >&2
    echo 'CodeDirectory v=20500 size=256 flags=0x10000(runtime)' >&2
    ;;
  *)
    echo "unexpected codesign arguments: $*" >&2
    exit 1
    ;;
esac
EOF

cat > "${MOCK_BIN}/file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'call\n' >> "${MOCK_FILE_LOG}"
exec /usr/bin/file "$@"
EOF
chmod +x "${MOCK_BIN}/security" "${MOCK_BIN}/codesign" "${MOCK_BIN}/file"

make_macho "${TEST_ROOT}/outer/native/libtest.dylib"
make_macho "${TEST_ROOT}/outer/native/pty4j-unix-spawn-helper"
make_macho "${TEST_ROOT}/outer/native/with spaces (helper)"
make_macho "${TEST_ROOT}/nested/bin/nested-helper"
chmod +x \
  "${TEST_ROOT}/outer/native/pty4j-unix-spawn-helper" \
  "${TEST_ROOT}/nested/bin/nested-helper"

index=0
while [ "${index}" -lt 2000 ]; do
  printf 'plain text %s\n' "${index}" > "${TEST_ROOT}/outer/plain/file-${index}.txt"
  index=$((index + 1))
done

if /usr/bin/file -b /bin/ls | grep -q 'Mach-O'; then
  cp /bin/ls "${TEST_ROOT}/outer/native/universal-helper"
  EXPECTED_SIGNING_CALLS=$((EXPECTED_SIGNING_CALLS + 1))
fi

(cd "${TEST_ROOT}/nested" && zip -q -r "${TEST_ROOT}/outer/dependencies/nested.jar" .)
(cd "${TEST_ROOT}/outer" && zip -q -r "${TEST_ROOT}/input/lib/fixture.jar" .)
if [ -n "${EXTRA_JAR}" ]; then
  [ -f "${EXTRA_JAR}" ] || fail "extra JAR does not exist: ${EXTRA_JAR}"
  cp "${EXTRA_JAR}" "${TEST_ROOT}/input/lib/extra.jar"
  EXPECTED_SIGNING_CALLS=$((EXPECTED_SIGNING_CALLS + 2))
fi

PATH="${MOCK_BIN}:${PATH}" \
MAC_SIGNING_IDENTITY="${IDENTITY}" \
MAC_SIGN_COMMAND_TIMEOUT_SECONDS=1 \
MAC_SIGN_RETRY_DELAY_SECONDS=0 \
MOCK_CODESIGN_LOG="${MOCK_CODESIGN_LOG}" \
MOCK_CODESIGN_HANG_STATE="${MOCK_CODESIGN_HANG_STATE}" \
MOCK_FILE_LOG="${MOCK_FILE_LOG}" \
  bash "${SIGNER}" "${TEST_ROOT}/input"

signed_count=$(wc -l < "${MOCK_CODESIGN_LOG}" | tr -d '[:space:]')
[ "${signed_count}" -eq "${EXPECTED_SIGNING_CALLS}" ] \
  || fail "expected ${EXPECTED_SIGNING_CALLS} signing calls, got ${signed_count}"
for expected in libtest.dylib pty4j-unix-spawn-helper 'with spaces (helper)' nested-helper; do
  grep -F -- "${expected}" "${MOCK_CODESIGN_LOG}" >/dev/null \
    || fail "missing signing call for ${expected}"
done
[ -f "${MOCK_CODESIGN_HANG_STATE}" ] \
  || fail "hung codesign fixture did not exercise the timeout path"
runtime_signing_count=$(grep -F -c -- '--options runtime --timestamp' "${MOCK_CODESIGN_LOG}")
[ "${runtime_signing_count}" -eq "${EXPECTED_SIGNING_CALLS}" ] \
  || fail "every signing call must request hardened runtime and a timestamp"
if grep -F -- 'file-0.txt' "${MOCK_CODESIGN_LOG}" >/dev/null; then
  fail "plain text file was selected for signing"
fi

file_invocations=$(wc -l < "${MOCK_FILE_LOG}" | tr -d '[:space:]')
[ "${file_invocations}" -lt 50 ] \
  || fail "file command was not batched: ${file_invocations} invocations"

mkdir -p "${TEST_ROOT}/repacked" "${TEST_ROOT}/nested-repacked"
unzip -q "${TEST_ROOT}/input/lib/fixture.jar" -d "${TEST_ROOT}/repacked"
unzip -q "${TEST_ROOT}/repacked/dependencies/nested.jar" -d "${TEST_ROOT}/nested-repacked"
[ -x "${TEST_ROOT}/repacked/native/pty4j-unix-spawn-helper" ] \
  || fail "extensionless helper lost its executable mode"
[ -x "${TEST_ROOT}/nested-repacked/bin/nested-helper" ] \
  || fail "nested helper lost its executable mode"
[ ! -x "${TEST_ROOT}/repacked/native/libtest.dylib" ] \
  || fail "non-executable dylib gained an executable mode"

if [ -n "${EXTRA_JAR}" ]; then
  mkdir -p "${TEST_ROOT}/extra-repacked"
  unzip -q "${TEST_ROOT}/input/lib/extra.jar" -d "${TEST_ROOT}/extra-repacked"
  extra_helper="${TEST_ROOT}/extra-repacked/resources/com/pty4j/native/darwin/pty4j-unix-spawn-helper"
  extra_dylib="${TEST_ROOT}/extra-repacked/resources/com/pty4j/native/darwin/libpty.dylib"
  [ -x "${extra_helper}" ] || fail "real pty4j helper lost its executable mode"
  [ ! -x "${extra_dylib}" ] || fail "real pty4j dylib gained an executable mode"
  grep -a -F -- 'MOCK-CODESIGNED-RUNTIME' "${extra_helper}" >/dev/null \
    || fail "real pty4j helper was not signed"
  grep -a -F -- 'MOCK-CODESIGNED-RUNTIME' "${extra_dylib}" >/dev/null \
    || fail "real pty4j dylib was not signed"
fi

echo "[check] batched Mach-O detection signed ${EXPECTED_SIGNING_CALLS} payloads with ${file_invocations} file process(es)"
