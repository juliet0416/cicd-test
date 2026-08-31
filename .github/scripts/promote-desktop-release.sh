#!/usr/bin/env bash

set -euo pipefail

required_variables=(
    CHAT2DB_PRODUCT
    CHAT2DB_RELEASE_ROOT
    CHAT2DB_PRODUCT_APP_NAME
    CHAT2DB_RELEASE_VERSION
    CHAT2DB_RELEASE_PROFILE
    CHAT2DB_PUBLISH_MODE
    CHAT2DB_RELEASE_CHANNEL
    CHAT2DB_RELEASE_EPOCH
    CHAT2DB_ENTERPRISE_SHA
    CHAT2DB_RELEASE_NOTES_URL
    CHAT2DB_ENTERPRISE_ROOT
    CHAT2DB_UPDATE_ARTIFACT_ROOT
    CHAT2DB_PROMOTE_WORK_DIR
    CHAT2DB_UPLOAD_LATEST
    CHAT2DB_UPDATE_LATEST_VERSION_JSON
    CHAT2DB_UPDATE_KEY_ID
    CHAT2DB_UPDATE_PUBLIC_KEY_B64
    BUCKET_NAME
    R2_REMOTE
    DOWNLOAD_SERVER_HOST
    DOWNLOAD_SERVER_USER
    DOWNLOAD_SERVER_KEY
)

for variable in "${required_variables[@]}"; do
    if [ -z "${!variable:-}" ]; then
        echo "Error: ${variable} is required" >&2
        exit 1
    fi
done

case "${CHAT2DB_PRODUCT}" in PRO|LOCAL) ;; *) echo "Error: invalid product" >&2; exit 1 ;; esac
case "${CHAT2DB_RELEASE_ROOT}" in download|offline) ;; *) echo "Error: invalid release root" >&2; exit 1 ;; esac
case "${CHAT2DB_RELEASE_PROFILE}" in bridge-fat|versioned-thin) ;; *) echo "Error: invalid release profile" >&2; exit 1 ;; esac
case "${CHAT2DB_PUBLISH_MODE}" in v1|v2|both) ;; *) echo "Error: invalid publish mode" >&2; exit 1 ;; esac
case "${CHAT2DB_RELEASE_CHANNEL}" in STABLE|BETA) ;; *) echo "Error: invalid release channel" >&2; exit 1 ;; esac
case "${CHAT2DB_UPLOAD_LATEST}" in true|false) ;; *) echo "Error: invalid upload_latest flag" >&2; exit 1 ;; esac
case "${CHAT2DB_UPDATE_LATEST_VERSION_JSON}" in true|false) ;; *) echo "Error: invalid pointer flag" >&2; exit 1 ;; esac

if [ "${CHAT2DB_PUBLISH_MODE}" != "v2" ] \
        && { [ "${CHAT2DB_RELEASE_PROFILE}" != "bridge-fat" ] \
            || [ "${CHAT2DB_RELEASE_CHANNEL}" != "STABLE" ]; }; then
    echo "Error: v1 publication requires a stable bridge-fat release" >&2
    exit 1
fi

for command in jq openssl ossutil rclone scp sha256sum ssh tar; do
    command -v "${command}" >/dev/null 2>&1 || {
        echo "Error: required command not found: ${command}" >&2
        exit 1
    }
done

PROMOTE_ROOT="${CHAT2DB_PROMOTE_WORK_DIR}/desktop-promote"
PUBLISH_ROOT="${PROMOTE_ROOT}/publish"
INSTALLER_ROOT="${PROMOTE_ROOT}/installers"
VERSIONED_REPLICAS_READY=()
DEFERRED_UPDATE_POINTER_SOURCE=""
DEFERRED_UPDATE_POINTER_DESTINATION=""
PRODUCT_LOWER=$(printf '%s' "${CHAT2DB_PRODUCT}" | tr '[:upper:]' '[:lower:]')
CHANNEL_LOWER=$(printf '%s' "${CHAT2DB_RELEASE_CHANNEL}" | tr '[:upper:]' '[:lower:]')
mkdir -p "${PUBLISH_ROOT}" "${INSTALLER_ROOT}"

DOWNLOAD_TARGET="${DOWNLOAD_SERVER_USER}@${DOWNLOAD_SERVER_HOST}"
SSH_OPTIONS=(-i "${DOWNLOAD_SERVER_KEY}" -o StrictHostKeyChecking=accept-new -o BatchMode=yes)
PROMOTION_STARTED_SECONDS=${SECONDS}
PROMOTION_PHASE="initialization"
PROMOTION_OBJECT_CURRENT=0
PROMOTION_OBJECT_TOTAL=0
PROMOTION_LOG_INTERVAL_SECONDS=${CHAT2DB_PROMOTION_LOG_INTERVAL_SECONDS:-30}
OSS_PUBLIC_BASE_URL=${CHAT2DB_OSS_PUBLIC_BASE_URL:-https://chat2db-cdn.oss-us-west-1.aliyuncs.com}
case "${PROMOTION_LOG_INTERVAL_SECONDS}" in
    ''|*[!0-9]*|0)
        echo "Error: CHAT2DB_PROMOTION_LOG_INTERVAL_SECONDS must be a positive integer" >&2
        exit 1
        ;;
esac

promotion_log() {
    local event="$1"
    local message
    shift
    printf -v message '[PROMOTE] time=%s event=%s' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${event}"
    while [ "$#" -gt 0 ]; do
        message="${message} $1"
        shift
    done
    printf '%s\n' "${message}"
}

begin_upload_phase() {
    PROMOTION_PHASE="$1"
    PROMOTION_OBJECT_TOTAL="$2"
    PROMOTION_OBJECT_CURRENT=0
    promotion_log phase_start \
        "phase=${PROMOTION_PHASE}" \
        "objects=${PROMOTION_OBJECT_TOTAL}"
}

begin_upload_object() {
    local mode="$1"
    local source_file="$2"
    local remote_relative_path="$3"
    local size_bytes
    PROMOTION_OBJECT_CURRENT=$((PROMOTION_OBJECT_CURRENT + 1))
    size_bytes=$(wc -c < "${source_file}" | tr -d '[:space:]')
    promotion_log object_start \
        "phase=${PROMOTION_PHASE}" \
        "object=${PROMOTION_OBJECT_CURRENT}/${PROMOTION_OBJECT_TOTAL}" \
        "mode=${mode}" \
        "size_bytes=${size_bytes}" \
        "path=${remote_relative_path}"
}

