#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Given a GitHub repo + PR, show which tags contain the PR merge commit
#          and any auto-generated backport PRs' merge commits.
# Author:  you (+ a friendly assist)
# Requires: bash, git, gh; optionally gum or fzf for interactive selection

set -Eeuo pipefail

#######################################
# Pretty logging
#######################################
COLOR=${NO_COLOR:-}
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[34m'; MAG=$'\033[35m'; CYA=$'\033[36m'; BLD=$'\033[1m'; RST=$'\033[0m'
else
    RED=""; GRN=""; YLW=""; BLU=""; MAG=""; CYA=""; BLD=""; RST=""
fi

log()   { printf '%s\n' "$*"; }
info()  { printf "${BLD}${CYA}ℹ${RST} %s\n" "$*"; }
ok()    { printf "${BLD}${GRN}✓${RST} %s\n" "$*"; }
warn()  { printf "${BLD}${YLW}!${RST} %s\n" "$*"; }
err()   { printf "${BLD}${RED}✗${RST} %s\n" "$*" >&2; }
die()   { err "$*"; exit 1; }

#######################################
# Defaults & globals
#######################################
OWNER="hashicorp"
REPO=""
PR_NUM=""
CACHE_DIR="${HOME}/.patches"
CACHE_REPOLIST="${CACHE_DIR}/repos.txt"
USE_SSH=true
REFRESH=false
ASSUME_YES=false

WORKDIR=""
CLEANUP() { [[ -n "${WORKDIR}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"; }
trap CLEANUP EXIT

#######################################
# Helpers
#######################################
have() { command -v "$1" >/dev/null 2>&1; }

confirm() {
    local msg="$1"
    if $ASSUME_YES; then return 0; fi

    if have gum; then gum confirm "$msg"
    else
        read -r -p "$msg [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]]
    fi
}

choose_from_stdin() {
    # chooses a line from stdin using gum, else fzf, else numeric prompt
    if have gum; then
        gum filter
    elif have fzf; then
        fzf --ansi --height=20 --reverse
    else
        # Build array and prompt
        mapfile -t arr
        local i=1
        for item in "${arr[@]}"; do printf "%2d) %s\n" "$i" "$item"; ((i++)); done
        read -r -p "> choose number: " n
        [[ "$n" =~ ^[0-9]+$ ]] || die "Invalid selection"
        (( n>=1 && n<=${#arr[@]} )) || die "Out of range"
        printf '%s\n' "${arr[$((n-1))]}"
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --owner <org>        GitHub org/owner (default: ${OWNER})
  --repo  <repo>       Repository name (e.g. consul) [if omitted, picker opens]
  --pr    <number>     PR number (required if non-interactive)
  --https              Use https URL when cloning (default: SSH)
  --ssh                Use SSH URL when cloning (default)
  --refresh            Refresh cached repo list
  --yes                Assume "yes" to prompts (non-interactive)
  -h, --help           Show this help

Examples:
  $(basename "$0") --repo consul --pr 19999
  $(basename "$0") --owner hashicorp --repo vault --pr 23456 --https --yes
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --owner)   OWNER="$2"; shift 2 ;;
        --repo)    REPO="$2"; shift 2 ;;
        --pr)      PR_NUM="$2"; shift 2 ;;
        --https)   USE_SSH=false; shift ;;
        --ssh)     USE_SSH=true; shift ;;
        --refresh) REFRESH=true; shift ;;
        --yes)     ASSUME_YES=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1";;
        esac
    done
}

ensure_deps() {
    for bin in gh git; do
        have "$bin" || die "Missing dependency: $bin"
    done

    # nice to have: gum/fzf
    if ! have gum && ! have fzf; then
        warn "Neither 'gum' nor 'fzf' found; falling back to basic selection UI."
    fi
}

gh_auth() {
    if ! gh auth status >/dev/null 2>&1; then
        confirm "GitHub CLI not logged in. Login now?" && gh auth login || die "GitHub auth required."
    fi
}

ensure_cache() { mkdir -p "${CACHE_DIR}"; }

refresh_repo_list() {
    info "Fetching list of repos for ${OWNER}..."
    # NOTE: gh limits 1000; we paginate by calling twice if needed
    # Many orgs <1000 anyway. For >1000, raise --limit if you like.
    gh repo list "${OWNER}" --limit 2000 --json name --jq '"'"${OWNER}/"'" + .[].name' \
      > "${CACHE_REPOLIST}"
    ok "Repo list cached: ${CACHE_REPOLIST}"
}

pick_repo() {
    ensure_cache
    if $REFRESH || [[ ! -s "${CACHE_REPOLIST}" ]]; then
        refresh_repo_list
    fi
    REPO_FULL="$(cat "${CACHE_REPOLIST}" | choose_from_stdin)"
    [[ -n "${REPO_FULL}" ]] || die "No repository selected."
    # split owner/repo
    OWNER="${REPO_FULL%%/*}"
    REPO="${REPO_FULL##*/}"
}

resolve_repo_url() {
    local json_field
    json_field=$($USE_SSH && echo 'sshUrl' || echo 'url')
    gh repo view "${OWNER}/${REPO}" --json "$json_field" --jq ".${json_field}"
}

get_pr_merge_commit() {
    local repo="$1" pr="$2"
    gh pr view --repo "$repo" "$pr" --json mergeCommit,title,number --jq '.mergeCommit.oid'
}

confirm_pr() {
    local repo="$1" pr="$2"
    local summary
    summary="$(gh pr view --repo "$repo" "$pr" --json number,mergeCommit,title --jq '["#"+(.number|tostring), (.title // "no-title")] | join(" - ")' || true)"
    [[ -n "$summary" ]] || die "PR #$pr not found in ${repo}."
    info "PR: ${summary}"
    if ! $ASSUME_YES; then
        confirm "Is this the correct PR?" || die "Aborted."
    fi
}

find_backport_pr_numbers() {
    local repo="$1" pr="$2"
    # Matches the standard "auto-generated from #<PR>" line used by backport bots
    gh search prs --repo "$repo" --match body "auto-generated from #$pr" --json number --jq '.[].number' || true
}

git_clone_treeless_bare() {
    local url="$1"
    WORKDIR="${CACHE_DIR}/${REPO}.git"
    if [[ -d "${WORKDIR}" ]]; then
        if confirm "Found existing bare clone (${WORKDIR}). Refresh it (delete & reclone)?"; then
            rm -rf "${WORKDIR}"
        fi
    fi

    if [[ ! -d "${WORKDIR}" ]]; then
        info "Cloning (bare, partial) ${OWNER}/${REPO}..."
        # Bare + partial clone. Tags sometimes need explicit fetch later.
        git clone --bare --filter=blob:none --progress "$url" "${WORKDIR}"
    else
        info "Reusing existing clone: ${WORKDIR}"
    fi

    # Ensure tags are present (partial clone can miss them)
    ( cd "${WORKDIR}" && git fetch --tags --prune --quiet )
}

tags_containing_commit() {
    local commit="$1"
    ( cd "${WORKDIR}" && git tag --contains "$commit" || true )
}

dedupe_sort() {
    awk 'NF' | sort -u
}

format_list_bullets() {
    # pretty output with bullets; if gum exists, let gum format them
    if have gum; then
        gum format "$(awk '{print "* " $0}')"
    else
        awk '{print " - " $0}'
    fi
}

#######################################
# Main
#######################################
parse_args "$@"
ensure_deps
gh_auth
ensure_cache

# repo selection
if [[ -z "${REPO:-}" ]]; then
    info "Pick a repository from ${OWNER}…"
    pick_repo
else
    # normalize OWNER/REPO if user passed "owner/repo" to --repo by mistake
    if [[ "$REPO" == */* ]]; then
        OWNER="${REPO%%/*}"
        REPO="${REPO##*/}"
    fi
fi

REPO_SLUG="${OWNER}/${REPO}"
REPO_URL="$(resolve_repo_url)"

# PR selection
if [[ -z "${PR_NUM:-}" ]]; then
    if $ASSUME_YES; then
        die "--pr is required for non-interactive runs (use --yes)."
    fi
    if have gum; then
        PR_NUM="$(gum input --placeholder "Enter PR number" --prompt "> #")"
    else
        read -r -p "> PR number: #" PR_NUM
    fi
fi

[[ "$PR_NUM" =~ ^[0-9]+$ ]] || die "Invalid PR number: ${PR_NUM}"

confirm_pr "$REPO_SLUG" "$PR_NUM"

# Main PR merge commit
MAIN_COMMIT="$(get_pr_merge_commit "$REPO_SLUG" "$PR_NUM")"
[[ -n "${MAIN_COMMIT}" && "${MAIN_COMMIT}" != "null" ]] || die "PR has no merge commit (maybe not merged yet?)."

ok "Main PR merge commit: ${MAIN_COMMIT}"

# Backport PRs (auto-generated pattern)
BP_PRS="$(find_backport_pr_numbers "$REPO_SLUG" "$PR_NUM" || true)"
if [[ -n "${BP_PRS}" ]]; then
    info "Found backport PRs: $(tr '\n' ' ' <<< "${BP_PRS}")"
else
    warn "No auto-generated backport PRs found."
fi

# Gather merge commits (main + backports)
MERGE_COMMITS=("${MAIN_COMMIT}")
if [[ -n "${BP_PRS}" ]]; then
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        c="$(get_pr_merge_commit "$REPO_SLUG" "$n" || true)"
        [[ -n "$c" && "$c" != "null" ]] && MERGE_COMMITS+=("$c") && ok "Backport #$n merge commit: $c"
    done <<< "${BP_PRS}"
fi

# Clone (bare, partial) & ensure tags
git_clone_treeless_bare "$REPO_URL"

# Compute union of tags that contain any of the merge commits
info "Looking up tags that contain the merge commit(s)…"
{
    for c in "${MERGE_COMMITS[@]}"; do
        tags_containing_commit "$c"
    done
} | dedupe_sort > "${CACHE_DIR}/_tags.tmp"

echo
if [[ -s "${CACHE_DIR}/_tags.tmp" ]]; then
    info "Found the following tags:"
    format_list_bullets < "${CACHE_DIR}/_tags.tmp"
else
    warn "No matching tags found. Check if the PR was cherry-picked without tagging or if tags are private."
fi
