#!/usr/bin/env sh

# Trigger and monitor the Granblue Fantasy Relink packaging workflow.
# Requirements: git, GitHub CLI (gh), and an authenticated gh session.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT" || exit 1

WORKFLOW=${GBFR_WORKFLOW:-build_gbfr.yml}
REPOSITORY=${GBFR_REPOSITORY:-EdwardHamu/Luma-Framework}
CONFIGURATION=${1:-${GBFR_CONFIGURATION:-Publishing-Release}}
REF=${2:-${GBFR_REF:-}}
REMOTE=${GBFR_REMOTE:-https://github.com/EdwardHamu/Luma-Framework.git}
MAX_RETRIES=${GBFR_MAX_RETRIES:-5}
RETRY_DELAY=${GBFR_RETRY_DELAY:-5}
POLL_INTERVAL=${GBFR_POLL_INTERVAL:-15}
DISCOVERY_TIMEOUT=${GBFR_DISCOVERY_TIMEOUT:-120}

usage() {
    printf 'Usage: %s [configuration] [ref]\n' "$(basename "$0")"
    printf '  configuration: Publishing-Release, Test-Release, or Development-Release\n'
    printf '  ref:          branch or tag; defaults to the current branch\n'
    printf '\nEnvironment overrides: GBFR_REPOSITORY, GBFR_REMOTE, GBFR_MAX_RETRIES, GBFR_RETRY_DELAY, GBFR_POLL_INTERVAL, GBFR_DISCOVERY_TIMEOUT\n'
}

die() {
    printf '[error] %s\n' "$*" >&2
    exit 1
}

is_non_negative_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

case "$CONFIGURATION" in
    Publishing-Release|Test-Release|Development-Release) ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        die "Unsupported configuration: $CONFIGURATION"
        ;;
esac

if [ -z "$REF" ]; then
    REF=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
fi
[ -n "$REF" ] || REF=main