complete_upload_object() {
    local mode="$1"
    local remote_relative_path="$2"
    promotion_log object_complete \
        "phase=${PROMOTION_PHASE}" \
        "object=${PROMOTION_OBJECT_CURRENT}/${PROMOTION_OBJECT_TOTAL}" \
        "mode=${mode}" \
        "path=${remote_relative_path}"
    if [ "${PROMOTION_OBJECT_CURRENT}" -eq "${PROMOTION_OBJECT_TOTAL}" ]; then
        promotion_log phase_complete \
            "phase=${PROMOTION_PHASE}" \
            "objects=${PROMOTION_OBJECT_CURRENT}/${PROMOTION_OBJECT_TOTAL}"
    fi
}

run_transfer() {
    local provider="$1"
    local stage="$2"
    local source="$3"
    local destination="$4"
    shift 4
    local started_seconds=${SECONDS}
    local transfer_pid monitor_pid
    local status
    promotion_log transfer_start \
        "phase=${PROMOTION_PHASE}" \
        "object=${PROMOTION_OBJECT_CURRENT}/${PROMOTION_OBJECT_TOTAL}" \
        "provider=${provider}" \
        "stage=${stage}" \
        "source=${source}" \
        "destination=${destination}"
    "$@" &
    transfer_pid=$!
    (
        while sleep "${PROMOTION_LOG_INTERVAL_SECONDS}"; do
            kill -0 "${transfer_pid}" 2>/dev/null || exit 0
            promotion_log transfer_progress \
                "phase=${PROMOTION_PHASE}" \
                "object=${PROMOTION_OBJECT_CURRENT}/${PROMOTION_OBJECT_TOTAL}" \
                "provider=${provider}" \
                "stage=${stage}" \
                "elapsed_seconds=$((SECONDS - started_seconds))" \
                "destination=${destination}"
        done
    ) &
    monitor_pid=$!
    if wait "${transfer_pid}"; then
        status=0
    else
        status=$?
    fi
    kill "${monitor_pid}" 2>/dev/null || true
    wait "${monitor_pid}" 2>/dev/null || true
    if [ "${status}" -eq 0 ]; then
        promotion_log transfer_complete \
            "phase=${PROMOTION_PHASE}" \
            "object=${PROMOTION_OBJECT_CURRENT}/${PROMOTION_OBJECT_TOTAL}" \
            "provider=${provider}" \
            "stage=${stage}" \
            "elapsed_seconds=$((SECONDS - started_seconds))" \
            "destination=${destination}"
        return 0
    else
        promotion_log transfer_failed \
            "phase=${PROMOTION_PHASE}" \
            "object=${PROMOTION_OBJECT_CURRENT}/${PROMOTION_OBJECT_TOTAL}" \
            "provider=${provider}" \
            "stage=${stage}" \
            "elapsed_seconds=$((SECONDS - started_seconds))" \
            "exit_code=${status}" \
            "destination=${destination}"
        return "${status}"
    fi
}

run_scp_transfer() {
    local source_file="$1"
    local temporary_path="$2"
    local destination="${DOWNLOAD_TARGET}:${temporary_path}"
    local source_size started_seconds transfer_pid monitor_pid status elapsed_seconds
    source_size=$(wc -c < "${source_file}" | tr -d '[:space:]')
    started_seconds=${SECONDS}
    promotion_log transfer_start \
        "phase=${PROMOTION_PHASE}" \
        "object=${PROMOTION_OBJECT_CURRENT}/${PROMOTION_OBJECT_TOTAL}" \
        "provider=download-server" \
        "stage=scp" \
        "size_bytes=${source_size}" \
        "source=${source_file}" \
        "destination=${destination}"
    scp "${SSH_OPTIONS[@]}" "${source_file}" "${destination}" </dev/null &
    transfer_pid=$!
    (
        local uploaded_size percent
        while sleep "${PROMOTION_LOG_INTERVAL_SECONDS}"; do
            kill -0 "${transfer_pid}" 2>/dev/null || exit 0
            # The remote command intentionally uses the locally resolved temporary path.
            # shellcheck disable=SC2029
            uploaded_size=$(ssh "${SSH_OPTIONS[@]}" "${DOWNLOAD_TARGET}" \
                "if [ -f '${temporary_path}' ]; then wc -c < '${temporary_path}'; else echo 0; fi" \
                </dev/null 2>/dev/null || true)
            case "${uploaded_size}" in
                ''|*[!0-9]*) uploaded_size=0 ;;
            esac
            if [ "${source_size}" -gt 0 ]; then
                percent=$((uploaded_size * 100 / source_size))
            else
                percent=0
            fi
            promotion_log transfer_progress \
                "phase=${PROMOTION_PHASE}" \
                "object=${PROMOTION_OBJECT_CURRENT}/${PROMOTION_OBJECT_TOTAL}" \
                "provider=download-server" \
                "stage=scp" \
                "elapsed_seconds=$((SECONDS - started_seconds))" \
                "uploaded_bytes=${uploaded_size}" \
                "size_bytes=${source_size}" \
                "percent=${percent}" \
                "destination=${destination}"
        done
    ) &
    monitor_pid=$!
    if wait "${transfer_pid}"; then
        status=0
    else
        status=$?
    fi
    kill "${monitor_pid}" 2>/dev/null || true
    wait "${monitor_pid}" 2>/dev/null || true
    elapsed_seconds=$((SECONDS - started_seconds))
    if [ "${status}" -eq 0 ]; then
        promotion_log transfer_complete \
            "phase=${PROMOTION_PHASE}" \
            "object=${PROMOTION_OBJECT_CURRENT}/${PROMOTION_OBJECT_TOTAL}" \
            "provider=download-server" \
            "stage=scp" \
            "elapsed_seconds=${elapsed_seconds}" \
            "size_bytes=${source_size}" \
            "destination=${destination}"
        return 0
    fi
    promotion_log transfer_failed \
        "phase=${PROMOTION_PHASE}" \
        "object=${PROMOTION_OBJECT_CURRENT}/${PROMOTION_OBJECT_TOTAL}" \
        "provider=download-server" \
        "stage=scp" \
        "elapsed_seconds=${elapsed_seconds}" \
        "size_bytes=${source_size}" \
        "exit_code=${status}" \
        "destination=${destination}"
    return "${status}"
}

