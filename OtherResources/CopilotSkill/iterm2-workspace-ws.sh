#!/bin/bash
# ws: lets the agent in one iTerm2 session (the orchestrator) run other agents in tabs of the same
# workspace. Installed by iTerm2 > Install Copilot CLI Integration with the iterm2-workspace skill.
#
# The workspace is the orchestrator's window, narrowed to its project: the project tab group its
# tab is in, or else its git repository (or folder). Tabs that ws opens are workers. Their shell
# exports ITERM2_ORCHESTRATOR_ID and their session has user.agentRole=worker, and ws refuses to run
# in either case, so a worker can't open tabs of its own.

set -u

# The installer fills in the it2 that belongs to the iTerm2 that installed this.
IT2="${IT2:-__IT2_PATH__}"
if [ ! -x "$IT2" ]; then
    IT2=""
    for candidate in "$HOME/.config/iterm2/it2" "$HOME/.iterm2/it2" "/Applications/iTerm.app/Contents/Resources/utilities/it2"; do
        if [ -x "$candidate" ]; then
            IT2="$candidate"
            break
        fi
    done
fi
# Tab is whitespace to read, which would merge empty fields, so rows use the unit separator.
SEP=$'\037'
FIELD_FORMAT='\(session.id)\t\(tab.window.id)\t\(tab.id)\t\(tab.projectPath)\t\(session.path)\t\(user.agentRole)\t\(user.orchestratorID)\t\(session.name)\t\(session.jobName)'

die() {
    echo "ws: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: ws <command> [arguments]

  info                         Show this session, its workspace, and its role.
  list                         List the other sessions in the workspace with their status.
  spawn [options]              Open a worker tab and print its session ID.
      --name NAME              Tab name.
      --dir DIR                Working folder (default: the workspace root).
      --agent copilot|claude|shell
                               What to run (default: copilot).
      --prompt TEXT            First prompt for the agent (for shell: a command).
      --flags FLAGS            Extra agent flags (default for copilot: --yolo).
      --focus                  Leave the new tab selected.
  send ID TEXT                 Type TEXT into a session and press Return.
  keys ID TEXT                 Type TEXT without pressing Return (use $'\e' for Esc).
  read ID [LINES]              Print the last LINES lines of a session’s screen (default 40).
  status ID                    Print a session’s status as JSON.
  wait [--timeout SECONDS] ID...
                               Wait until one of the sessions is done, waiting, failed,
                               idle after working, or quiet (not working and its screen
                               unchanged for 20 s), and print its ID and status.
  focus ID                     Select a session’s tab.
  close ID                     Close a worker this session opened.
  release ID                   Stop treating a worker this session opened as a worker.
EOF
}

it2() {
    "$IT2" "$@"
}

quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

my_id() {
    local id="${ITERM_SESSION_ID:-${TERM_SESSION_ID:-}}"
    printf '%s' "${id#*:}"
}

sessions() {
    it2 session list --format "$FIELD_FORMAT" | tr '\t' "$SEP"
}

# Sets ME_*, ROOT and ROOT_KIND from this session's row.
load_me() {
    [ -n "$IT2" ] || die "it2 not found. Install the Copilot CLI integration from the iTerm2 menu, or set IT2."
    ME_ID="$(my_id)"
    [ -n "$ME_ID" ] || die "not running in an iTerm2 session."
    local all row
    all="$(sessions)" || die "can’t reach iTerm2. Is the Python API enabled?"
    row="$(printf '%s\n' "$all" | awk -F"$SEP" -v id="$ME_ID" '$1 == id')"
    [ -n "$row" ] || die "iTerm2 doesn’t know session $ME_ID."
    IFS="$SEP" read -r _ ME_WINDOW ME_TAB ME_PROJECT ME_PATH ME_ROLE ME_PARENT _ _ <<<"$row"
    if [ -n "$ME_PROJECT" ]; then
        ROOT="$ME_PROJECT"
        ROOT_KIND="project"
    else
        local base="${ME_PATH:-$PWD}"
        ROOT="$(git -C "$base" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$base")"
        ROOT_KIND="folder"
    fi
}

is_worker() {
    [ -n "${ITERM2_ORCHESTRATOR_ID:-}" ] || [ "$ME_ROLE" = "worker" ]
}

