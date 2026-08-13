#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
WORK_DIR=$(mktemp -d)
cleanup() { rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

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
        printf '%s\n' '{"schemaVersion":2,"releaseEpoch":0,"status":"ACTIVE","channel":"BETA","releases":[{"version":"5.3.3","platform":"MACOS","arch":"ARM64","packageType":"MACOS_APP_ARCHIVE","manifestUrl":"https://cdn.example.com/old.json"}]}' > "$4"
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
if [ "$(basename "$0")" = "scp" ] \
        && [ -n "${PROMOTE_TEST_SLOW_SCP_ONCE_FILE:-}" ] \
        && [ ! -e "${PROMOTE_TEST_SLOW_SCP_ONCE_FILE}" ]; then
    touch "${PROMOTE_TEST_SLOW_SCP_ONCE_FILE}"
    sleep 2
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
export CHAT2DB_RELEASE_VERSION=5.3.3
export CHAT2DB_RELEASE_PROFILE=bridge-fat
export CHAT2DB_RELEASE_CHANNEL=STABLE
export CHAT2DB_RELEASE_EPOCH=0
export CHAT2DB_DATA_SCHEMA_VERSION=0
export CHAT2DB_ROLLBACK_COMPATIBLE_FROM=5.3.3
export CHAT2DB_ENTERPRISE_SHA=0123456789012345678901234567890123456789
export CHAT2DB_RELEASE_NOTES_URL=https://chat2db.ai/release-notes
export CHAT2DB_ENTERPRISE_ROOT="${WORK_DIR}/enterprise"
export CHAT2DB_UPDATE_ARTIFACT_ROOT="${WORK_DIR}/update-artifacts"
export CHAT2DB_PROMOTE_WORK_DIR="${WORK_DIR}/promote"
export CHAT2DB_UPLOAD_LATEST=false
export CHAT2DB_UPDATE_LATEST_VERSION_JSON=true
export CHAT2DB_UPDATE_KEY_ID=test-key
export CHAT2DB_UPDATE_PUBLIC_KEY_B64=test-public-key
export BUCKET_NAME=test-bucket
export R2_REMOTE=test-r2:test-bucket
export DOWNLOAD_SERVER_HOST=download.example.com
export DOWNLOAD_SERVER_USER=release
export DOWNLOAD_SERVER_KEY="${WORK_DIR}/download-key"
export GITHUB_RUN_ID=123
export GITHUB_RUN_ATTEMPT=1
export CHAT2DB_PROMOTION_LOG_INTERVAL_SECONDS=1
export CHAT2DB_DOWNLOAD_SERVER_PULL_FROM_OSS=true
touch "${DOWNLOAD_SERVER_KEY}"

BRIDGE_DIR="${WORK_DIR}/bridge"
BRIDGE_ARTIFACT_DIR="${CHAT2DB_UPDATE_ARTIFACT_ROOT}/bridge-update-pro"
BRIDGE_OUTPUT_LOG="${WORK_DIR}/bridge-output.log"
mkdir -p "${BRIDGE_DIR}" "${BRIDGE_ARTIFACT_DIR}"
for file in version.json build-provenance.json chat2db-enterprise.jar chat2db-updater.jar dist.zip; do
    printf '%s\n' "${file}" > "${BRIDGE_DIR}/${file}"
done
tar -C "${BRIDGE_DIR}" -czf "${BRIDGE_ARTIFACT_DIR}/bridge-update.tar.gz" .

bash "${SCRIPT_DIR}/promote-desktop-release.sh" > "${BRIDGE_OUTPUT_LOG}"
grep -Fq 'download/updates/5.3.3/chat2db-updater.jar' "${LOG_FILE}"
grep -Fq 'download/updates/latest_version.json' "${LOG_FILE}"
tail -n 1 "${LOG_FILE}" | grep -Fq 'oss://test-bucket/download/updates/latest_version.json'
grep -Fq 'provider=download-server strategy=oss-pull' "${BRIDGE_OUTPUT_LOG}"
grep -Fq 'event=transfer_start phase=bridge-update object=6/6 provider=download-server stage=scp' "${BRIDGE_OUTPUT_LOG}"
grep -Fq 'event=download_server_capacity target=release@download.example.com' "${BRIDGE_OUTPUT_LOG}"

: > "${LOG_FILE}"
export CHAT2DB_UPLOAD_LATEST=true
export CHAT2DB_UPDATE_LATEST_VERSION_JSON=false
rm -rf "${CHAT2DB_PROMOTE_WORK_DIR}"
bash "${SCRIPT_DIR}/promote-desktop-release.sh"
grep -Fq 'download/latest/Chat2DB-Pro-arm64-latest.dmg' "${LOG_FILE}"
grep -Fq 'download/latest/linux/x86_64/Chat2DB-Pro-5.3.3-x86_64.AppImage' "${LOG_FILE}"
grep -Fq 'download/latest/linux/arm64/Chat2DB-Pro-5.3.3-aarch64.rpm' "${LOG_FILE}"

FAKE_ENTERPRISE_SCRIPTS="${CHAT2DB_ENTERPRISE_ROOT}/script/package"
mkdir -p "${FAKE_ENTERPRISE_SCRIPTS}"
cat > "${FAKE_ENTERPRISE_SCRIPTS}/generate_update_v2.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
product_lower=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
platform_lower=$(printf '%s' "$4" | tr '[:upper:]' '[:lower:]')
arch_lower=$(printf '%s' "$5" | tr '[:upper:]' '[:lower:]')
package_type_lower=$(printf '%s' "$6" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
mkdir -p "$9"
case "$6" in
    MACOS_APP_ARCHIVE) extension=tar.gz ;;
    WINDOWS_EXE) extension=exe ;;
    LINUX_APPIMAGE) extension=AppImage ;;
    LINUX_DEB) extension=deb ;;
    LINUX_RPM) extension=rpm ;;