pull_download_server_from_oss() {
    local source_file="$1"
    local source_relative_path="$2"
    local temporary_path="$3"
    local source_url="${OSS_PUBLIC_BASE_URL}/${source_relative_path}"
    local expected_sha256
    expected_sha256=$(sha256sum "${source_file}" | awk '{print $1}')
    promotion_log transfer_strategy \
        "phase=${PROMOTION_PHASE}" \
        "object=${PROMOTION_OBJECT_CURRENT}/${PROMOTION_OBJECT_TOTAL}" \
        "provider=download-server" \
        "strategy=oss-pull" \
        "source=${source_url}"
    # Source URL, digest, and destination are generated from release-owned values.
    # shellcheck disable=SC2029
    run_transfer download-server oss-pull "${source_url}" "${DOWNLOAD_TARGET}:${temporary_path}" \
        ssh "${SSH_OPTIONS[@]}" "${DOWNLOAD_TARGET}" \
            "set -e; curl --fail --location --silent --show-error --retry 5 --connect-timeout 15 --output '${temporary_path}' '${source_url}'; actual=\$(sha256sum '${temporary_path}' | awk '{print \$1}'); test \"\${actual}\" = '${expected_sha256}'" \
            </dev/null
}

wait_for_parallel_transfers() {
    local transfer_pid
    local status=0
    for transfer_pid in "$@"; do
        if ! wait "${transfer_pid}"; then
            status=1
        fi
    done
    return "${status}"
}

download_server_file_matches() {
    local source_file="$1"
    local final_path="$2"
    local expected_sha256
    expected_sha256=$(sha256sum "${source_file}" | awk '{print $1}')
    # The final path and digest are generated from release-owned values.
    # shellcheck disable=SC2029
    ssh "${SSH_OPTIONS[@]}" "${DOWNLOAD_TARGET}" \
        "test -f '${final_path}' && actual=\$(sha256sum '${final_path}' | awk '{print \$1}') && test \"\${actual}\" = '${expected_sha256}'" \
        </dev/null 2>/dev/null
}

cleanup_download_server_temp() {
    local temporary_path="$1"
    # The temporary path is generated uniquely for this workflow run.
    # shellcheck disable=SC2029
    ssh "${SSH_OPTIONS[@]}" "${DOWNLOAD_TARGET}" "rm -f '${temporary_path}'" \
        </dev/null 2>/dev/null || true
}

cleanup_download_server_temp_files() {
    local release_root="/data/downloads/${CHAT2DB_RELEASE_ROOT}"

    case "${release_root}" in
        /data/downloads/download|/data/downloads/offline) ;;
        *)
            echo "Error: refusing to clean unexpected download-server root: ${release_root}" >&2
            exit 1
            ;;
    esac

    promotion_log download_server_cleanup_start \
        "target=${DOWNLOAD_TARGET}" \
        "release_root=${release_root}" \
        "scope=temporary-files"
    # All paths are selected from the validated release-root allowlist above.
    # shellcheck disable=SC2029
    run_transfer download-server cleanup "${release_root}" "${DOWNLOAD_TARGET}:${release_root}" \
        ssh "${SSH_OPTIONS[@]}" "${DOWNLOAD_TARGET}" \
            "find '${release_root}' -type f -name '*.uploading.*' -mmin +1440 -delete" </dev/null
    promotion_log download_server_cleanup_complete \
        "target=${DOWNLOAD_TARGET}" \
        "release_root=${release_root}" \
        "scope=temporary-files"
}

prune_download_server_latest_history() {
    local release_root="/data/downloads/${CHAT2DB_RELEASE_ROOT}"
    local latest_linux_root="${release_root}/latest/linux"
    local current_package_pattern="${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_RELEASE_VERSION}-*"

    case "${release_root}" in
        /data/downloads/download|/data/downloads/offline) ;;
        *)
            echo "Error: refusing to prune unexpected download-server root: ${release_root}" >&2
            exit 1
            ;;
    esac
    case "${CHAT2DB_PRODUCT_APP_NAME}:${CHAT2DB_RELEASE_VERSION}" in
        *[!A-Za-z0-9._:-]*)
            echo "Error: unsafe product name or release version for retention cleanup" >&2
            exit 1
            ;;
    esac

    promotion_log download_server_retention_start \
        "target=${DOWNLOAD_TARGET}" \
        "latest_root=${latest_linux_root}" \
        "keep=${current_package_pattern}"
    # This runs only after every current latest installer has been published successfully.
    # shellcheck disable=SC2029
    run_transfer download-server retention "${latest_linux_root}" "${DOWNLOAD_TARGET}:${latest_linux_root}" \
        ssh "${SSH_OPTIONS[@]}" "${DOWNLOAD_TARGET}" \
            "if [ -d '${latest_linux_root}' ]; then find '${latest_linux_root}' -type f -name '${CHAT2DB_PRODUCT_APP_NAME}-*' ! -name '${current_package_pattern}' -delete; fi" \
            </dev/null
    promotion_log download_server_retention_complete \
        "target=${DOWNLOAD_TARGET}" \
        "latest_root=${latest_linux_root}" \
        "keep=${current_package_pattern}"
}

cleanup_download_server_failed_uploads() {
    local release_root="/data/downloads/${CHAT2DB_RELEASE_ROOT}"
    local current_upload_pattern="*.uploading.${GITHUB_RUN_ID:-local}.${GITHUB_RUN_ATTEMPT:-1}.*"
    case "${release_root}" in
        /data/downloads/download|/data/downloads/offline) ;;
        *) return 0 ;;
    esac
    # All paths are selected from the validated release-root allowlist above.
    # shellcheck disable=SC2029
    ssh "${SSH_OPTIONS[@]}" "${DOWNLOAD_TARGET}" \
        "find '${release_root}' -type f -name '${current_upload_pattern}' -delete" \
        </dev/null 2>/dev/null || true
}

