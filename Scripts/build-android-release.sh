#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

required_environment=(
    FO_PUBLIC_SUPABASE_URL
    FO_PUBLIC_SUPABASE_KEY
    FO_PUBLIC_GOOGLE_CLIENT_ID
    FO_ANDROID_UPLOAD_KEYSTORE_PATH
    FO_ANDROID_UPLOAD_KEY_ALIAS
    FO_ANDROID_UPLOAD_STORE_PASSWORD
    FO_ANDROID_UPLOAD_KEY_PASSWORD
)

for variable_name in "${required_environment[@]}"; do
    if [[ -z "${!variable_name:-}" ]]; then
        echo "Android release configuration is incomplete: ${variable_name}." >&2
        exit 1
    fi
done

if [[ ! -f "${FO_ANDROID_UPLOAD_KEYSTORE_PATH}" ]]; then
    echo "Android release configuration is incomplete: upload keystore file." >&2
    exit 1
fi

android_java_home="${JAVA_HOME:-}"
if [[ ! -x "${android_java_home}/bin/java" ]] && [[ -x /usr/libexec/java_home ]]; then
    android_java_home=$(/usr/libexec/java_home -v 17 2>/dev/null || true)
fi
if [[ ! -x "${android_java_home}/bin/java" ]] ||
   ! "${android_java_home}/bin/java" -version 2>&1 | head -1 | grep -Eq 'version "17([."]|$)'; then
    echo "Android release builds require JDK 17." >&2
    exit 1
fi

export JAVA_HOME="${android_java_home}"

./gradlew :androidApp:bundleRelease --no-daemon

release_bundle="Apps/Android/build/outputs/bundle/release/androidApp-release.aab"
if [[ ! -s "${release_bundle}" ]]; then
    echo "Android release bundle was not produced." >&2
    exit 1
fi

if ! jarsigner -verify "${release_bundle}" >/dev/null 2>&1; then
    echo "Android release bundle signature verification failed." >&2
    exit 1
fi

echo "Signed Android release bundle verified."
