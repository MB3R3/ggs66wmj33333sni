#!/bin/bash

echo "########################"
echo "# Fake Commit Generator #"
echo "########################"
echo

set -euo pipefail

# --- Config ---
# Window: past 4 months (~120 days) through today.
DEFAULT_START_DAYS_AGO=120
DEFAULT_END_DAYS_AGO=0
MIN_COMMITS_PER_DAY=1
MAX_COMMITS_PER_DAY=3
# Probability (out of 100) that any given day gets commits.
# 8 = very sparse, only ~1 day per 2 weeks is green.
COMMIT_PROBABILITY=8

# Commit identity. MUST be an email linked to your GitHub account or
# commits will not appear on the contribution graph (grey avatar).
# Use GitHub's noreply email: <ID>+<username>@users.noreply.github.com
GIT_AUTHOR_NAME="Mb3r3"
GIT_AUTHOR_EMAIL="104103852+MB3R3@users.noreply.github.com"

# --- Helpers ---

to_epoch() {
    local input="$1"
    if [[ -z "$input" ]]; then
        echo ""
    elif date -d "$input" +%s &>/dev/null; then
        date -d "$input" +%s
    elif date -d "@$input" +%s &>/dev/null; then
        echo "$input"
    else
        echo ""
    fi
}

random_range() {
    local min=$1 max=$2
    echo $(( min + RANDOM % (max - min + 1) ))
}

# --- Gather input ---
# Modes: --auto/-y (non-interactive defaults), --purge (rewrite history).
AUTO=false
PURGE=false
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --auto|-y) AUTO=true ;;
        --purge)   PURGE=true ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            echo "usage: $0 [--auto|-y] [--purge] [--dry-run]"
            exit 0 ;;
        *)
            echo "error: unknown argument '$arg' (try --help)"
            exit 1 ;;
    esac
done

if [[ "$PURGE" == true ]]; then
    echo ""
    echo "Purge mode: will rewrite history to drop every commit that only"
    echo "touches fixtures/, then force-push with --force-with-lease."
    echo ""
    echo "  NOTE: GitHub counts contributions by commit SHA at push time."
    echo "  Rewriting history creates NEW SHAs; the tiles you already earned"
    echo "  stay counted and may show up as duplicates until GitHub's"
    echo "  background indexing reconciles them (often 24-48h, sometimes never)."
    echo "  This stops further inflation -- it does not give you a blank slate."
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        echo "Dry run: reporting only, nothing will be modified."
        echo ""
        echo "Commits that would be REMOVED:"
        git log --reverse --format="%h  %ad  %s" --date=short HEAD -- fixtures/ | sed 's/^/  /'
        echo ""
        removed=$(git log --format="%H" HEAD -- fixtures/ | grep -c . || true)
        kept=$(( $(git rev-list --count HEAD) - removed ))
        echo "  $removed to remove, $kept to keep."
        exit 0
    fi

    read -rp "Type 'purge' to proceed (anything else aborts): " confirm
    if [[ "$confirm" != "purge" ]]; then
        echo "aborted - nothing changed"
        exit 0
    fi

    echo ""
    echo "Creating safety backup branch 'backup/pre-purge'..."
    git branch -f backup/pre-purge HEAD

    echo "Removing stale refs/original from any earlier rewrite..."
    for r in $(git for-each-ref --format="%(refname)" refs/original/); do
        git update-ref -d "$r"
    done

    echo "Rewriting history (this takes a moment)..."
    # Every fake commit adds only empty files under fixtures/. Dropping that
    # path empties those commits, and --prune-empty drops them entirely,
    # leaving real commits untouched.
    FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch --force \
        --index-filter "git rm -q -r --cached --ignore-unmatch fixtures" \
        --prune-empty \
        --tag-name-filter cat \
        -- main

    echo "Cleaning up rewrite metadata and unreachable objects..."
    for r in $(git for-each-ref --format="%(refname)" refs/original/); do
        git update-ref -d "$r"
    done
    rm -rf .git/refs/original
    git reflog expire --expire=now --all
    git gc --prune=now --quiet

    echo ""
    echo "History rewritten. Remaining commits:"
    git log --oneline --reverse
    echo ""

    if [[ -n "$(git status --porcelain)" ]]; then
        echo "error: working tree not clean after rewrite; refusing to push."
        echo "       resolve manually, then: git push --force-with-lease origin main"
        exit 1
    fi

    echo "Force-pushing to origin/main..."
    if git push --force-with-lease origin main; then
        echo "Done. Restore old history with: git reset --hard backup/pre-purge"
    else
        echo ""
        echo "Push rejected. --force-with-lease refused because origin/main moved"
        echo "since your last fetch. Fetch and inspect before retrying:"
        echo "  git fetch origin && git log --oneline origin/main"
    fi
    exit 0