upload_download_server() {
    local source_file="$1"
    local remote_relative_path="$2"
    local allow_oss_pull="${3:-false}"
    local oss_source_relative_path="${4:-${remote_relative_path}}"
    local final_path="/data/downloads/${remote_relative_path}"
    local remote_dir
    local temporary_path
    remote_dir=$(dirname "${final_path}")
    temporary_path="${final_path}.uploading.${GITHUB_RUN_ID:-local}.${GITHUB_RUN_ATTEMPT:-1}.${RANDOM}"
    if [ "${allow_oss_pull}" = "true" ] \
            && download_server_file_matches "${source_file}" "${final_path}"; then
        promotion_log transfer_skipped \
            "phase=${PROMOTION_PHASE}" \
            "object=${PROMOTION_OBJECT_CURRENT}/${PROMOTION_OBJECT_TOTAL}" \
            "provider=download-server" \
            "reason=sha256-match" \
            "destination=${DOWNLOAD_TARGET}:${final_path}"
        return 0
    fi
    # The path is intentionally quoted for the remote shell.
    # shellcheck disable=SC2029
    run_transfer download-server prepare "${source_file}" "${DOWNLOAD_TARGET}:${remote_dir}" \
        ssh "${SSH_OPTIONS[@]}" "${DOWNLOAD_TARGET}" "mkdir -p '${remote_dir}'" </dev/null
    if [ "${allow_oss_pull}" = "true" ]; then
        if [ "${CHAT2DB_DOWNLOAD_SERVER_PULL_FROM_OSS:-true}" = "true" ] \
                && pull_download_server_from_oss "${source_file}" "${oss_source_relative_path}" "${temporary_path}"; then
            :
        else
            promotion_log transfer_fallback \
                "phase=${PROMOTION_PHASE}" \
                "object=${PROMOTION_OBJECT_CURRENT}/${PROMOTION_OBJECT_TOTAL}" \
                "provider=download-server" \
                "from=oss-pull" \
                "to=scp" \
                "destination=${DOWNLOAD_TARGET}:${temporary_path}"
            if ! run_scp_transfer "${source_file}" "${temporary_path}"; then
                cleanup_download_server_temp "${temporary_path}"
                return 1
            fi
        fi
    else
        if ! run_scp_transfer "${source_file}" "${temporary_path}"; then
            cleanup_download_server_temp "${temporary_path}"
            return 1
        fi
    fi
    # All three paths are intentionally expanded locally.
    # shellcheck disable=SC2029
    run_transfer download-server atomic-rename "${temporary_path}" "${DOWNLOAD_TARGET}:${final_path}" \
        ssh "${SSH_OPTIONS[@]}" "${DOWNLOAD_TARGET}" \
            "chmod 644 '${temporary_path}' && mv -f '${temporary_path}' '${final_path}'" </dev/null
}

copy_download_server_file() {
    local source_file="$1"
    local source_relative_path="$2"
    local destination_relative_path="$3"
    local source_path="/data/downloads/${source_relative_path}"
    local destination_path="/data/downloads/${destination_relative_path}"
    local destination_dir temporary_path expected_sha256
    destination_dir=$(dirname "${destination_path}")
    temporary_path="${destination_path}.uploading.${GITHUB_RUN_ID:-local}.${GITHUB_RUN_ATTEMPT:-1}.${RANDOM}"
    expected_sha256=$(sha256sum "${source_file}" | awk '{print $1}')
    run_transfer download-server provider-copy "${source_path}" "${DOWNLOAD_TARGET}:${destination_path}" \
        ssh "${SSH_OPTIONS[@]}" "${DOWNLOAD_TARGET}" \
            "set -e; mkdir -p '${destination_dir}'; rm -f '${temporary_path}'; ln '${source_path}' '${temporary_path}'; actual=\$(sha256sum '${temporary_path}' | awk '{print \$1}'); test \"\${actual}\" = '${expected_sha256}'; chmod 644 '${temporary_path}'; mv -f '${temporary_path}' '${destination_path}'" \
            </dev/null
}

ensure_versioned_replicas() {
    local source_file="$1"
    local source_relative_path="$2"
    local ready_path r2_pid download_pid
    for ready_path in "${VERSIONED_REPLICAS_READY[@]-}"; do
        if [ "${ready_path}" = "${source_relative_path}" ]; then
            promotion_log replica_source_skipped \
                "phase=${PROMOTION_PHASE}" \
                "object=${PROMOTION_OBJECT_CURRENT}/${PROMOTION_OBJECT_TOTAL}" \
                "reason=already-ready" \
                "path=${source_relative_path}"
            return 0
        fi
    done
    promotion_log replica_source_start \
        "phase=${PROMOTION_PHASE}" \
        "object=${PROMOTION_OBJECT_CURRENT}/${PROMOTION_OBJECT_TOTAL}" \
        "path=${source_relative_path}"
    run_transfer cloudflare-r2 replica-source "${source_file}" "${R2_REMOTE}/${source_relative_path}" \
        rclone copyto "${source_file}" "${R2_REMOTE}/${source_relative_path}" </dev/null &
    r2_pid=$!
    upload_download_server "${source_file}" "${source_relative_path}" true "${source_relative_path}" &
    download_pid=$!
    wait_for_parallel_transfers "${r2_pid}" "${download_pid}"
    VERSIONED_REPLICAS_READY+=("${source_relative_path}")
    promotion_log replica_source_complete \
        "phase=${PROMOTION_PHASE}" \
        "object=${PROMOTION_OBJECT_CURRENT}/${PROMOTION_OBJECT_TOTAL}" \
        "path=${source_relative_path}"
}

