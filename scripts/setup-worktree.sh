#!/bin/bash
# Ensure all gitignored assets exist — either by symlinking from the main
# worktree (in a git worktree) or by running the download scripts (fresh clone).
# Safe to run multiple times — skips assets that already exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MAIN_WT=$(git -C "${REPO_ROOT}" worktree list --porcelain 2>/dev/null | head -1 | sed 's/worktree //')
IS_WORKTREE=false
if [ "${REPO_ROOT}" != "${MAIN_WT}" ]; then
    IS_WORKTREE=true
fi

# ensure_dir NAME REL_PATH SETUP_COMMAND
#   In a worktree: try symlink from main, fall back to setup command
#   In main repo:  run setup command if missing
ensure_dir() {
    local name="$1"
    local rel_path="$2"
    local setup_cmd="$3"
    local local_path="${REPO_ROOT}/${rel_path}"

    # Remove broken symlinks
    if [ -L "${local_path}" ] && [ ! -d "${local_path}" ]; then
        echo "⚠ ${name} (removing broken symlink)"
        rm "${local_path}"
    elif [ -d "${local_path}" ]; then
        echo "✓ ${name}"
        return 0
    fi

    if [ "${IS_WORKTREE}" = true ] && [ -d "${MAIN_WT}/${rel_path}" ]; then
        mkdir -p "$(dirname "${local_path}")"
        ln -s "${MAIN_WT}/${rel_path}" "${local_path}"
        echo "→ ${name} (symlinked)"
        return 0
    fi

    if [ -n "${setup_cmd}" ]; then
        echo "⬇ ${name} (downloading...)"
        eval "${setup_cmd}"
        return $?
    fi

    echo "✗ ${name} (missing)"
    return 1
}

# ensure_files NAME REL_DIR FILE_LIST SETUP_COMMAND
#   Like ensure_dir but for individual files within a directory
ensure_files() {
    local name="$1"
    local rel_dir="$2"
    local files="$3"
    local setup_cmd="$4"
    local all_exist=true

    for f in ${files}; do
        local local_path="${REPO_ROOT}/${rel_dir}/${f}"
        # Remove broken symlinks
        if [ -L "${local_path}" ] && [ ! -f "${local_path}" ]; then
            rm "${local_path}"
            all_exist=false
            break
        elif [ ! -f "${local_path}" ]; then
            all_exist=false
            break
        fi
    done

    if [ "${all_exist}" = true ]; then
        echo "✓ ${name}"
        return 0
    fi

    if [ "${IS_WORKTREE}" = true ]; then
        local can_symlink=true
        for f in ${files}; do
            if [ ! -f "${MAIN_WT}/${rel_dir}/${f}" ]; then
                can_symlink=false
                break
            fi
        done
        if [ "${can_symlink}" = true ]; then
            mkdir -p "${REPO_ROOT}/${rel_dir}"
            for f in ${files}; do
                ln -sf "${MAIN_WT}/${rel_dir}/${f}" "${REPO_ROOT}/${rel_dir}/${f}"
            done
            echo "→ ${name} (symlinked)"
            return 0
        fi
    fi

    if [ -n "${setup_cmd}" ]; then
        echo "⬇ ${name} (downloading...)"
        eval "${setup_cmd}"
        return $?
    fi

    echo "✗ ${name} (missing)"
    return 1
}

FAILED=0

ensure_dir "Monaco editor" \
    "ConjureDSPExtension/Resources/monaco/vs" \
    "\"${SCRIPT_DIR}/setup-monaco.sh\"" \
    || FAILED=1

ensure_files "xterm.js" \
    "ConjureDSPExtension/Resources/terminal" \
    "xterm.js xterm.css addon-fit.js addon-web-links.js" \
    "\"${SCRIPT_DIR}/setup-xterm.sh\"" \
    || FAILED=1

ensure_dir "uv" \
    "uv-dist" \
    "\"${SCRIPT_DIR}/setup-uv.sh\"" \
    || FAILED=1

ensure_dir "Python 3.14" \
    "rust/python-dist" \
    "\"${REPO_ROOT}/rust/setup-python.sh\"" \
    || FAILED=1

ensure_dir "Rust compiler" \
    "rustc-dist" \
    "\"${SCRIPT_DIR}/setup-rustc.sh\"" \
    || FAILED=1

ensure_files "Local.xcconfig (signing/telemetry)" \
    "Config" \
    "Local.xcconfig" \
    "cp \"${REPO_ROOT}/Config/Local.xcconfig.template\" \"${REPO_ROOT}/Config/Local.xcconfig\" && echo 'note: created Config/Local.xcconfig from template — set DEVELOPMENT_TEAM to your Apple team id before building'" \
    || FAILED=1

if [ "${FAILED}" -ne 0 ]; then
    echo ""
    echo "Some assets could not be set up. Check the errors above."
    exit 1
fi