esac
printf 'full-package\n' > "$9/package-${product_lower}-${platform_lower}-${arch_lower}-${package_type_lower}.${extension}"
printf '{"schemaVersion":2,"releaseEpoch":%s,"status":"ACTIVE","product":"%s","channel":"%s","version":"%s","platform":"%s","arch":"%s","updateScope":"FULL_PACKAGE","packageType":"%s","signature":"test"}\n' \
    "${11}" "$2" "$3" "$1" "$4" "$5" "$6" \
    > "$9/manifest-${product_lower}-${platform_lower}-${arch_lower}-${package_type_lower}.json"
BASH
cat > "${FAKE_ENTERPRISE_SCRIPTS}/generate_update_index_v2.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
test "$#" -eq 13
test -s "${CHAT2DB_PREVIOUS_UPDATE_INDEX}"
test "$(jq '.releases | length' "${CHAT2DB_PREVIOUS_UPDATE_INDEX}")" -eq 1
printf '{"schemaVersion":2,"releaseEpoch":%s,"status":"ACTIVE","channel":"%s","releases":[{"version":"5.3.3"}]}\n' \
    "$2" "$1" > "$4"
BASH
chmod +x "${FAKE_ENTERPRISE_SCRIPTS}"/*.sh

for target in macos-x64 macos-arm64 windows-x64 linux-x64 linux-arm64; do
    package_root="${WORK_DIR}/package-${target}"
    artifact_root="${CHAT2DB_UPDATE_ARTIFACT_ROOT}/full-package-pro-${target}"
    mkdir -p "${package_root}/package" "${artifact_root}"
    printf 'full-package\n' > "${package_root}/package/version.txt"
    tar -C "${package_root}" -czf "${artifact_root}/full-package-${target}.tar.gz" package
done

: > "${LOG_FILE}"
PROMOTION_OUTPUT_LOG="${WORK_DIR}/promotion-output.log"
export PROMOTE_TEST_SLOW_SCP_ONCE_FILE="${WORK_DIR}/slow-scp-once"
export CHAT2DB_DOWNLOAD_SERVER_PULL_FROM_OSS=false
export CHAT2DB_RELEASE_VERSION=5.3.4-beta.1
export CHAT2DB_RELEASE_PROFILE=versioned-thin
export CHAT2DB_RELEASE_CHANNEL=BETA
export CHAT2DB_RELEASE_EPOCH=1
export CHAT2DB_UPLOAD_LATEST=false
export CHAT2DB_UPDATE_LATEST_VERSION_JSON=true
export CHAT2DB_UPDATE_SIGNING_PRIVATE_KEY_B64=test-private-key
export PROMOTE_TEST_DRAIN_STDIN=true
rm -rf "${CHAT2DB_PROMOTE_WORK_DIR}"
bash "${SCRIPT_DIR}/promote-desktop-release.sh" > "${PROMOTION_OUTPUT_LOG}"
grep -Fq 'download/updates-v2/beta/5.3.4-beta.1/package-pro-macos-arm64-macos-app-archive.tar.gz' "${LOG_FILE}"
grep -Fq 'download/updates-v2/beta/5.3.4-beta.1/package-pro-linux-arm64-linux-appimage.AppImage' "${LOG_FILE}"
grep -Fq 'download/updates-v2/beta/5.3.4-beta.1/release-index.json' "${LOG_FILE}"
grep -Fq 'download/updates-v2/beta/latest_version.json' "${LOG_FILE}"
test "$(grep -Ec '^ossutil cp -f .*/manifest-pro-.* oss://test-bucket/download/updates-v2/beta/5\.3\.4-beta\.1/manifest-pro-' "${LOG_FILE}")" -eq 9
test "$(grep -Ec '^ossutil cp -f .*/package-pro-.* oss://test-bucket/download/updates-v2/beta/5\.3\.4-beta\.1/package-pro-' "${LOG_FILE}")" -eq 9
test "$(grep -Ec '^ossutil cp -f .*/release-index\.json oss://test-bucket/download/updates-v2/beta/5\.3\.4-beta\.1/release-index\.json$' "${LOG_FILE}")" -eq 1
tail -n 1 "${LOG_FILE}" | grep -Fq 'oss://test-bucket/download/updates-v2/beta/latest_version.json'
grep -Fq 'event=promotion_start product=PRO version=5.3.4-beta.1 profile=versioned-thin channel=BETA' "${PROMOTION_OUTPUT_LOG}"
grep -Fq 'event=phase_start phase=updates-v2 objects=20' "${PROMOTION_OUTPUT_LOG}"
grep -Fq 'event=transfer_start phase=updates-v2 object=1/20 provider=aliyun-oss stage=upload' "${PROMOTION_OUTPUT_LOG}"
grep -Fq 'provider=cloudflare-r2 stage=upload' "${PROMOTION_OUTPUT_LOG}"
grep -Fq 'provider=download-server stage=scp' "${PROMOTION_OUTPUT_LOG}"
grep -Fq 'event=transfer_progress phase=updates-v2 object=1/20 provider=download-server stage=scp' "${PROMOTION_OUTPUT_LOG}"
grep -Fq 'uploaded_bytes=0 size_bytes=' "${PROMOTION_OUTPUT_LOG}"
grep -Fq 'event=phase_complete phase=updates-v2 objects=20/20' "${PROMOTION_OUTPUT_LOG}"
grep -Fq 'event=promotion_complete product=PRO version=5.3.4-beta.1' "${PROMOTION_OUTPUT_LOG}"