fi

if [[ "$AUTO" == true ]]; then
    START=$(to_epoch "$(date -d "-${DEFAULT_START_DAYS_AGO} days" -I)")
    END=$(to_epoch "$(date -I)")
    echo "Auto mode: using window -> $(date -d "@$START" -I) to $(date -d "@$END" -I) at ${COMMIT_PROBABILITY}%"
else
    read -rp "Start date? [default: $(date -d "-${DEFAULT_START_DAYS_AGO} days" -I) - past 4 months] : " input_start
    START=$(to_epoch "${input_start:-$(date -d "-${DEFAULT_START_DAYS_AGO} days" -I)}")
    if [[ -z "$START" ]]; then
        echo "error: invalid start date"; exit 1
    fi

    read -rp "End date?   [default: $(date -I)] : " input_end
    END=$(to_epoch "${input_end:-$(date -I)}")
    if [[ -z "$END" ]]; then
        echo "error: invalid end date"; exit 1
    fi

    if (( START > END )); then
        echo "error: start date is after end date"; exit 1
    fi

    read -rp "Commit probability per day (1-100)? [default: $COMMIT_PROBABILITY] : " input_prob
    COMMIT_PROBABILITY=${input_prob:-$COMMIT_PROBABILITY}
fi

# --- Validate git repo ---

if ! git rev-parse --show-toplevel &>/dev/null; then
    echo "error: not inside a git repository"
    exit 1
fi

if [[ -z "$(git config user.name 2>/dev/null)" || -z "$(git config user.email 2>/dev/null)" ]]; then
    echo "error: git user.name or user.email not configured"
    exit 1
fi

# --- Generate ---

echo ""
echo "Generating commits from $(date -d "@$START" -I) to $(date -d "@$END" -I)"
echo "Commit probability per day: ${COMMIT_PROBABILITY}%"
echo "Commits per active day: ${MIN_COMMITS_PER_DAY}-${MAX_COMMITS_PER_DAY}"
echo ""

total_commits=0

for day_epoch in $(seq "$START" 86400 "$END"); do
    # Roll the dice — skip this day?
    roll=$(random_range 1 100)
    if (( roll > COMMIT_PROBABILITY )); then
        continue
    fi

    folder=$(date -d "@$day_epoch" +%Y-%m-%d)
    num_commits=$(random_range "$MIN_COMMITS_PER_DAY" "$MAX_COMMITS_PER_DAY")

    mkdir -p "./fixtures/${folder}"

    for (( c = 1; c <= num_commits; c++ )); do
        # Random time within that day (0-86399 seconds offset)
        random_seconds=$(random_range 0 86399)
        commit_epoch=$(( day_epoch + random_seconds ))
        timestamp=$(date -d "@$commit_epoch" +"%Y-%m-%d_%H-%M-%S")
        filename="${timestamp}_${c}"

        touch "./fixtures/${folder}/${filename}"
        git add "./fixtures/${folder}/${filename}"

        GIT_AUTHOR_NAME="$GIT_AUTHOR_NAME" GIT_AUTHOR_EMAIL="$GIT_AUTHOR_EMAIL" \
        GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL" \
        GIT_AUTHOR_DATE="$commit_epoch" GIT_COMMITTER_DATE="$commit_epoch" \
            git commit -m "${filename}" --quiet

        total_commits=$(( total_commits + 1 ))
    done

    echo "  ${folder}: ${num_commits} commit(s)"
done

echo ""
echo "Done. ${total_commits} total commits created."
