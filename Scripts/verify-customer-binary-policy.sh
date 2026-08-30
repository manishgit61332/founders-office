#!/bin/bash

set -euo pipefail
umask 077

readonly script_name="$(basename "$0")"

fail() {
  echo "${script_name}: $*" >&2
  exit 1
}

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
  fail "usage: ${script_name} <customer-executable> [expected-architectures]"
fi

readonly executable="$1"
readonly expected_architectures="${2:-}"
[[ -f "${executable}" && ! -L "${executable}" && -x "${executable}" ]] \
  || fail "customer executable must be a regular executable file"

for command_name in lipo strings otool python3 sort mktemp; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "missing command: ${command_name}"
done

readonly actual_architectures="$(lipo -archs "${executable}" 2>/dev/null)" \
  || fail "customer executable is not a supported Mach-O binary"
read -r -a actual_arch_array <<< "${actual_architectures}"
[[ "${#actual_arch_array[@]}" -gt 0 ]] || fail "customer executable has no architectures"

normalize_architectures() {
  printf '%s\n' "$@" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

if [[ -n "${expected_architectures}" ]]; then
  read -r -a expected_arch_array <<< "${expected_architectures}"
  [[ "${#expected_arch_array[@]}" -gt 0 ]] || fail "expected architectures are empty"
  seen_expected=" "
  for architecture in "${expected_arch_array[@]}"; do
    case "${architecture}" in
      arm64|x86_64) ;;
      *) fail "unsupported expected customer architecture: ${architecture}" ;;
    esac
    [[ "${seen_expected}" != *" ${architecture} "* ]] \
      || fail "duplicate expected customer architecture: ${architecture}"
    seen_expected+="${architecture} "
  done
  [[ "$(normalize_architectures "${actual_arch_array[@]}")" == "$(normalize_architectures "${expected_arch_array[@]}")" ]] \
    || fail "customer executable architectures do not match policy"
fi

readonly work_root="$(mktemp -d "${TMPDIR:-/tmp}/founders-office-binary-policy.XXXXXX")"
cleanup() {
  rm -rf -- "${work_root}"
}
trap cleanup EXIT INT TERM

readonly forbidden_sentinels=(
  "/usr/local/bin/codex"
  "/opt/homebrew/bin/codex"
  "/usr/bin/env"
  "--skip-git-repo-check"
  "--output-last-message"
  "--ephemeral"
  "workspace-write"
  "gpt-5.5"
  "Codex Runs"
  "OPENLOOPS_ROOT"
  "OPENLOOPS_PREVIEW_"
  "OpenLoopsWorkspace"
  "--preview"
  "--snapshot"
  "--motion-frames"
  "--motion-reversal-frames"
)

for architecture in "${actual_arch_array[@]}"; do
  case "${architecture}" in
    arm64|x86_64) ;;
    *) fail "unsupported customer architecture: ${architecture}" ;;
  esac

  architecture_binary="${executable}"
  if [[ "${#actual_arch_array[@]}" -gt 1 ]]; then
    architecture_binary="${work_root}/customer-${architecture}"
    lipo "${executable}" -thin "${architecture}" -output "${architecture_binary}" \
      || fail "could not inspect architecture ${architecture}"
  fi

  strings_file="${work_root}/strings-${architecture}.txt"
  strings -a "${architecture_binary}" > "${strings_file}"
  for sentinel in "${forbidden_sentinels[@]}"; do
    if grep -Fq -- "${sentinel}" "${strings_file}"; then
      fail "${architecture} customer executable contains forbidden Codex/development sentinel: ${sentinel}"
    fi
  done

  # Swift can encode strings of 15 bytes or fewer directly in machine-code
  # immediates. They do not necessarily appear in `strings` output, so inspect
  # each architecture's disassembly and reconstruct adjacent 64-bit constants.
  disassembly_file="${work_root}/disassembly-${architecture}.txt"
  otool -arch "${architecture}" -tvV "${architecture_binary}" > "${disassembly_file}" \
    || fail "could not disassemble architecture ${architecture}"
  decoded_hit="$(python3 - "${disassembly_file}" "${forbidden_sentinels[@]}" <<'PY'
import re
import sys

path = sys.argv[1]
sentinels = [value.encode("utf-8") for value in sys.argv[2:]]
with open(path, encoding="utf-8", errors="replace") as handle:
    lines = handle.readlines()

arm_start = re.compile(r"\bmov\s+x([0-9]+),\s*#0x([0-9a-fA-F]+)(?:\s*;.*)?$")
arm_continue = re.compile(
    r"\bmovk\s+x([0-9]+),\s*#0x([0-9a-fA-F]+),\s*lsl\s*#([0-9]+)(?:\s*;.*)?$"
)
x86_immediate = re.compile(r"\bmovabsq\s+.*##\s*imm\s*=\s*0x([0-9a-fA-F]{1,16})")

chunks: list[bytes] = []
index = 0
while index < len(lines):
    line = lines[index].strip()
    x86_match = x86_immediate.search(line)
    if x86_match:
        chunks.append(int(x86_match.group(1), 16).to_bytes(8, "little"))
        index += 1
        continue

    start_match = arm_start.search(line)
    if not start_match:
        index += 1
        continue

    register = start_match.group(1)
    value = int(start_match.group(2), 16)
    cursor = index + 1
    while cursor < len(lines):
        continuation = arm_continue.search(lines[cursor].strip())
        if not continuation or continuation.group(1) != register:
            break
        immediate = int(continuation.group(2), 16)
        shift = int(continuation.group(3))
        value = (value & ~(0xFFFF << shift)) | (immediate << shift)
        cursor += 1
    chunks.append((value & ((1 << 64) - 1)).to_bytes(8, "little"))
    index = cursor

for chunk_index, first in enumerate(chunks):
    candidates = [first]
    if chunk_index + 1 < len(chunks):
        candidates.append(first + chunks[chunk_index + 1])
    for candidate in candidates:
        for sentinel in sentinels:
            if sentinel in candidate:
                print(sentinel.decode("utf-8"))
                raise SystemExit(0)
PY
)"
  if [[ -n "${decoded_hit}" ]]; then
    fail "${architecture} customer executable contains forbidden immediate Codex/development sentinel: ${decoded_hit}"
  fi
done

echo "Verified customer binary policy for: ${actual_architectures}"