: > "${LOG_FILE}"
export CHAT2DB_RELEASE_VERSION=5.3.4
export CHAT2DB_RELEASE_PROFILE=bridge-fat
export CHAT2DB_RELEASE_CHANNEL=STABLE
export CHAT2DB_RELEASE_EPOCH=1
export CHAT2DB_ROLLBACK_COMPATIBLE_FROM=5.3.3
export CHAT2DB_UPDATE_LATEST_VERSION_JSON=false
rm -rf "${CHAT2DB_PROMOTE_WORK_DIR}"
bash "${SCRIPT_DIR}/promote-desktop-release.sh" >/dev/null
grep -Fq 'download/updates-v2/stable/5.3.4/package-pro-macos-arm64-macos-app-archive.tar.gz' "${LOG_FILE}"
grep -Fq 'download/updates-v2/stable/5.3.4/manifest-pro-windows-x64-windows-exe.json' "${LOG_FILE}"
if grep -Fq 'download/updates/5.3.4/version.json' "${LOG_FILE}"; then
    echo '5.3.4 fat release must use updater-v2 full-package distribution' >&2
    exit 1
fi

: > "${LOG_FILE}"
unset PROMOTE_TEST_SLOW_SCP_ONCE_FILE
export CHAT2DB_DOWNLOAD_SERVER_PULL_FROM_OSS=true
export CHAT2DB_RELEASE_VERSION=5.3.3
export CHAT2DB_RELEASE_PROFILE=bridge-fat
export CHAT2DB_RELEASE_CHANNEL=BETA
export CHAT2DB_RELEASE_EPOCH=1
export CHAT2DB_ROLLBACK_COMPATIBLE_FROM=5.3.0
rm -rf "${CHAT2DB_PROMOTE_WORK_DIR}"
bash "${SCRIPT_DIR}/promote-desktop-release.sh"
grep -Fq 'download/updates-v2/beta/5.3.3/package-pro-macos-arm64-macos-app-archive.tar.gz' "${LOG_FILE}"
grep -Fq 'download/updates-v2/beta/5.3.3/manifest-pro-windows-x64-windows-exe.json' "${LOG_FILE}"
grep -Fq 'download/updates-v2/beta/latest_version.json' "${LOG_FILE}"
if grep -Fq 'download/updates/5.3.3/version.json' "${LOG_FILE}"; then
    echo 'beta bridge must not publish the stable v1 bridge pointer' >&2
    exit 1
fi

echo "desktop promotion tests passed"
