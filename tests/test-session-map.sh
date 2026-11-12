#!/bin/bash
# What a pane may claim about its session comes from the process itself.
# Nothing is inferred from transcript contents: a conversation is quoted in
# other transcripts too, and matching on that handed panes a neighbour's id.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$HOOKS/lib/session-map.sh"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
printf '#!/bin/sh\nsleep 30\n' > "$BIN/claude"; chmod +x "$BIN/claude"
start() { "$BIN/claude" "$@" >/dev/null 2>&1 & echo $!; }

SID=33333333-3333-3333-3333-333333333333

pid=$(start --session-id "$SID")
check "a process naming its session is believed" "$(claude_session_of_pane "$pid")" "$SID"
kill "$pid" 2>/dev/null

pid=$(start --resume 11111111-1111-1111-1111-111111111111)
check "a resumed id is not the live session" "$(claude_session_of_pane "$pid")" ""
kill "$pid" 2>/dev/null

pid=$(start)
check "no arguments, no claim" "$(claude_session_of_pane "$pid")" ""
kill "$pid" 2>/dev/null

# A bare `claude` hosted by the daemon states nothing on its command line; its
# session file — named after its pid, written by Claude — names the session
# and the pane it runs in.
export CLAUDE_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$CLAUDE_SESSIONS_DIR"
test_server_start
PANE=$(t display-message -p '#{pane_id}')
DSID=44444444-4444-4444-4444-444444444444

pid=$(start)
printf '{"pid":%s,"sessionId":"%s","tmux":"t:@0.%s","status":"idle"}' "$pid" "$DSID" "$PANE" \
    > "$CLAUDE_SESSIONS_DIR/$pid.json"
check "a session file names the pane's session" "$(claude_session_of_pane "$pid")" "$DSID"
check "an unstamped session is found through its file" "$(claude_pane_of_session "$DSID")" "$PANE"
check "and the pane is stamped for next time" "$(t show-options -pqv -t "$PANE" @claude-session)" "$DSID"
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

GONE=55555555-5555-5555-5555-555555555555
printf '{"pid":%s,"sessionId":"%s","tmux":"t:@0.%s","status":"idle"}' 999999 "$GONE" "$PANE" \
    > "$CLAUDE_SESSIONS_DIR/999999.json"
check "a leftover file of a dead process names nothing" "$(claude_pane_of_session "$GONE")" ""
test_server_stop
