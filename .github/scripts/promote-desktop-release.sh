#!/usr/bin/env bash

set -euo pipefail

required_variables=(
    CHAT2DB_PRODUCT
    CHAT2DB_RELEASE_ROOT
    CHAT2DB_PRODUCT_APP_NAME
    CHAT2DB_RELEASE_VERSION
    CHAT2DB_RELEASE_PROFILE
    CHAT2DB_RELEASE_CHANNEL
    CHAT2DB_RELEASE_EPOCH
    CHAT2DB_DATA_SCHEMA_VERSION
    CHAT2DB_ROLLBACK_COMPATIBLE_FROM
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
case "${CHAT2DB_RELEASE_CHANNEL}" in STABLE|BETA) ;; *) echo "Error: invalid release channel" >&2; exit 1 ;; esac
case "${CHAT2DB_UPLOAD_LATEST}" in true|false) ;; *) echo "Error: invalid upload_latest flag" >&2; exit 1 ;; esac
case "${CHAT2DB_UPDATE_LATEST_VERSION_JSON}" in true|false) ;; *) echo "Error: invalid pointer flag" >&2; exit 1 ;; esac

for command in jq openssl ossutil rclone scp ssh tar; do
    command -v "${command}" >/dev/null 2>&1 || {
        echo "Error: required command not found: ${command}" >&2
        exit 1
    }
done

PROMOTE_ROOT="${CHAT2DB_PROMOTE_WORK_DIR}/desktop-promote"
PUBLISH_ROOT="${PROMOTE_ROOT}/publish"
INSTALLER_ROOT="${PROMOTE_ROOT}/installers"
PRODUCT_LOWER=$(printf '%s' "${CHAT2DB_PRODUCT}" | tr '[:upper:]' '[:lower:]')
CHANNEL_LOWER=$(printf '%s' "${CHAT2DB_RELEASE_CHANNEL}" | tr '[:upper:]' '[:lower:]')
mkdir -p "${PUBLISH_ROOT}" "${INSTALLER_ROOT}"

DOWNLOAD_TARGET="${DOWNLOAD_SERVER_USER}@${DOWNLOAD_SERVER_HOST}"
SSH_OPTIONS=(-i "${DOWNLOAD_SERVER_KEY}" -o StrictHostKeyChecking=accept-new -o BatchMode=yes)

upload_download_server() {
    local source_file="$1"
    local remote_relative_path="$2"
    local final_path="/data/downloads/${remote_relative_path}"
    local remote_dir
    local temporary_path
    remote_dir=$(dirname "${final_path}")
    temporary_path="${final_path}.uploading.${GITHUB_RUN_ID:-local}.${GITHUB_RUN_ATTEMPT:-1}.${RANDOM}"
    # The path is intentionally quoted for the remote shell.
    # shellcheck disable=SC2029
    ssh "${SSH_OPTIONS[@]}" "${DOWNLOAD_TARGET}" "mkdir -p '${remote_dir}'" </dev/null
    scp "${SSH_OPTIONS[@]}" "${source_file}" "${DOWNLOAD_TARGET}:${temporary_path}" </dev/null
    # All three paths are intentionally expanded locally.
    # shellcheck disable=SC2029
    ssh "${SSH_OPTIONS[@]}" "${DOWNLOAD_TARGET}" \
        "chmod 644 '${temporary_path}' && mv -f '${temporary_path}' '${final_path}'" </dev/null
}

upload_immutable() {
    local source_file="$1"
    local remote_relative_path="$2"
    test -s "${source_file}"
    ossutil cp -f "${source_file}" "oss://${BUCKET_NAME}/${remote_relative_path}" </dev/null
    rclone copyto "${source_file}" "${R2_REMOTE}/${remote_relative_path}" </dev/null
    upload_download_server "${source_file}" "${remote_relative_path}" </dev/null
}

upload_mutable() {
    local source_file="$1"
    local remote_relative_path="$2"
    test -s "${source_file}"
    # Publish the public OSS object last after both replicas are complete.
    upload_download_server "${source_file}" "${remote_relative_path}" </dev/null
    rclone copyto "${source_file}" "${R2_REMOTE}/${remote_relative_path}" </dev/null
    ossutil cp -f "${source_file}" "oss://${BUCKET_NAME}/${remote_relative_path}" </dev/null
}

