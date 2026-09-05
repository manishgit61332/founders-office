#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

android_java_home="${JAVA_HOME:-}"
if [[ ! -x "${android_java_home}/bin/java" ]] && [[ -x /usr/libexec/java_home ]]; then
    android_java_home=$(/usr/libexec/java_home -v 17 2>/dev/null || true)
fi
if [[ ! -x "${android_java_home}/bin/java" ]] ||
   ! "${android_java_home}/bin/java" -version 2>&1 | head -1 | grep -Eq 'version "17([."]|$)'; then
    echo "Android verification requires JDK 17." >&2
    exit 1
fi

export JAVA_HOME="${android_java_home}"

./gradlew \
    :androidApp:testDebugUnitTest \
    :androidApp:lintDebug \
    :androidApp:assembleDebug \
    :androidApp:assembleDebugAndroidTest \
    --no-daemon

echo "Android development checks passed."
