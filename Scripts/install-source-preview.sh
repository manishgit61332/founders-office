#!/bin/zsh

set -euo pipefail
umask 077

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
install_root=""
launch_after_install=1
expected_commit=""

usage() {
    cat <<'EOF'
Usage: Scripts/install-source-preview.sh [--expected-commit SHA] [--install-root PATH] [--no-launch]

Builds Founder’s Office from this checkout, ad-hoc signs it on this Mac, and
installs it for the current user. This is a source-based Development preview.
It is not a signed or notarized Beta, and its .app bundle must not be shared.

Requirements:
  - macOS 14 or later
  - Apple Command Line Tools with Swift
  - a clean Git checkout that you intend to trust and run

Options:
  --expected-commit SHA  Refuse to install unless HEAD is this full commit SHA.
  --install-root PATH  Install into PATH instead of ~/Applications.
  --no-launch          Install but do not open the app.
  --help               Show this help text.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --expected-commit)
            if (( $# < 2 )) || [[ ! "$2" =~ '^[0-9a-fA-F]{40}$' ]]; then
                print -u2 -- "--expected-commit requires a full 40-character Git commit SHA."
                exit 64
            fi
            expected_commit="${2:l}"
            shift
            ;;
        --install-root)
            if (( $# < 2 )) || [[ -z "$2" ]]; then
                print -u2 -- "--install-root requires a non-empty path."
                exit 64
            fi
            if [[ "$2" != /* || "$2" == "/" ]]; then
                print -u2 -- "--install-root must be an absolute directory below the filesystem root."
                exit 64
            fi
            install_root="$2"
            shift
            ;;
        --no-launch)
            launch_after_install=0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            print -u2 "Unknown option: $1"
            usage >&2
            exit 64
            ;;
    esac
    shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    print -u2 "The Mac source preview can be built only on macOS."
    exit 69
fi

macos_version="$(sw_vers -productVersion)"
macos_major="${macos_version%%.*}"
if [[ ! "$macos_major" =~ '^[0-9]+$' ]] || (( macos_major < 14 )); then
    print -u2 "Founder’s Office requires macOS 14 or later; this Mac reports ${macos_version}."
    exit 69
fi

required_commands=(git swift xcrun codesign plutil iconutil)
if (( launch_after_install == 1 )); then
    required_commands+=(open)
fi
if [[ -z "$install_root" ]]; then
    required_commands+=(osascript)
fi
for command_name in "${required_commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        print -u2 "Missing required command: ${command_name}. Install Apple Command Line Tools and retry."
        exit 69
    fi
done

if ! xcrun --find swift >/dev/null 2>&1; then
    print -u2 "Apple Command Line Tools are not ready. Run 'xcode-select --install' yourself, then retry."
    exit 69
fi

if ! git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    print -u2 "This installer must run from a Git checkout of Founder’s Office."
    exit 65
fi

if [[ -n "$(git -C "$project_dir" status --porcelain)" ]]; then
    print -u2 "The checkout has uncommitted files. Review or remove them before running code as a source preview."
    exit 65
fi

commit="$(git -C "$project_dir" rev-parse HEAD)"
if [[ -n "$expected_commit" && "$commit" != "$expected_commit" ]]; then
    print -u2 "Expected commit ${expected_commit}, but this checkout is ${commit}. Nothing was installed."
    exit 65
fi
branch="$(git -C "$project_dir" branch --show-current)"
if [[ -z "$branch" ]]; then
    branch="detached"
fi

"${script_dir}/check-repository-safety.sh"

if [[ -n "$install_root" ]]; then
    FOUNDER_OFFICE_INSTALL_ROOT="$install_root" \
        FOUNDER_OFFICE_RELEASE=0 \
        "${script_dir}/build-app.sh" --install
    installed_app="${install_root%/}/Founder's Office.app"
else
    FOUNDER_OFFICE_RELEASE=0 "${script_dir}/build-app.sh" --install
    user_applications="$(osascript -e 'POSIX path of (path to applications folder from user domain)')"
    installed_app="${user_applications%/}/Founder's Office.app"
fi

if [[ ! -d "$installed_app" ]]; then
    print -u2 "The development app was not installed at the expected path."
    exit 70
fi

codesign --verify --deep --strict --verbose=2 "$installed_app"

channel="$(plutil -extract FounderOfficeDistributionChannel raw "$installed_app/Contents/Info.plist")"
notarized="$(plutil -extract FounderOfficeNotarized raw "$installed_app/Contents/Info.plist")"
workspace="$(plutil -extract OpenLoopsWorkspace raw "$installed_app/Contents/Info.plist")"

if [[ "$channel" != "development" || "$notarized" != "false" || "$workspace" != "$project_dir" ]]; then
    print -u2 "The installed app does not satisfy the source-preview development boundary."
    exit 70
fi

print "Installed Founder’s Office source preview from ${branch} at commit ${commit}."
print "App: ${installed_app}"
print "Keep this checkout: the preview stores its local workspace beside this source tree."
print "To update, review 'git pull --ff-only', then run this installer again."
print "Do not share the .app bundle: it is ad-hoc signed and not notarized."

if (( launch_after_install == 1 )); then
    open "$installed_app"
fi
