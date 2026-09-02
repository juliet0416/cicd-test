#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

FAKE_BIN="${WORK_DIR}/bin"
LOG_FILE="${WORK_DIR}/commands.log"
mkdir -p "${FAKE_BIN}"

cat > "${FAKE_BIN}/ossutil" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
printf 'ossutil' >> "${PROMOTE_TEST_LOG}"
printf ' %q' "$@" >> "${PROMOTE_TEST_LOG}"
printf '\n' >> "${PROMOTE_TEST_LOG}"
if [ "$1" = "cp" ] && [[ "$3" == oss://* ]] && [[ "$4" != oss://* ]]; then
    mkdir -p "$(dirname "$4")"
    if [[ "$3" == */updates-v2/*/latest_version.json ]]; then
        printf '%s\n' '{"schemaVersion":2,"releaseEpoch":0,"status":"ACTIVE","channel":"BETA","releases":[]}' > "$4"
    else
        printf 'installer\n' > "$4"
    fi
fi
BASH

for command in rclone ssh scp; do
    cat > "${FAKE_BIN}/${command}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "$(basename "$0")" >> "${PROMOTE_TEST_LOG}"
printf ' %q' "$@" >> "${PROMOTE_TEST_LOG}"
printf '\n' >> "${PROMOTE_TEST_LOG}"
if [ "$(basename "$0")" = "ssh" ] && printf '%s\n' "$*" | grep -Fq 'test -f '; then
    exit 1
fi
if [ "$(basename "$0")" = "ssh" ] \
        && [ "${PROMOTE_TEST_FAIL_LATEST_COPY:-false}" = "true" ] \
        && printf '%s\n' "$*" | grep -Fq '/latest/' \
        && printf '%s\n' "$*" | grep -Fq 'cp -f --'; then
    exit 1
fi
if [ "$(basename "$0")" = "scp" ] \
        && [ -n "${PROMOTE_TEST_SLOW_SCP_ONCE_FILE:-}" ] \
        && [ ! -e "${PROMOTE_TEST_SLOW_SCP_ONCE_FILE}" ]; then
    touch "${PROMOTE_TEST_SLOW_SCP_ONCE_FILE}"
    sleep 1
fi
if [ "${PROMOTE_TEST_DRAIN_STDIN:-false}" = "true" ]; then
    cat >/dev/null
fi
BASH
done
chmod +x "${FAKE_BIN}"/*
export PATH="${FAKE_BIN}:${PATH}"
export PROMOTE_TEST_LOG="${LOG_FILE}"

export CHAT2DB_PRODUCT=PRO
export CHAT2DB_RELEASE_ROOT=download
export CHAT2DB_PRODUCT_APP_NAME=Chat2DB-Pro
export CHAT2DB_RELEASE_VERSION=5.3.6-beta.3
export CHAT2DB_RELEASE_PROFILE=versioned-thin
export CHAT2DB_RELEASE_CHANNEL=BETA
export CHAT2DB_RELEASE_EPOCH=6
export CHAT2DB_ENTERPRISE_SHA=0123456789012345678901234567890123456789
export CHAT2DB_RELEASE_NOTES_URL=https://chat2db.ai/release-notes
export CHAT2DB_ENTERPRISE_ROOT="${WORK_DIR}/enterprise"
export CHAT2DB_UPDATE_ARTIFACT_ROOT="${WORK_DIR}/update-artifacts"
export CHAT2DB_PROMOTE_WORK_DIR="${WORK_DIR}/promote"
export CHAT2DB_UPLOAD_LATEST=false
export CHAT2DB_UPDATE_LATEST_VERSION_JSON=true
export CHAT2DB_UPDATE_KEY_ID=test-key
export CHAT2DB_UPDATE_PUBLIC_KEY_B64=test-public-key
export CHAT2DB_UPDATE_SIGNING_PRIVATE_KEY_B64=test-private-key
export BUCKET_NAME=test-bucket
export R2_REMOTE=test-r2:test-bucket
export DOWNLOAD_SERVER_HOST=download.example.com
export DOWNLOAD_SERVER_USER=release
export DOWNLOAD_SERVER_KEY="${WORK_DIR}/download-key"
export CHAT2DB_PROMOTION_LOG_INTERVAL_SECONDS=1
export CHAT2DB_DOWNLOAD_SERVER_PULL_FROM_OSS=false
export PROMOTE_TEST_DRAIN_STDIN=true
touch "${DOWNLOAD_SERVER_KEY}"

INVALID_OUTPUT="${WORK_DIR}/invalid-beta-output.log"
export CHAT2DB_UPLOAD_LATEST=true
if bash "${SCRIPT_DIR}/promote-desktop-release.sh" >"${INVALID_OUTPUT}" 2>&1; then
    echo 'beta promotion must reject upload_latest=true' >&2
    exit 1
fi
grep -Fq 'Beta releases must not publish download-server latest installers' "${INVALID_OUTPUT}"
export CHAT2DB_UPLOAD_LATEST=false

FAKE_ENTERPRISE_SCRIPTS="${CHAT2DB_ENTERPRISE_ROOT}/script/package"
mkdir -p "${FAKE_ENTERPRISE_SCRIPTS}"
cat > "${FAKE_ENTERPRISE_SCRIPTS}/generate_update_v2.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
test "$#" -eq 14
product_lower=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')
platform_lower=$(printf '%s' "$5" | tr '[:upper:]' '[:lower:]')
arch_lower=$(printf '%s' "$6" | tr '[:upper:]' '[:lower:]')
package_type_lower=$(printf '%s' "$7" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
mkdir -p "${10}"
case "$7" in
    MACOS_APP_ARCHIVE) extension=tar.gz ;;
    WINDOWS_EXE) extension=exe ;;
    LINUX_APPIMAGE) extension=AppImage ;;
    LINUX_DEB) extension=deb ;;
    LINUX_RPM) extension=rpm ;;
esac
cp "$8" "${10}/package-${product_lower}-${platform_lower}-${arch_lower}-${package_type_lower}.${extension}"
printf '{"schemaVersion":2,"releaseEpoch":%s,"status":"ACTIVE","product":"%s","channel":"%s","version":"%s","nativeVersion":"%s","platform":"%s","arch":"%s","updateScope":"FULL_PACKAGE","packageType":"%s","packageUrl":"%s/package-%s-%s-%s-%s.%s","signature":"test"}\n' \
    "${12}" "$3" "$4" "$1" "$2" "$5" "$6" "$7" \
    "${11}" "${product_lower}" "${platform_lower}" "${arch_lower}" "${package_type_lower}" "${extension}" \
    > "${10}/manifest-${product_lower}-${platform_lower}-${arch_lower}-${package_type_lower}.json"
BASH
cat > "${FAKE_ENTERPRISE_SCRIPTS}/desktop_layout.sh" <<'BASH'
#!/usr/bin/env bash
chat2db_jpackage_version() { printf '5.3.601\n'; }
BASH
cat > "${FAKE_ENTERPRISE_SCRIPTS}/generate_update_index_v2.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
test "$#" -eq 13
channel="$1"
epoch="$2"
output="$4"
jq -cn --arg channel "${channel}" --argjson epoch "${epoch}" '{schemaVersion:2,releaseEpoch:$epoch,status:"ACTIVE",channel:$channel,releases:[]}' > "${output}"
BASH
chmod +x "${FAKE_ENTERPRISE_SCRIPTS}"/*.sh

for target in macos-x64 macos-arm64 windows-x64 linux-x64 linux-arm64; do
    package_root="${WORK_DIR}/package-${target}"
    artifact_root="${CHAT2DB_UPDATE_ARTIFACT_ROOT}/full-package-pro-${target}"
    mkdir -p "${package_root}/package" "${artifact_root}"
    printf 'full-package\n' > "${package_root}/package/version.txt"
    tar -C "${package_root}" -czf "${artifact_root}/full-package-${target}.tar.gz" package
done

OUTPUT_LOG="${WORK_DIR}/beta-output.log"
bash "${SCRIPT_DIR}/promote-desktop-release.sh" > "${OUTPUT_LOG}"
grep -Fq 'download/updates-v2/beta/5.3.6-beta.3/release-index.json' "${LOG_FILE}"
grep -Fq 'download/updates-v2/beta/latest_version.json' "${LOG_FILE}"
if grep -Eq 'phase=updates-v2.*provider=download-server' "${OUTPUT_LOG}"; then
    echo 'beta promotion must not publish versioned resources to download server' >&2
    exit 1
fi

: > "${LOG_FILE}"
export CHAT2DB_RELEASE_VERSION=5.3.6
export CHAT2DB_RELEASE_CHANNEL=STABLE
export CHAT2DB_RELEASE_EPOCH=7
export CHAT2DB_UPLOAD_LATEST=false
rm -rf "${CHAT2DB_PROMOTE_WORK_DIR}"
OUTPUT_LOG="${WORK_DIR}/stable-output.log"
bash "${SCRIPT_DIR}/promote-desktop-release.sh" > "${OUTPUT_LOG}"
grep -Fq 'download/updates-v2/stable/5.3.6/release-index.json' "${LOG_FILE}"
grep -Fq 'provider=download-server stage=provider-copy' "${OUTPUT_LOG}"
grep -Fq 'cp -f --' "${SCRIPT_DIR}/promote-desktop-release.sh"

echo "desktop promotion tests passed"