require_orchestrator() {
    load_me
    if is_worker; then
        die "this session is a worker of orchestrator ${ITERM2_ORCHESTRATOR_ID:-$ME_PARENT}. Workers don’t open or control other sessions; report back to the orchestrator instead."
    fi
    if [ "$ME_ROLE" != "orchestrator" ]; then
        it2 session set-var user.agentRole orchestrator --session "$ME_ID" >/dev/null 2>&1
    fi
}

# Rows of the other sessions in the workspace: same window, and in the project (or under the
# folder), plus any worker this session opened.
workspace_rows() {
    sessions | awk -F"$SEP" -v me="$ME_ID" -v win="$ME_WINDOW" -v root="$ROOT" -v kind="$ROOT_KIND" '
        $1 == me || $2 != win { next }
        $7 == me { print; next }
        kind == "project" && $4 == root { print; next }
        $4 == "" && ($5 == root || index($5, root "/") == 1) { print }'
}

require_member() {
    local id="$1"
    [ -n "$id" ] || die "missing session ID."
    workspace_rows | awk -F"$SEP" -v id="$id" '$1 == id { found = 1 } END { exit !found }' ||
        die "session $id isn’t in this workspace."
}

require_own_worker() {
    workspace_rows | awk -F"$SEP" -v id="$1" -v me="$ME_ID" '$1 == id && $6 == "worker" && $7 == me { found = 1 } END { exit !found }' ||
        die "session $1 isn’t a worker this session opened. Ask the user before touching it."
}

status_json() {
    it2 session get-status --session "$1" 2>/dev/null
}

status_of() {
    status_json "$1" | sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p'
}

cmd_info() {
    load_me
    local role="orchestrator"
    is_worker && role="worker of ${ITERM2_ORCHESTRATOR_ID:-$ME_PARENT}"
    printf 'session\t%s\nwindow\t%s\nworkspace\t%s (%s)\nrole\t%s\n' "$ME_ID" "$ME_WINDOW" "$ROOT" "$ROOT_KIND" "$role"
}

cmd_list() {
    require_orchestrator
    printf 'ID\tROLE\tSTATUS\tNAME\tJOB\tPATH\n'
    workspace_rows | while IFS="$SEP" read -r id _ _ _ path role _ name job; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "${role:-user}" "$(status_of "$id")" "$name" "$job" "$path"
    done
}

cmd_spawn() {
    require_orchestrator
    local name="" dir="$ROOT" agent="copilot" prompt="" flags="" flags_set=0 focus=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            --dir) dir="$2"; shift 2 ;;
            --agent) agent="$2"; shift 2 ;;
            --prompt) prompt="$2"; shift 2 ;;
            --flags) flags="$2"; flags_set=1; shift 2 ;;
            --focus) focus=1; shift ;;
            *) die "unknown spawn option $1" ;;
        esac
    done
    case "$dir" in
        /*) ;;
        *) dir="$ROOT/$dir" ;;
    esac
    [ -d "$dir" ] || die "no folder at $dir."
    dir="$(cd "$dir" && pwd -P)"

    local run
    case "$agent" in
        copilot)
            [ $flags_set = 1 ] || flags="--yolo"
            run="copilot $flags"
            [ -n "$prompt" ] && run="$run -i $(quote "$prompt")"
            ;;
        claude)
            run="claude $flags"
            [ -n "$prompt" ] && run="$run $(quote "$prompt")"
            ;;
        shell)
            run="$prompt"
            ;;
        *) die "unknown agent $agent." ;;
    esac
    local command="cd -- $(quote "$dir") && export ITERM2_ORCHESTRATOR_ID=$(quote "$ME_ID")"
    [ -n "$run" ] && command="$command && $run"

    local selected created id
    selected="$(it2 tab list --window "$ME_WINDOW" --json 2>/dev/null | tr -d '\n' |
        sed 's/}/}\n/g' | grep '"is_active" *: *true' | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' | head -1)"
    created="$(it2 tab new --window "$ME_WINDOW" --json --command "$command")" || die "couldn’t open a tab."
    id="$(printf '%s' "$created" | tr -d '\n' | sed -n 's/.*"session_id" *: *"\([^"]*\)".*/\1/p')"
    [ -n "$id" ] || die "iTerm2 didn’t say which session it opened: $created"
    it2 session set-var user.agentRole worker --session "$id" >/dev/null
    it2 session set-var user.orchestratorID "$ME_ID" --session "$id" >/dev/null
    [ -n "$name" ] && it2 session set-name "$name" --session "$id" >/dev/null
    if [ $focus = 0 ] && [ -n "$selected" ]; then
        it2 tab select "$selected" >/dev/null 2>&1
    fi
    printf '%s\n' "$id"
}