copy_provider_replicas() {
    local source_file="$1"
    local source_relative_path="$2"
    local destination_relative_path="$3"
    local publish_oss_last="${4:-false}"
    local oss_pid r2_pid download_pid
    if [ "${publish_oss_last}" != "true" ]; then
        run_transfer aliyun-oss provider-copy \
            "oss://${BUCKET_NAME}/${source_relative_path}" \
            "oss://${BUCKET_NAME}/${destination_relative_path}" \
            ossutil cp -f \
                "oss://${BUCKET_NAME}/${source_relative_path}" \
                "oss://${BUCKET_NAME}/${destination_relative_path}" </dev/null &
        oss_pid=$!
    fi
    run_transfer cloudflare-r2 provider-copy \
        "${R2_REMOTE}/${source_relative_path}" \
        "${R2_REMOTE}/${destination_relative_path}" \
        rclone copyto \
            "${R2_REMOTE}/${source_relative_path}" \
            "${R2_REMOTE}/${destination_relative_path}" </dev/null &
    r2_pid=$!
    copy_download_server_file \
        "${source_file}" "${source_relative_path}" "${destination_relative_path}" &
    download_pid=$!
    if [ "${publish_oss_last}" = "true" ]; then
        wait_for_parallel_transfers "${r2_pid}" "${download_pid}"
    else
        wait_for_parallel_transfers "${oss_pid}" "${r2_pid}" "${download_pid}"
    fi
    if [ "${publish_oss_last}" = "true" ]; then
        run_transfer aliyun-oss provider-copy \
            "oss://${BUCKET_NAME}/${source_relative_path}" \
            "oss://${BUCKET_NAME}/${destination_relative_path}" \
            ossutil cp -f \
                "oss://${BUCKET_NAME}/${source_relative_path}" \
                "oss://${BUCKET_NAME}/${destination_relative_path}" </dev/null
    fi
}

upload_immutable_from_versioned() {
    local source_file="$1"
    local source_relative_path="$2"
    local destination_relative_path="$3"
    test -s "${source_file}"
    begin_upload_object immutable "${source_file}" "${destination_relative_path}"
    ensure_versioned_replicas "${source_file}" "${source_relative_path}"
    copy_provider_replicas \
        "${source_file}" "${source_relative_path}" "${destination_relative_path}" false
    complete_upload_object immutable "${destination_relative_path}"
}

upload_mutable_from_versioned() {
    local source_file="$1"
    local source_relative_path="$2"
    local destination_relative_path="$3"
    test -s "${source_file}"
    begin_upload_object mutable "${source_file}" "${destination_relative_path}"
    ensure_versioned_replicas "${source_file}" "${source_relative_path}"
    copy_provider_replicas \
        "${source_file}" "${source_relative_path}" "${destination_relative_path}" true
    complete_upload_object mutable "${destination_relative_path}"
}

upload_immutable() {
    local source_file="$1"
    local remote_relative_path="$2"
    test -s "${source_file}"
    begin_upload_object immutable "${source_file}" "${remote_relative_path}"
    run_transfer aliyun-oss upload "${source_file}" "oss://${BUCKET_NAME}/${remote_relative_path}" \
        ossutil cp -f "${source_file}" "oss://${BUCKET_NAME}/${remote_relative_path}" </dev/null
    local r2_pid download_pid
    run_transfer cloudflare-r2 upload "${source_file}" "${R2_REMOTE}/${remote_relative_path}" \
        rclone copyto "${source_file}" "${R2_REMOTE}/${remote_relative_path}" </dev/null &
    r2_pid=$!
    upload_download_server "${source_file}" "${remote_relative_path}" true &
    download_pid=$!
    wait_for_parallel_transfers "${r2_pid}" "${download_pid}"
    complete_upload_object immutable "${remote_relative_path}"
}

upload_mutable() {
    local source_file="$1"
    local remote_relative_path="$2"
    test -s "${source_file}"
    begin_upload_object mutable "${source_file}" "${remote_relative_path}"
    # Publish the public OSS object last after both replicas are complete.
    upload_download_server "${source_file}" "${remote_relative_path}" false
    run_transfer cloudflare-r2 upload "${source_file}" "${R2_REMOTE}/${remote_relative_path}" \
        rclone copyto "${source_file}" "${R2_REMOTE}/${remote_relative_path}" </dev/null
    run_transfer aliyun-oss upload "${source_file}" "oss://${BUCKET_NAME}/${remote_relative_path}" \
        ossutil cp -f "${source_file}" "oss://${BUCKET_NAME}/${remote_relative_path}" </dev/null
    complete_upload_object mutable "${remote_relative_path}"
}

