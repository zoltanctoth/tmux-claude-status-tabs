#!/bin/bash
# Work out which conversation each pane is running, and stamp it on the pane.
#
# Hooks normally carry TMUX_PANE and need none of this. Some do not: Claude
# hands tool execution to pre-warmed background processes (`claude bg-spare`)
# owned by its daemon, and those inherit the daemon's environment, which has
# never seen tmux. Their hooks arrive with no pane, and a tab driven that way
# never moves.
#
# The payload does carry a session id, so the pane only has to be labelled
# with the same id for the two to meet. That label is derived, not guessed:
#
#   --session-id <uuid> on the pane's process is the id outright;
#   --resume <uuid> names the conversation it continued, and the transcript
#   of the live session quotes that id, so the file that contains it is this
#   pane's session.
#
# A pane that yields no id is left unlabelled rather than approximated.

CLAUDE_PROJECTS="${CLAUDE_PROJECTS:-$HOME/.claude/projects}"
CLAUDE_SESSIONS_DIR="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}"

# Claude's own account of a live session: ~/.claude/sessions/<pid>.json, keyed
# by the pid of the CLI in the pane, carrying the current sessionId and the
# pane itself ("tmux": "<session>:@<window>.%<pane>"). It is written by the
# process that sits in the pane, so it holds for a conversation hosted in the
# daemon too — the case nothing else can link — and it follows /clear and
# --resume, which hand the same pane a new id.
#
# Args: <session id>. Prints the pane it runs in, or nothing.
claude_pane_from_session_file() {
    local want="$1" f pid ref
    [ -n "$want" ] && [ -d "$CLAUDE_SESSIONS_DIR" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    for f in $(grep -lF -- "\"$want\"" "$CLAUDE_SESSIONS_DIR"/*.json 2>/dev/null); do
        IFS=$'\t' read -r pid ref < <(
            jq -r --arg s "$want" 'select(.sessionId == $s) | [.pid, .tmux // ""] | @tsv' "$f" 2>/dev/null
        )
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        # A file whose process is gone is a leftover, not a session.
        kill -0 "$pid" 2>/dev/null || continue
        case "${ref##*.}" in %*) printf '%s' "${ref##*.}"; return 0 ;; esac
    done
    return 1
}

# The directory Claude keeps a project's transcripts in: the absolute path
# with every character that is not a letter, digit or dash turned into a dash.
claude_project_dir() {
    printf '%s/%s' "$CLAUDE_PROJECTS" "$(printf '%s' "$1" | sed 's/[^a-zA-Z0-9-]/-/g')"
}

# Args: <pane claude pid>. Prints the session id, or nothing.
#
# Only what the process states about itself counts. An earlier version looked
# for the transcript quoting the id a session was resumed from, which read as
# clever and was wrong: a conversation gets quoted in other transcripts too, so
# it handed panes the id of a neighbouring session. Everything else comes from
# the SessionStart stamp, the fork chain, or link-pane.sh.
claude_session_of_pane() {
    local pid="$1" cmdline sid
    cmdline=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
    sid=$(printf '%s' "$cmdline" | sed -n 's/.*--session-id \([0-9a-f-]\{36\}\).*/\1/p' | head -1)
    # A bare `claude` states nothing on its command line, but its session file
    # (named after this very pid) does.
    if [ -z "$sid" ] && [ -f "$CLAUDE_SESSIONS_DIR/$pid.json" ] && command -v jq >/dev/null 2>&1; then
        sid=$(jq -r '.sessionId // empty' "$CLAUDE_SESSIONS_DIR/$pid.json" 2>/dev/null)
    fi
    printf '%s' "$sid"
}

# A conversation Claude forked into its daemon carries a new id, while the pane
# still wears the id it was stamped with. The fork's own arguments name the
# transcript it came from, so the parent id is readable rather than guessed:
#
#   --session-id <new> --fork-session --resume /…/projects/<slug>/<parent>.jsonl
#
# Args: <session id> [process table file for tests]. Prints the parent id.
claude_parent_session() {
    local want="$1" line
    line=$({ [ -n "$2" ] && cat "$2" || ps -Ao command=; } |
        grep -F -- "--session-id $want" | grep -F -- "--fork-session" | head -1)
    [ -n "$line" ] || return 1
    printf '%s' "$line" | sed -n 's/.*--resume [^ ]*\/\([0-9a-f-]\{36\}\)\.jsonl.*/\1/p'
}

# Find the pane a session id was stamped on. Exact match only, though a forked
# conversation is followed back to the one it came from.
claude_pane_of_session() {
    local want="$1" pane stamped hops=0
    [ -n "$want" ] || return 1
    while [ "$hops" -lt 4 ]; do
        while IFS="	" read -r pane stamped; do
            # A pane accumulates ids: restarting Claude in it, or resuming,
            # gives the same tab a new conversation while the old one may
            # still be running work that reports against the old id.
            case " $stamped " in *" $want "*) ;; *) continue ;; esac
            printf '%s' "$pane"
            return 0
        done <<EOF
$(tmux list-panes -a -F '#{pane_id}	#{@claude-session}' 2>/dev/null)
EOF
        # Not stamped yet (a new window, a /clear since the last seed pass):
        # the CLI's session file names the pane outright.
        pane=$(claude_pane_from_session_file "$want") && [ -n "$pane" ] && {
            claude_stamp_session "$pane" "$want"
            printf '%s' "$pane"
            return 0
        }
        # Not stamped anywhere: this may be a fork of a conversation that is.
        want=$(claude_parent_session "$want" "$2") || return 1
        [ -n "$want" ] || return 1
        hops=$(( hops + 1 ))
    done
    return 1
}

# Record an id against a pane without losing the ones already there.
claude_stamp_session() {
    local pane="$1" sid="$2" have
    [ -n "$sid" ] || return 1
    have=$(tmux show-options -pqv -t "$pane" @claude-session 2>/dev/null)
    case " $have " in
        *" $sid "*) return 0 ;;
    esac
    tmux set-option -p -t "$pane" @claude-session "${have:+$have }$sid" 2>/dev/null
}