cmd_send() {
    require_orchestrator
    require_member "${1:-}"
    [ $# -ge 2 ] || die "usage: ws send ID TEXT"
    it2 session send --session "$1" -- "$2" >/dev/null || die "couldn’t send to $1."
    # A separate Return, so a full-screen agent sees typing followed by Enter rather than a paste.
    sleep 0.3
    it2 session send --session "$1" -- $'\r' >/dev/null
}

cmd_keys() {
    require_orchestrator
    require_member "${1:-}"
    [ $# -ge 2 ] || die "usage: ws keys ID TEXT"
    it2 session send --session "$1" -- "$2" >/dev/null
}

cmd_read() {
    require_orchestrator
    require_member "${1:-}"
    # The screen's rows below the cursor are blank, so drop trailing blank lines before tail.
    it2 session read --session "$1" |
        awk '{ lines[NR] = $0 } NF { last = NR } END { for (i = 1; i <= last; i++) print lines[i] }' |
        tail -n "${2:-40}"
}

cmd_status() {
    require_orchestrator
    require_member "${1:-}"
    status_json "$1"
    echo
}

cmd_wait() {
    require_orchestrator
    local timeout=1800
    if [ "${1:-}" = "--timeout" ]; then
        timeout="$2"
        shift 2
    fi
    [ $# -gt 0 ] || die "usage: ws wait [--timeout SECONDS] ID..."
    local id
    for id in "$@"; do
        require_member "$id"
    done
    # idle counts only after the session was seen working, so a worker that hasn’t started its
    # turn yet isn’t mistaken for a finished one. A session that isn’t working and whose screen
    # hasn’t changed for a while is quiet: a shell that finished, or a prompt no hook reports,
    # like Copilot CLI’s folder trust question.
    local quiet_after=20 seen="" start=$SECONDS status i screen
    local -a screens=() changed=()
    while [ $((SECONDS - start)) -lt "$timeout" ]; do
        i=0
        for id in "$@"; do
            status="$(status_of "$id")"
            case "$status" in
                done|waiting|error)
                    printf '%s\t%s\n' "$id" "$status"
                    return 0
                    ;;
                working)
                    case " $seen " in *" $id "*) ;; *) seen="$seen $id" ;; esac
                    ;;
                idle)
                    case " $seen " in *" $id "*) printf '%s\t%s\n' "$id" "$status"; return 0 ;; esac
                    ;;
            esac
            screen="$(it2 session read --session "$id" 2>/dev/null | cksum)"
            if [ "${screens[$i]:-}" != "$screen" ] || [ "$status" = "working" ]; then
                screens[$i]="$screen"
                changed[$i]=$SECONDS
            elif [ $((SECONDS - ${changed[$i]})) -ge $quiet_after ]; then
                printf '%s\tquiet\n' "$id"
                return 0
            fi
            i=$((i + 1))
        done
        sleep 3
    done
    echo "timeout"
    return 2
}

cmd_focus() {
    require_orchestrator
    require_member "${1:-}"
    it2 session focus "$1"
}

cmd_close() {
    require_orchestrator
    require_member "${1:-}"
    require_own_worker "$1"
    it2 session close --session "$1" --force
}

cmd_release() {
    require_orchestrator
    require_member "${1:-}"
    require_own_worker "$1"
    it2 session set-var user.agentRole '""' --session "$1" >/dev/null
    it2 session set-var user.orchestratorID '""' --session "$1" >/dev/null
}

command="${1:-}"
[ $# -gt 0 ] && shift
case "$command" in
    info) cmd_info ;;
    list) cmd_list ;;
    spawn) cmd_spawn "$@" ;;
    send) cmd_send "$@" ;;
    keys) cmd_keys "$@" ;;
    read) cmd_read "$@" ;;
    status) cmd_status "$@" ;;
    wait) cmd_wait "$@" ;;
    focus) cmd_focus "$@" ;;
    close) cmd_close "$@" ;;
    release) cmd_release "$@" ;;
    ""|-h|--help|help) usage ;;
    *) usage >&2; exit 1 ;;
esac
