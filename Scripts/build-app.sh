#!/bin/zsh

set -euo pipefail

# This is intentionally a development-only builder. It uses an ad-hoc
# signature and embeds the current checkout so the local Codex workflow can
# find its development workspace. It must never feed the public download.
if [[ "${FOUNDER_OFFICE_RELEASE:-0}" != "0" ]]; then
    print -u2 "build-app.sh cannot create a distributable release."
    print -u2 "Use Scripts/release-macos.sh for Developer ID signing and notarization."
    exit 64
fi

project_dir="${0:A:h:h}"
bundle_name="Founder's Office"
bundle_dir="${project_dir}/dist/development/${bundle_name}.app"
binary_path="${project_dir}/.build/release/OpenLoops"
executable_name="FoundersOffice"

cd "${project_dir}"
swift build -c release

if [[ -d "${bundle_dir}" ]]; then
    rm -rf "${bundle_dir}"
fi

mkdir -p "${bundle_dir}/Contents/MacOS"
mkdir -p "${bundle_dir}/Contents/Resources"
mkdir -p "${bundle_dir}/Contents/Resources/Fonts"
cp "${binary_path}" "${bundle_dir}/Contents/MacOS/${executable_name}"
cp "${project_dir}/Resources/Info.plist" "${bundle_dir}/Contents/Info.plist"
plutil -replace OpenLoopsWorkspace -string "${project_dir}" "${bundle_dir}/Contents/Info.plist" 2>/dev/null \
    || plutil -insert OpenLoopsWorkspace -string "${project_dir}" "${bundle_dir}/Contents/Info.plist"
plutil -replace FounderOfficeDistributionChannel -string "development" "${bundle_dir}/Contents/Info.plist" 2>/dev/null \
    || plutil -insert FounderOfficeDistributionChannel -string "development" "${bundle_dir}/Contents/Info.plist"
plutil -replace FounderOfficeNotarized -bool false "${bundle_dir}/Contents/Info.plist" 2>/dev/null \
    || plutil -insert FounderOfficeNotarized -bool false "${bundle_dir}/Contents/Info.plist"
cp "${project_dir}/Resources/Fonts/"* "${bundle_dir}/Contents/Resources/Fonts/"
cp "${project_dir}/Apps/macOS/PrivacyInfo.xcprivacy" "${bundle_dir}/Contents/Resources/PrivacyInfo.xcprivacy"
codesign --force --deep --sign - "${bundle_dir}"
codesign --verify --deep --strict --verbose=2 "${bundle_dir}"

if [[ "${1:-}" == "--install" ]]; then
    if [[ -n "${FOUNDER_OFFICE_INSTALL_ROOT:-}" ]]; then
        install_root="${FOUNDER_OFFICE_INSTALL_ROOT}"
    else
        install_root="$(osascript -e 'POSIX path of (path to applications folder from user domain)')"
        install_root="${install_root%/}"
    fi
    install_target="${install_root}/${bundle_name}.app"
    legacy_target="${install_root}/OpenLoops.app"
    backup_root="${project_dir}/install-backups"
    install_stamp="$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "${install_root}"
    mkdir -p "${backup_root}"

    pkill -x OpenLoops 2>/dev/null || true
    pkill -x FoundersOffice 2>/dev/null || true

    staging_root="$(mktemp -d "${install_root}/.founders-office-install.XXXXXX")"
    staging_target="${staging_root}/${bundle_name}.app"
    cp -R "${bundle_dir}" "${staging_target}"
    codesign --force --deep --sign - "${staging_target}"

    if [[ -d "${install_target}" ]]; then
        backup_target="${backup_root}/${bundle_name}.app.previous-${install_stamp}"
        mv "${install_target}" "${backup_target}"
    fi

    if [[ -d "${legacy_target}" ]]; then
        legacy_backup="${backup_root}/OpenLoops.app.migrated-${install_stamp}"
        mv "${legacy_target}" "${legacy_backup}"
    fi

    mv "${staging_target}" "${install_target}"
    rmdir "${staging_root}"
    print "Installed local development build: ${install_target}"
    print "Not for distribution: ad-hoc signed, not notarized, and tied to ${project_dir}"
else
    print "Built local development app: ${bundle_dir}"
    print "Not for distribution: ad-hoc signed, not notarized, and tied to ${project_dir}"
fi
