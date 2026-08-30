#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."
chmod +x .githooks/pre-push
git config core.hooksPath .githooks

echo "Installed Founder's Office Git hooks."