DISCOVERY_BRANCH=$REF
case "$DISCOVERY_BRANCH" in
    refs/heads/*) DISCOVERY_BRANCH=${DISCOVERY_BRANCH#refs/heads/} ;;
    refs/tags/*) DISCOVERY_BRANCH= ;;
esac

is_non_negative_integer "$MAX_RETRIES" || die 'GBFR_MAX_RETRIES must be a positive integer'
[ "$MAX_RETRIES" -gt 0 ] || die 'GBFR_MAX_RETRIES must be a positive integer'
is_non_negative_integer "$RETRY_DELAY" || die 'GBFR_RETRY_DELAY must be a non-negative integer'
is_non_negative_integer "$POLL_INTERVAL" || die 'GBFR_POLL_INTERVAL must be a non-negative integer'
is_non_negative_integer "$DISCOVERY_TIMEOUT" || die 'GBFR_DISCOVERY_TIMEOUT must be a non-negative integer'

[ -f ".github/workflows/$WORKFLOW" ] || die "Workflow not found: .github/workflows/$WORKFLOW"
command -v gh >/dev/null 2>&1 || die 'GitHub CLI (gh) is required; install it and run gh auth login'
command -v git >/dev/null 2>&1 || die 'git is required'

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    printf '[%s] %s\n' "$(timestamp)" "$*"
}

# Network calls can fail transiently while pushing, dispatching, or reading Actions state.
retry_command() {
    retry_attempt=1
    while [ "$retry_attempt" -le "$MAX_RETRIES" ]; do
        retry_error_file=$(mktemp "${TMPDIR:-/tmp}/gbfr-gh.XXXXXX") || return 1
        if retry_output=$("$@" 2>"$retry_error_file"); then
            rm -f "$retry_error_file"
            printf '%s\n' "$retry_output"
            return 0
        fi

        retry_error=$(cat "$retry_error_file")
        rm -f "$retry_error_file"
        if [ "$retry_attempt" -eq "$MAX_RETRIES" ]; then
            [ -n "$retry_error" ] && printf '%s\n' "$retry_error" >&2
            return 1
        fi

        retry_wait=$((RETRY_DELAY * retry_attempt))
        printf '[retry %s/%s] GitHub CLI failed; retrying in %ss\n' \
            "$retry_attempt" "$MAX_RETRIES" "$retry_wait" >&2
        [ -n "$retry_error" ] && printf '%s\n' "$retry_error" >&2
        sleep "$retry_wait"
        retry_attempt=$((retry_attempt + 1))
    done
    return 1
}

notify_user() {
    notify_title=$1
    notify_message=$2

    if command -v notify-send >/dev/null 2>&1; then
        notify-send "$notify_title" "$notify_message" >/dev/null 2>&1 && return 0
    fi

    if [ "$(uname -s 2>/dev/null || printf unknown)" = Darwin ] && command -v osascript >/dev/null 2>&1; then
        osascript - "$notify_title" "$notify_message" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
    display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
        [ "$?" -eq 0 ] && return 0
    fi

    # Windows Git Bash and WSL can use the built-in PowerShell dialog.
    for notify_powershell in powershell.exe powershell pwsh; do
        if command -v "$notify_powershell" >/dev/null 2>&1; then
            if GBFR_NOTIFY_TITLE="$notify_title" GBFR_NOTIFY_MESSAGE="$notify_message" \
                "$notify_powershell" -NoLogo -NonInteractive -Command \
                'Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show($env:GBFR_NOTIFY_MESSAGE, $env:GBFR_NOTIFY_TITLE) | Out-Null' \
                >/dev/null 2>&1; then
                return 0
            fi
        fi
    done

    printf '[notification] %s: %s\n' "$notify_title" "$notify_message" >&2
    return 0
}

list_runs() {
    # A branch filter keeps a concurrent workflow on another ref from being selected.
    if [ -n "$DISCOVERY_BRANCH" ]; then
        retry_command gh run list \
            --repo "$REPOSITORY" \
            --workflow "$WORKFLOW" \
            --branch "$DISCOVERY_BRANCH" \
            --event workflow_dispatch \
            --limit 20 \
            --json databaseId,createdAt \
            --jq '.[] | [.databaseId, .createdAt] | @tsv'
    else
        retry_command gh run list \
            --repo "$REPOSITORY" \
            --workflow "$WORKFLOW" \
            --event workflow_dispatch \
            --limit 20 \
            --json databaseId,createdAt \
            --jq '.[] | [.databaseId, .createdAt] | @tsv'
    fi
}

find_new_run() {
    find_runs=$1
    find_previous_id=$2
    find_dispatch_started=$3

    printf '%s\n' "$find_runs" | while IFS="$(printf '\t')" read -r find_id find_created_at; do
        [ -n "$find_id" ] || continue
        if [ "$find_id" = "$find_previous_id" ]; then
            continue
        fi
        if [ "$find_created_at" = "$find_dispatch_started" ] || [ "$find_created_at" \> "$find_dispatch_started" ]; then
            printf '%s\n' "$find_id"
            break
        fi
    done
}

render_progress() {
    render_snapshot=$1
    render_run_line=$(printf '%s\n' "$render_snapshot" | sed -n '1p')
    IFS="$(printf '\t')" read -r render_marker render_status render_conclusion render_url <<EOF
$render_run_line
EOF

    if [ "$render_conclusion" = - ]; then
        log "Workflow status: $render_status"
    else
        log "Workflow status: $render_status ($render_conclusion)"
    fi
    render_steps=$(printf '%s\n' "$render_snapshot" | sed '1d')
    if [ -n "$render_steps" ]; then
        printf '%s\n' "$render_steps" | while IFS="$(printf '\t')" read -r render_step_marker render_job render_step render_step_status render_step_conclusion; do
            [ "$render_step_marker" = STEP ] || continue
            render_display_status=$render_step_status
            [ "$render_step_status" = completed ] && render_display_status=$render_step_conclusion
            printf '  [%s] %s / %s\n' "$render_display_status" "$render_job" "$render_step"
        done
    fi
}

log "Workflow: $WORKFLOW"
log "Configuration: $CONFIGURATION"
log "Ref: $REF"

log "Pushing $REF to $REMOTE..."
retry_command git push "$REMOTE" "$REF" \
    || die "Unable to push $REF to $REMOTE"

previous_runs=$(list_runs) || die 'Unable to query existing workflow runs'
previous_run_id=$(printf '%s\n' "$previous_runs" | sed -n '1p' | cut -f1)

dispatch_started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
log 'Dispatching workflow...'
retry_command gh workflow run "$WORKFLOW" --repo "$REPOSITORY" --ref "$REF" -f "configuration=$CONFIGURATION" >/dev/null \
    || die 'Unable to dispatch workflow; check gh auth status and repository permissions'

log 'Waiting for GitHub to register the new run...'
run_id=
discovery_started=$(date '+%s')
while [ -z "$run_id" ]; do
    current_runs=$(list_runs) || die 'Unable to query workflow runs'
    run_id=$(find_new_run "$current_runs" "$previous_run_id" "$dispatch_started")
    [ -n "$run_id" ] && break

    discovery_now=$(date '+%s')
    if [ $((discovery_now - discovery_started)) -ge "$DISCOVERY_TIMEOUT" ]; then
        notify_user 'GBFR packaging could not be tracked' 'The workflow was dispatched, but no new run appeared in time.'
        die 'Timed out while locating the dispatched workflow run'
    fi
    sleep "$POLL_INTERVAL"
done

run_url=$(retry_command gh run view "$run_id" --repo "$REPOSITORY" --json url --jq '.url') \
    || die "Unable to read workflow run $run_id"
log "Tracking run #$run_id: $run_url"

last_snapshot=
while :; do
    snapshot=$(retry_command gh run view "$run_id" --repo "$REPOSITORY" \
        --json status,conclusion,url,jobs \
        --jq '(["RUN", .status, (.conclusion // "-"), .url] | @tsv), (.jobs[]? | .name as $job | .steps[]? | (["STEP", $job, .name, .status, (.conclusion // "-")] | @tsv))') \
        || {
            notify_user 'GBFR packaging status unavailable' "Could not read run #$run_id after retries."
            exit 1
        }

    if [ "$snapshot" != "$last_snapshot" ]; then
        render_progress "$snapshot"
        last_snapshot=$snapshot
    fi

    run_line=$(printf '%s\n' "$snapshot" | sed -n '1p')
    IFS="$(printf '\t')" read -r marker status conclusion url <<EOF
$run_line
EOF
    if [ "$status" = completed ]; then
        break
    fi
    sleep "$POLL_INTERVAL"
done

case "$conclusion" in
    success)
        notify_user 'GBFR packaging completed' "Run #$run_id succeeded. $run_url"
        log "Packaging completed successfully: $run_url"
        exit 0
        ;;
    *)
        notify_user 'GBFR packaging failed' "Run #$run_id finished with ${conclusion:-unknown}. $run_url"
        log "Packaging finished with ${conclusion:-unknown}: $run_url"
        exit 1
        ;;
esac