publish_bridge_update() {
    local artifact_dir="${CHAT2DB_UPDATE_ARTIFACT_ROOT}/bridge-update-${PRODUCT_LOWER}"
    local archive="${artifact_dir}/bridge-update.tar.gz"
    local extracted="${PROMOTE_ROOT}/bridge"
    local update_root="${CHAT2DB_RELEASE_ROOT}/updates/${CHAT2DB_RELEASE_VERSION}"
    local pointer="${PROMOTE_ROOT}/latest_version.json"
    local required

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
        echo "Error: the 5.3.3 bridge must not publish lib.zip" >&2
        exit 1
    fi

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
    ossutil cp -f \
        "oss://${BUCKET_NAME}/${CHAT2DB_RELEASE_ROOT}/${version}/${file_name}" \
        "${destination}"
    test -s "${destination}"
}

publish_v2_update() {
    local update_root="${CHAT2DB_RELEASE_ROOT}/updates-v2/${CHANNEL_LOWER}/${CHAT2DB_RELEASE_VERSION}"
    local base_url="https://cdn.chat2db-ai.com/${update_root}"
    local generated="${PUBLISH_ROOT}/updates-v2"
    local rollback_root="${PROMOTE_ROOT}/rollback-installers"
    local previous_index="${PROMOTE_ROOT}/previous-release-index.json"
    local product_display current_file rollback_file package_type arch launcher manifest
    local current_path rollback_path rollback_url target
    local manifests=()
    local current_files=()
    local rollback_files=()
    local previous_index_environment=()

    if [ -z "${CHAT2DB_UPDATE_SIGNING_PRIVATE_KEY_B64:-}" ]; then
        echo "Error: CHAT2DB_UPDATE_SIGNING_PRIVATE_KEY_B64 is required for versioned-thin" >&2
        exit 1
    fi
    mkdir -p "${generated}" "${rollback_root}"
    if [ "${CHAT2DB_PRODUCT}" = "PRO" ]; then
        product_display="Chat2DB Pro"
    else
        product_display="Chat2DB Local"
    fi

    for target in macos-x64 macos-arm64; do
        if [ "${target}" = "macos-x64" ]; then arch=X64; else arch=ARM64; fi
        current_path="${CHAT2DB_UPDATE_ARTIFACT_ROOT}/full-package-${PRODUCT_LOWER}-${target}/full-package-${target}.tar.gz"
        test -s "${current_path}"
        CHAT2DB_UPDATE_SIGNING_PRIVATE_KEY_B64="${CHAT2DB_UPDATE_SIGNING_PRIVATE_KEY_B64}" \
        CHAT2DB_UPDATE_KEY_ID="${CHAT2DB_UPDATE_KEY_ID}" \
        CHAT2DB_UPDATE_PUBLIC_KEY_B64="${CHAT2DB_UPDATE_PUBLIC_KEY_B64}" \
            bash "${CHAT2DB_ENTERPRISE_ROOT}/script/package/generate_update_v2.sh" \
                "${CHAT2DB_RELEASE_VERSION}" "${CHAT2DB_PRODUCT}" "${CHAT2DB_RELEASE_CHANNEL}" \
                MACOS "${arch}" MACOS_APP_ARCHIVE "${current_path}" \
                "Contents/MacOS/${product_display}" "${generated}" "${base_url}" \
                "${CHAT2DB_RELEASE_EPOCH}" "${CHAT2DB_DATA_SCHEMA_VERSION}" \
                "${CHAT2DB_ROLLBACK_COMPATIBLE_FROM}" "${CHAT2DB_ENTERPRISE_SHA}" \
                "${CHAT2DB_RELEASE_NOTES_URL}"
        manifest="${generated}/manifest-${PRODUCT_LOWER}-macos-$(printf '%s' "${arch}" | tr '[:upper:]' '[:lower:]')-macos-app-archive.json"
        test -s "${manifest}"
        manifests+=("${manifest}")
    done

    current_file="${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_RELEASE_VERSION}.exe"
    rollback_file="${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_ROLLBACK_COMPATIBLE_FROM}.exe"
    current_path="${INSTALLER_ROOT}/${current_file}"
    rollback_path="${rollback_root}/${rollback_file}"
    download_release_artifact "${CHAT2DB_RELEASE_VERSION}" "${current_file}" "${current_path}"
    download_release_artifact "${CHAT2DB_ROLLBACK_COMPATIBLE_FROM}" "${rollback_file}" "${rollback_path}"
    rollback_url="https://cdn.chat2db-ai.com/${CHAT2DB_RELEASE_ROOT}/${CHAT2DB_ROLLBACK_COMPATIBLE_FROM}/${rollback_file}"
    CHAT2DB_UPDATE_ROLLBACK_PACKAGE_FILE="${rollback_path}" \
    CHAT2DB_UPDATE_ROLLBACK_PACKAGE_URL="${rollback_url}" \
    CHAT2DB_UPDATE_SIGNING_PRIVATE_KEY_B64="${CHAT2DB_UPDATE_SIGNING_PRIVATE_KEY_B64}" \
    CHAT2DB_UPDATE_KEY_ID="${CHAT2DB_UPDATE_KEY_ID}" \
    CHAT2DB_UPDATE_PUBLIC_KEY_B64="${CHAT2DB_UPDATE_PUBLIC_KEY_B64}" \
        bash "${CHAT2DB_ENTERPRISE_ROOT}/script/package/generate_update_v2.sh" \
            "${CHAT2DB_RELEASE_VERSION}" "${CHAT2DB_PRODUCT}" "${CHAT2DB_RELEASE_CHANNEL}" \
            WINDOWS X64 WINDOWS_EXE "${current_path}" "${product_display}.exe" \
            "${generated}" "${base_url}" "${CHAT2DB_RELEASE_EPOCH}" "${CHAT2DB_DATA_SCHEMA_VERSION}" \
            "${CHAT2DB_ROLLBACK_COMPATIBLE_FROM}" "${CHAT2DB_ENTERPRISE_SHA}" \
            "${CHAT2DB_RELEASE_NOTES_URL}"
    manifest="${generated}/manifest-${PRODUCT_LOWER}-windows-x64-windows-exe.json"
    test -s "${manifest}"
    manifests+=("${manifest}")

    for target in linux-x64 linux-arm64; do
        if [ "${target}" = "linux-x64" ]; then
            arch=X64
            current_files=(
                "${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_RELEASE_VERSION}-x86_64.AppImage:LINUX_APPIMAGE"
                "${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_RELEASE_VERSION}-amd64.deb:LINUX_DEB"
                "${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_RELEASE_VERSION}-x86_64.rpm:LINUX_RPM"
            )
            rollback_files=(
                "${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_ROLLBACK_COMPATIBLE_FROM}-x86_64.AppImage"
                "${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_ROLLBACK_COMPATIBLE_FROM}-amd64.deb"
                "${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_ROLLBACK_COMPATIBLE_FROM}-x86_64.rpm"
            )
        else
            arch=ARM64
            current_files=(
                "${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_RELEASE_VERSION}-arm64.AppImage:LINUX_APPIMAGE"
                "${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_RELEASE_VERSION}-arm64.deb:LINUX_DEB"
                "${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_RELEASE_VERSION}-aarch64.rpm:LINUX_RPM"
            )
            rollback_files=(
                "${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_ROLLBACK_COMPATIBLE_FROM}-arm64.AppImage"
                "${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_ROLLBACK_COMPATIBLE_FROM}-arm64.deb"
                "${CHAT2DB_PRODUCT_APP_NAME}-${CHAT2DB_ROLLBACK_COMPATIBLE_FROM}-aarch64.rpm"
            )
        fi
        for index in 0 1 2; do
            current_file="${current_files[$index]%%:*}"
            package_type="${current_files[$index]##*:}"
            rollback_file="${rollback_files[$index]}"
            current_path="${INSTALLER_ROOT}/${current_file}"
            download_release_artifact "${CHAT2DB_RELEASE_VERSION}" "${current_file}" "${current_path}"
            rollback_path=""
            rollback_url=""
            launcher="bin/${product_display}"
            if [ "${package_type}" = "LINUX_APPIMAGE" ]; then
                launcher="."
            else
                rollback_path="${rollback_root}/${rollback_file}"
                download_release_artifact \
                    "${CHAT2DB_ROLLBACK_COMPATIBLE_FROM}" "${rollback_file}" "${rollback_path}"
                rollback_url="https://cdn.chat2db-ai.com/${CHAT2DB_RELEASE_ROOT}/${CHAT2DB_ROLLBACK_COMPATIBLE_FROM}/${rollback_file}"
            fi
            CHAT2DB_UPDATE_ROLLBACK_PACKAGE_FILE="${rollback_path}" \
            CHAT2DB_UPDATE_ROLLBACK_PACKAGE_URL="${rollback_url}" \
            CHAT2DB_UPDATE_SIGNING_PRIVATE_KEY_B64="${CHAT2DB_UPDATE_SIGNING_PRIVATE_KEY_B64}" \
            CHAT2DB_UPDATE_KEY_ID="${CHAT2DB_UPDATE_KEY_ID}" \
            CHAT2DB_UPDATE_PUBLIC_KEY_B64="${CHAT2DB_UPDATE_PUBLIC_KEY_B64}" \
                bash "${CHAT2DB_ENTERPRISE_ROOT}/script/package/generate_update_v2.sh" \
                    "${CHAT2DB_RELEASE_VERSION}" "${CHAT2DB_PRODUCT}" "${CHAT2DB_RELEASE_CHANNEL}" \
                    LINUX "${arch}" "${package_type}" "${current_path}" "${launcher}" \
                    "${generated}" "${base_url}" "${CHAT2DB_RELEASE_EPOCH}" \
                    "${CHAT2DB_DATA_SCHEMA_VERSION}" "${CHAT2DB_ROLLBACK_COMPATIBLE_FROM}" \
                    "${CHAT2DB_ENTERPRISE_SHA}" "${CHAT2DB_RELEASE_NOTES_URL}"
            manifest="${generated}/manifest-${PRODUCT_LOWER}-linux-$(printf '%s' "${arch}" | tr '[:upper:]' '[:lower:]')-$(printf '%s' "${package_type}" | tr '[:upper:]' '[:lower:]' | tr '_' '-').json"
            test -s "${manifest}"
            manifests+=("${manifest}")
        done
    done

    if ossutil cp -f \
        "oss://${BUCKET_NAME}/${CHAT2DB_RELEASE_ROOT}/updates-v2/${CHANNEL_LOWER}/latest_version.json" \
        "${previous_index}" >/dev/null 2>&1; then
        test -s "${previous_index}"
        previous_index_environment+=("CHAT2DB_PREVIOUS_UPDATE_INDEX=${previous_index}")
    fi
    env "${previous_index_environment[@]}" \
        bash "${CHAT2DB_ENTERPRISE_ROOT}/script/package/generate_update_index_v2.sh" \
            "${CHAT2DB_RELEASE_CHANNEL}" "${CHAT2DB_RELEASE_EPOCH}" "${base_url}" \
            "${generated}/release-index.json" "${manifests[@]}"

    while IFS= read -r file; do
        upload_immutable "${file}" "${update_root}/$(basename "${file}")"
    done < <(find "${generated}" -maxdepth 1 -type f -print | LC_ALL=C sort)

    if [ "${CHAT2DB_UPDATE_LATEST_VERSION_JSON}" = "true" ]; then
        upload_mutable "${generated}/release-index.json" \
            "${CHAT2DB_RELEASE_ROOT}/updates-v2/${CHANNEL_LOWER}/latest_version.json"
    fi
}

download_installer() {
    local file_name="$1"
    local destination="${INSTALLER_ROOT}/${file_name}"
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

    for mapping in "${mappings[@]}"; do
        source_file="${mapping%%::*}"
        destination="${mapping##*::}"
        upload_mutable \
            "${INSTALLER_ROOT}/${source_file}" \
            "${CHAT2DB_RELEASE_ROOT}/latest/${destination}"
    done
    for mapping in "${linux_mappings[@]}"; do
        source_file="${mapping%%::*}"
        destination="${mapping##*::}"
        upload_mutable \
            "${INSTALLER_ROOT}/${source_file}" \
            "${CHAT2DB_RELEASE_ROOT}/latest/linux/${destination}/${source_file}"
    done
}

if [ "${CHAT2DB_RELEASE_PROFILE}" = "bridge-fat" ] \
        && [ "${CHAT2DB_RELEASE_CHANNEL}" = "STABLE" ]; then
    publish_bridge_update
else
    publish_v2_update
fi

if [ "${CHAT2DB_UPLOAD_LATEST}" = "true" ]; then
    publish_latest_installers
fi

echo "Desktop release promotion completed."