publish_bridge_update() {
    local artifact_dir="${CHAT2DB_UPDATE_ARTIFACT_ROOT}/bridge-update-${PRODUCT_LOWER}"
    local archive="${artifact_dir}/bridge-update.tar.gz"
    local extracted="${PROMOTE_ROOT}/bridge"
    local update_root="${CHAT2DB_RELEASE_ROOT}/updates/${CHAT2DB_RELEASE_VERSION}"
    local pointer="${PROMOTE_ROOT}/latest_version.json"
    local required upload_total=1

    test -s "${archive}"
    mkdir -p "${extracted}"
    tar -xzf "${archive}" -C "${extracted}"
    if find "${extracted}" -type l -print -quit | grep -q .; then
        echo "Error: bridge update payload must not contain symbolic links" >&2
        exit 1
    fi
    for required in version.json chat2db-enterprise.jar chat2db-updater.jar dist.zip; do
        test -s "${extracted}/${required}"
    done
    if [ -e "${extracted}/lib.zip" ]; then
        echo "Error: a bridge-fat release must not publish lib.zip" >&2
        exit 1
    fi

    for required in "${extracted}"/*.jar "${extracted}"/*.zip; do
        upload_total=$((upload_total + 1))
    done
    if [ -s "${extracted}/build-provenance.json" ]; then
        upload_total=$((upload_total + 1))
    fi
    if [ "${CHAT2DB_UPDATE_LATEST_VERSION_JSON}" = "true" ]; then
        upload_total=$((upload_total + 1))
    fi
    begin_upload_phase bridge-update "${upload_total}"

    upload_immutable "${extracted}/version.json" "${update_root}/version.json"
    for required in "${extracted}"/*.jar "${extracted}"/*.zip; do
        upload_immutable "${required}" "${update_root}/$(basename "${required}")"
    done
    if [ -s "${extracted}/build-provenance.json" ]; then
        upload_immutable "${extracted}/build-provenance.json" "${update_root}/build-provenance.json"
    fi

    jq -cn \
        --arg latestVersion "${CHAT2DB_RELEASE_VERSION}" \
        --arg metadataUrl "https://cdn.chat2db-ai.com/${update_root}/version.json" \
        '{latestVersion: $latestVersion, metadataUrl: $metadataUrl, forceUpdate: false}' \
        > "${pointer}"
    if [ "${CHAT2DB_UPDATE_LATEST_VERSION_JSON}" = "true" ]; then
        upload_mutable "${pointer}" "${CHAT2DB_RELEASE_ROOT}/updates/latest_version.json"
    fi
}

download_release_artifact() {
    local version="$1"
    local file_name="$2"
    local destination="$3"
    mkdir -p "$(dirname "${destination}")"
    run_transfer aliyun-oss download \
        "oss://${BUCKET_NAME}/${CHAT2DB_RELEASE_ROOT}/${version}/${file_name}" \
        "${destination}" \
        ossutil cp -f \
            "oss://${BUCKET_NAME}/${CHAT2DB_RELEASE_ROOT}/${version}/${file_name}" \
            "${destination}"
    test -s "${destination}"
}

publish_v2_update() {
    local update_root="${CHAT2DB_RELEASE_ROOT}/updates-v2/${CHANNEL_LOWER}/${CHAT2DB_RELEASE_VERSION}"
    local base_url="https://cdn.chat2db-ai.com/${update_root}"
    local generated="${PUBLISH_ROOT}/updates-v2"
    local previous_index="${PROMOTE_ROOT}/previous-release-index.json"
    local product_display current_file package_type package_extension arch launcher manifest native_version upload_total
    local current_path target
    local manifests=()
    local reusable_package_sources=()
    local current_files=()
    local previous_index_environment=()
    local transition_mode=false

    if [ -z "${CHAT2DB_UPDATE_SIGNING_PRIVATE_KEY_B64:-}" ]; then
        echo "Error: CHAT2DB_UPDATE_SIGNING_PRIVATE_KEY_B64 is required for updater-v2 publication" >&2
        exit 1
    fi
    # TEMP-5.3.3-5.3.4-PROTOCOL-2-COMPAT: 5.3.5 is the one inbound
    # transition release for already-installed protocol-2 Pro clients.
    if [ "${CHAT2DB_PRODUCT}" = "PRO" ] \
            && [ "${CHAT2DB_RELEASE_VERSION}" = "5.3.5" ] \
            && [ "${CHAT2DB_RELEASE_PROFILE}" = "bridge-fat" ] \
            && [ "${CHAT2DB_RELEASE_CHANNEL}" = "STABLE" ]; then
        transition_mode=true
    fi
    mkdir -p "${generated}"
    rm -f "${generated}"/*
    # shellcheck source=script/package/desktop_layout.sh
    source "${CHAT2DB_ENTERPRISE_ROOT}/script/package/desktop_layout.sh"
    native_version=$(chat2db_jpackage_version "${CHAT2DB_RELEASE_VERSION}")
    if [ "${CHAT2DB_PRODUCT}" = "PRO" ]; then
        product_display="Chat2DB Pro"
    else
        product_display="Chat2DB Local"
    fi

    generate_manifest() {
        local platform="$1"
        local arch="$2"
        local package_type="$3"
        local current_path="$4"
        local launcher="$5"
        local baseline="$6"
        local platform_lower arch_lower package_type_lower suffix rollback_file rollback_url manifest
        platform_lower=$(printf '%s' "${platform}" | tr '[:upper:]' '[:lower:]')
        arch_lower=$(printf '%s' "${arch}" | tr '[:upper:]' '[:lower:]')
        package_type_lower=$(printf '%s' "${package_type}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        suffix=""
        rollback_file=""
        rollback_url=""
        if [ "${transition_mode}" = "true" ]; then
            suffix="-from-${baseline}"
            case "${package_type}" in
                WINDOWS_EXE|LINUX_DEB|LINUX_RPM)
                    rollback_file="${INSTALLER_ROOT}/rollback-${baseline}-${current_file}"
                    download_release_artifact "${baseline}" "${current_file}" "${rollback_file}"
                    rollback_url="https://cdn.chat2db-ai.com/${CHAT2DB_RELEASE_ROOT}/${baseline}/${current_file}"
                    ;;
            esac
        fi
        if [ "${transition_mode}" = "true" ]; then
            CHAT2DB_UPDATE_SIGNING_PRIVATE_KEY_B64="${CHAT2DB_UPDATE_SIGNING_PRIVATE_KEY_B64}" \
            CHAT2DB_UPDATE_KEY_ID="${CHAT2DB_UPDATE_KEY_ID}" \
            CHAT2DB_UPDATE_PUBLIC_KEY_B64="${CHAT2DB_UPDATE_PUBLIC_KEY_B64}" \
            CHAT2DB_UPDATE_MANIFEST_SUFFIX="${suffix}" \
                bash "${CHAT2DB_ENTERPRISE_ROOT}/script/package/generate_update_v2.sh" \
                    "${CHAT2DB_RELEASE_VERSION}" "${native_version}" "${CHAT2DB_PRODUCT}" "${CHAT2DB_RELEASE_CHANNEL}" \
                    "${platform}" "${arch}" "${package_type}" "${current_path}" "${launcher}" \
                    "${generated}" "${base_url}" "${CHAT2DB_RELEASE_EPOCH}" "${CHAT2DB_ENTERPRISE_SHA}" \
                    "${CHAT2DB_RELEASE_NOTES_URL}" 2 1 "${baseline}" "${rollback_file}" "${rollback_url}"
        else
            CHAT2DB_UPDATE_SIGNING_PRIVATE_KEY_B64="${CHAT2DB_UPDATE_SIGNING_PRIVATE_KEY_B64}" \
            CHAT2DB_UPDATE_KEY_ID="${CHAT2DB_UPDATE_KEY_ID}" \
            CHAT2DB_UPDATE_PUBLIC_KEY_B64="${CHAT2DB_UPDATE_PUBLIC_KEY_B64}" \
            CHAT2DB_UPDATE_MANIFEST_SUFFIX="${suffix}" \
                bash "${CHAT2DB_ENTERPRISE_ROOT}/script/package/generate_update_v2.sh" \
                    "${CHAT2DB_RELEASE_VERSION}" "${native_version}" "${CHAT2DB_PRODUCT}" "${CHAT2DB_RELEASE_CHANNEL}" \
                    "${platform}" "${arch}" "${package_type}" "${current_path}" "${launcher}" \
                    "${generated}" "${base_url}" "${CHAT2DB_RELEASE_EPOCH}" "${CHAT2DB_ENTERPRISE_SHA}" \
                    "${CHAT2DB_RELEASE_NOTES_URL}"
        fi
        manifest="${generated}/manifest-${PRODUCT_LOWER}-${platform_lower}-${arch_lower}-${package_type_lower}${suffix}.json"
        test -s "${manifest}"
        manifests+=("${manifest}")
    }

    for target in macos-x64 macos-arm64; do
        if [ "${target}" = "macos-x64" ]; then arch=X64; else arch=ARM64; fi
        current_path="${CHAT2DB_UPDATE_ARTIFACT_ROOT}/full-package-${PRODUCT_LOWER}-${target}/full-package-${target}.tar.gz"
        test -s "${current_path}"
        current_file="full-package-${target}.tar.gz"
        generate_manifest MACOS "${arch}" MACOS_APP_ARCHIVE "${current_path}" \
            "Contents/MacOS/${product_display}" 5.3.3
    done

    current_file="${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_RELEASE_VERSION}.exe"
    current_path="${INSTALLER_ROOT}/${current_file}"
    download_release_artifact "${CHAT2DB_RELEASE_VERSION}" "${current_file}" "${current_path}"
    if [ "${transition_mode}" = "true" ]; then
        generate_manifest WINDOWS X64 WINDOWS_EXE "${current_path}" "${product_display}.exe" 5.3.3
        generate_manifest WINDOWS X64 WINDOWS_EXE "${current_path}" "${product_display}.exe" 5.3.4
    else
        generate_manifest WINDOWS X64 WINDOWS_EXE "${current_path}" "${product_display}.exe" ""
    fi
    reusable_package_sources+=(
        "package-${PRODUCT_LOWER}-windows-x64-windows-exe.exe::${CHAT2DB_RELEASE_ROOT}/${CHAT2DB_RELEASE_VERSION}/${current_file}"
    )

    for target in linux-x64 linux-arm64; do
        if [ "${target}" = "linux-x64" ]; then
            arch=X64
            current_files=(
                "${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_RELEASE_VERSION}-x86_64.AppImage:LINUX_APPIMAGE"
                "${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_RELEASE_VERSION}-amd64.deb:LINUX_DEB"
                "${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_RELEASE_VERSION}-x86_64.rpm:LINUX_RPM"
            )
        else
            arch=ARM64
            current_files=(
                "${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_RELEASE_VERSION}-arm64.AppImage:LINUX_APPIMAGE"
                "${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_RELEASE_VERSION}-arm64.deb:LINUX_DEB"
                "${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_RELEASE_VERSION}-aarch64.rpm:LINUX_RPM"
            )
        fi
        for index in 0 1 2; do
            current_file="${current_files[$index]%%:*}"
            package_type="${current_files[$index]##*:}"
            case "${package_type}" in
                LINUX_APPIMAGE) package_extension=AppImage ;;
                LINUX_DEB) package_extension=deb ;;
                LINUX_RPM) package_extension=rpm ;;
            esac
            current_path="${INSTALLER_ROOT}/${current_file}"
            download_release_artifact "${CHAT2DB_RELEASE_VERSION}" "${current_file}" "${current_path}"
            launcher="bin/${product_display}"
            if [ "${package_type}" = "LINUX_APPIMAGE" ]; then
                launcher="."
            fi
            if [ "${transition_mode}" = "true" ]; then
                if [ "${package_type}" = "LINUX_APPIMAGE" ]; then
                    generate_manifest LINUX "${arch}" "${package_type}" "${current_path}" "${launcher}" 5.3.3
                else
                    generate_manifest LINUX "${arch}" "${package_type}" "${current_path}" "${launcher}" 5.3.3
                    generate_manifest LINUX "${arch}" "${package_type}" "${current_path}" "${launcher}" 5.3.4
                fi
            else
                generate_manifest LINUX "${arch}" "${package_type}" "${current_path}" "${launcher}" ""
            fi
            reusable_package_sources+=(
                "package-${PRODUCT_LOWER}-linux-$(printf '%s' "${arch}" | tr '[:upper:]' '[:lower:]')-$(printf '%s' "${package_type}" | tr '[:upper:]' '[:lower:]' | tr '_' '-').${package_extension}::${CHAT2DB_RELEASE_ROOT}/${CHAT2DB_RELEASE_VERSION}/${current_file}"
            )
        done
    done

    if ossutil cp -f \
        "oss://${BUCKET_NAME}/${CHAT2DB_RELEASE_ROOT}/updates-v2/${CHANNEL_LOWER}/latest_version.json" \
        "${previous_index}" >/dev/null 2>&1; then
        test -s "${previous_index}"
        previous_index_environment+=("CHAT2DB_PREVIOUS_UPDATE_INDEX=${previous_index}")
    fi
    if [ "${transition_mode}" = "true" ]; then
        env "${previous_index_environment[@]}" CHAT2DB_UPDATE_INDEX_TRANSITION=true \
            bash "${CHAT2DB_ENTERPRISE_ROOT}/script/package/generate_update_index_v2.sh" \
                "${CHAT2DB_RELEASE_CHANNEL}" "${CHAT2DB_RELEASE_EPOCH}" "${base_url}" \
                "${generated}/release-index.json" "${manifests[@]}"
    else
        env "${previous_index_environment[@]}" \
            bash "${CHAT2DB_ENTERPRISE_ROOT}/script/package/generate_update_index_v2.sh" \
                "${CHAT2DB_RELEASE_CHANNEL}" "${CHAT2DB_RELEASE_EPOCH}" "${base_url}" \
                "${generated}/release-index.json" "${manifests[@]}"
    fi

    upload_total=$(find "${generated}" -maxdepth 1 -type f -print | wc -l | tr -d '[:space:]')
    begin_upload_phase updates-v2 "${upload_total}"

    while IFS= read -r file; do
        local reusable_source=""
        local reusable_mapping reusable_name
        for reusable_mapping in "${reusable_package_sources[@]}"; do
            reusable_name="${reusable_mapping%%::*}"
            if [ "${reusable_name}" = "$(basename "${file}")" ]; then
                reusable_source="${reusable_mapping##*::}"
                break
            fi
        done
        if [ -n "${reusable_source}" ]; then
            upload_immutable_from_versioned \
                "${file}" "${reusable_source}" "${update_root}/$(basename "${file}")"
        else
            upload_immutable "${file}" "${update_root}/$(basename "${file}")"
        fi
    done < <(find "${generated}" -maxdepth 1 -type f -print | LC_ALL=C sort)

    if [ "${CHAT2DB_UPDATE_LATEST_VERSION_JSON}" = "true" ]; then
        DEFERRED_UPDATE_POINTER_SOURCE="${generated}/release-index.json"
        DEFERRED_UPDATE_POINTER_DESTINATION="${CHAT2DB_RELEASE_ROOT}/updates-v2/${CHANNEL_LOWER}/latest_version.json"
    fi
}

publish_deferred_update_pointer() {
    if [ -z "${DEFERRED_UPDATE_POINTER_SOURCE}" ]; then
        return 0
    fi
    begin_upload_phase update-pointer 1
    upload_mutable \
        "${DEFERRED_UPDATE_POINTER_SOURCE}" \
        "${DEFERRED_UPDATE_POINTER_DESTINATION}"
}

download_installer() {
    local file_name="$1"
    local destination="${INSTALLER_ROOT}/${file_name}"
    if [ -s "${destination}" ]; then
        promotion_log transfer_skipped \
            "phase=${PROMOTION_PHASE}" \
            "object=${PROMOTION_OBJECT_CURRENT}/${PROMOTION_OBJECT_TOTAL}" \
            "provider=local-cache" \
            "reason=installer-ready" \
            "destination=${destination}"
        return 0
    fi
    download_release_artifact "${CHAT2DB_RELEASE_VERSION}" "${file_name}" "${destination}"
}

publish_latest_installers() {
    local product="${CHAT2DB_PRODUCT_APP_NAME}"
    local version="${CHAT2DB_RELEASE_VERSION}"
    local source_file destination
    local mappings=(
        "${product}-${version}.exe::${product}-latest.exe"
        "${product}-${version}-x64.dmg::${product}-latest.dmg"
        "${product}-${version}-arm64.dmg::${product}-arm64-latest.dmg"
        "${product}-${version}-amd64.deb::${product}-latest.deb"
        "${product}-${version}-x86_64.rpm::${product}-latest.rpm"
        "${product}-${version}-x86_64.AppImage::${product}-latest.AppImage"
        "${product}-${version}-arm64.deb::${product}-arm64-latest.deb"
        "${product}-${version}-aarch64.rpm::${product}-arm64-latest.rpm"
        "${product}-${version}-arm64.AppImage::${product}-arm64-latest.AppImage"
    )
    local linux_mappings=(
        "${product}-${version}-amd64.deb::x86_64"
        "${product}-${version}-x86_64.rpm::x86_64"
        "${product}-${version}-x86_64.AppImage::x86_64"
        "${product}-${version}-arm64.deb::arm64"
        "${product}-${version}-aarch64.rpm::arm64"
        "${product}-${version}-arm64.AppImage::arm64"
    )

    for source_file in \
        "${product}-${version}.exe" \
        "${product}-${version}-x64.dmg" \
        "${product}-${version}-arm64.dmg" \
        "${product}-${version}-amd64.deb" \
        "${product}-${version}-x86_64.rpm" \
        "${product}-${version}-x86_64.AppImage" \
        "${product}-${version}-arm64.deb" \
        "${product}-${version}-aarch64.rpm" \
        "${product}-${version}-arm64.AppImage"; do
        download_installer "${source_file}"
    done

    begin_upload_phase latest-installers "$(( ${#mappings[@]} + ${#linux_mappings[@]} ))"

    for mapping in "${mappings[@]}"; do
        source_file="${mapping%%::*}"
        destination="${mapping##*::}"
        upload_mutable_from_versioned \
            "${INSTALLER_ROOT}/${source_file}" \
            "${CHAT2DB_RELEASE_ROOT}/${version}/${source_file}" \
            "${CHAT2DB_RELEASE_ROOT}/latest/${destination}"
    done
    for mapping in "${linux_mappings[@]}"; do
        source_file="${mapping%%::*}"
        destination="${mapping##*::}"
        upload_mutable_from_versioned \
            "${INSTALLER_ROOT}/${source_file}" \
            "${CHAT2DB_RELEASE_ROOT}/${version}/${source_file}" \
            "${CHAT2DB_RELEASE_ROOT}/latest/linux/${destination}/${source_file}"
    done
}

promotion_log promotion_start \
    "product=${CHAT2DB_PRODUCT}" \
    "version=${CHAT2DB_RELEASE_VERSION}" \
    "profile=${CHAT2DB_RELEASE_PROFILE}" \
    "publish_mode=${CHAT2DB_PUBLISH_MODE}" \
    "channel=${CHAT2DB_RELEASE_CHANNEL}" \
    "upload_latest=${CHAT2DB_UPLOAD_LATEST}" \
    "update_pointer=${CHAT2DB_UPDATE_LATEST_VERSION_JSON}"
trap cleanup_download_server_failed_uploads EXIT
cleanup_download_server_temp_files
download_server_capacity=$(ssh "${SSH_OPTIONS[@]}" "${DOWNLOAD_TARGET}" \
    "df -B1 --output=avail,pcent /data/downloads | tail -n 1 | tr -s ' '" \
    </dev/null 2>/dev/null || true)
promotion_log download_server_capacity \
    "target=${DOWNLOAD_TARGET}" \
    "available_and_usage=${download_server_capacity:-unknown}"

case "${CHAT2DB_PUBLISH_MODE}" in
    v1)
        publish_bridge_update
        ;;
    v2)
        publish_v2_update
        ;;
    both)
        publish_bridge_update
        publish_v2_update
        ;;
esac

if [ "${CHAT2DB_UPLOAD_LATEST}" = "true" ]; then
    publish_latest_installers
fi

publish_deferred_update_pointer

if [ "${CHAT2DB_UPLOAD_LATEST}" = "true" ]; then
    prune_download_server_latest_history
fi

promotion_log promotion_complete \
    "product=${CHAT2DB_PRODUCT}" \
    "version=${CHAT2DB_RELEASE_VERSION}" \
    "elapsed_seconds=$((SECONDS - PROMOTION_STARTED_SECONDS))"
