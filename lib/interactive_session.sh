#!/bin/bash
# Interactive Session Component for Ralph
# Drives an interactive Claude Code session through tmux, reading responses
# from Claude's JSONL session files (~/.claude/projects/)
# This avoids API costs by using a Claude Code Max subscription

# Configuration
# Note: INTERACTIVE_MODE is set by ralph_loop.sh (CLI flag or .ralphrc), not here
INTERACTIVE_TMUX_SESSION=""
INTERACTIVE_CLAUDE_PANE=""
INTERACTIVE_POLL_INTERVAL=2       # seconds between JSONL polls
INTERACTIVE_IDLE_THRESHOLD=60     # seconds of no new JSONL lines = turn complete
INTERACTIVE_STUCK_TIMEOUT=60      # seconds before sending stuck notification
INTERACTIVE_SESSION_ID=""         # captured from JSONL directory

# get_project_jsonl_dir - Convert working directory to Claude project path format
#
# Claude stores session JSONL files in ~/.claude/projects/<path>/
# where <path> is the project directory with / replaced by - and prepended with -
#
# Example: /home/ucizi/code/my-project → ~/.claude/projects/-home-ucizi-code-my-project/
#
# Args: $1 - project directory (defaults to pwd)
# Returns: path to the JSONL directory on stdout
get_project_jsonl_dir() {
    local project_dir="${1:-$(pwd)}"
    # Replace all / with - and prepend -
    local converted
    converted=$(echo "$project_dir" | sed 's|/|-|g')
    echo "$HOME/.claude/projects/${converted}/"
}

# get_active_session_jsonl - Find the most recently modified JSONL file
#
# Args: $1 - JSONL directory (from get_project_jsonl_dir)
# Returns: full path to active JSONL file on stdout, empty if none found
get_active_session_jsonl() {
    local jsonl_dir="$1"

    if [[ ! -d "$jsonl_dir" ]]; then
        echo ""
        return 1
    fi

    # Find most recently modified .jsonl file
    local latest
    latest=$(ls -t "$jsonl_dir"*.jsonl 2>/dev/null | head -1)
    echo "$latest"
}

# setup_interactive_tool_permissions - Generate .claude/settings.json for tool auto-approval
#
# In interactive mode, --allowedTools flag doesn't apply. Instead, we configure
# the project's .claude/settings.json to auto-approve the tools from ALLOWED_TOOLS.
#
# Args: $1 - CLAUDE_ALLOWED_TOOLS string (comma-separated)
setup_interactive_tool_permissions() {
    local allowed_tools="${1:-$CLAUDE_ALLOWED_TOOLS}"

    if [[ -z "$allowed_tools" ]]; then
        return 0
    fi

    mkdir -p .claude

    # Generate settings.json with allowedTools from CLAUDE_ALLOWED_TOOLS
    # Split comma-separated tools into a JSON array
    jq -n --arg tools "$allowed_tools" '{
        "permissions": {
            "allow": ($tools | split(",") | map(gsub("^\\s+|\\s+$"; "")))
        }
    }' > .claude/settings.json

    return 0
}

# init_interactive_session - Create tmux session with Claude interactive pane
#
# Creates a tmux session with 2 panes:
#   - Pane 0: Ralph loop (current process)
#   - Pane 1: Interactive Claude Code session
#
# Returns: 0 on success, 1 on failure
init_interactive_session() {
    local project_dir
    project_dir=$(pwd)

    # Verify tmux is available
    if ! command -v tmux &>/dev/null; then
        log_status "ERROR" "Interactive mode requires tmux"
        return 1
    fi

    # Set up tool permissions before launching Claude
    setup_interactive_tool_permissions "$CLAUDE_ALLOWED_TOOLS"

    # Create tmux session name
    INTERACTIVE_TMUX_SESSION="ralph-interactive-$$"

    # Check if we're already inside tmux
    if [[ -n "${TMUX:-}" ]]; then
        # We're inside tmux — create a new pane in the current window
        local current_pane
        current_pane=$(tmux display-message -p '#{pane_id}')

        # Split horizontally to create Claude pane
        INTERACTIVE_CLAUDE_PANE=$(tmux split-window -h -t "$current_pane" -c "$project_dir" -P -F '#{pane_id}')

        # Launch Claude in the new pane
        tmux send-keys -t "$INTERACTIVE_CLAUDE_PANE" "claude" Enter

        log_status "INFO" "Launched interactive Claude in tmux pane: $INTERACTIVE_CLAUDE_PANE"
    else
        # Not inside tmux — create a new session
        tmux new-session -d -s "$INTERACTIVE_TMUX_SESSION" -c "$project_dir"

        # Get the base window index
        local base_win
        base_win=$(tmux show-options -gv base-index 2>/dev/null)
        base_win="${base_win:-0}"

        # Pane 0 is for Ralph (we'll use send-keys to start things)
        # Split to create pane 1 for Claude
        tmux split-window -h -t "$INTERACTIVE_TMUX_SESSION:${base_win}" -c "$project_dir"

        INTERACTIVE_CLAUDE_PANE="$INTERACTIVE_TMUX_SESSION:${base_win}.1"

        # Launch Claude in pane 1
        tmux send-keys -t "$INTERACTIVE_CLAUDE_PANE" "claude" Enter

        log_status "INFO" "Created tmux session '$INTERACTIVE_TMUX_SESSION' with Claude in pane 1"
    fi

    # Wait for Claude to be ready by checking the tmux pane for the input prompt
    # Claude's JSONL file is only created after the first message, so we check
    # the pane content instead
    log_status "INFO" "Waiting for Claude to initialize..."

    local wait_count=0
    local max_wait=60  # 60 seconds max wait for startup
    while [[ $wait_count -lt $max_wait ]]; do
        # Capture pane content and check for Claude's ready indicators
        local pane_content
        pane_content=$(tmux capture-pane -t "$INTERACTIVE_CLAUDE_PANE" -p 2>/dev/null || echo "")

        # Claude shows ">" prompt or "? for shortcuts" when ready
        if echo "$pane_content" | grep -qE '(for shortcuts|^❯|^>)'; then
            log_status "SUCCESS" "Claude session ready"
            return 0
        fi
        sleep 1
        ((wait_count++))
    done

    log_status "ERROR" "Timed out waiting for Claude to start"
    return 1
}

# send_prompt_interactive - Send a prompt to the Claude interactive pane
#
# Uses tmux load-buffer + paste-buffer to handle arbitrarily large prompts
# (avoids send-keys character limits)
#
# Args: $1 - prompt content string
# Returns: 0 on success, 1 on failure
send_prompt_interactive() {
    local prompt_content="$1"

    if [[ -z "$INTERACTIVE_CLAUDE_PANE" ]]; then
        log_status "ERROR" "No interactive Claude pane configured"
        return 1
    fi

    # Write prompt to temp file
    local tmp_file="/tmp/ralph_prompt_$$.txt"
    printf '%s' "$prompt_content" > "$tmp_file"

    # Load into tmux buffer and paste
    tmux load-buffer "$tmp_file"
    tmux paste-buffer -t "$INTERACTIVE_CLAUDE_PANE"
    # Brief delay for Claude's TUI to register the pasted content before Enter
    sleep 1
    tmux send-keys -t "$INTERACTIVE_CLAUDE_PANE" Enter

    rm -f "$tmp_file"

    return 0
}

# wait_for_response - Poll JSONL file for turn completion
#
# Watches the JSONL file for new lines beyond the baseline count.
# A turn is considered complete when:
#   1. New lines have appeared (content is arriving)
#   2. No new lines for INTERACTIVE_IDLE_THRESHOLD seconds (silence = done)
#
# If no new lines appear for INTERACTIVE_STUCK_TIMEOUT seconds after sending,
# sends a desktop notification to alert the user.
#
# Args:
#   $1 - JSONL file path
#   $2 - baseline line count (before prompt was sent)
#   $3 - timeout in seconds
# Returns: 0 on success, 1 on timeout
wait_for_response() {
    local jsonl_file="$1"
    local baseline="$2"
    local timeout_seconds="$3"
    local elapsed=0
    local idle_seconds=0
    local content_started=false
    local last_line_count=$baseline
    local stuck_notified=false

    while [[ $elapsed -lt $timeout_seconds ]]; do
        sleep "$INTERACTIVE_POLL_INTERVAL"
        elapsed=$((elapsed + INTERACTIVE_POLL_INTERVAL))

        # If the pane was killed (e.g., user manually closed it), stop waiting.
        # This lets killing the pane act as a "skip this turn" signal.
        if ! check_interactive_session_alive; then
            log_status "INFO" "Claude pane died — ending wait early"
            return 0
        fi

        # Count current lines
        local current_count=0
        if [[ -f "$jsonl_file" ]]; then
            current_count=$(wc -l < "$jsonl_file")
        fi

        if [[ $current_count -gt $last_line_count ]]; then
            # New content arrived
            content_started=true
            idle_seconds=0
            last_line_count=$current_count
            stuck_notified=false
        else
            # No new content
            idle_seconds=$((idle_seconds + INTERACTIVE_POLL_INTERVAL))

            if [[ "$content_started" == "true" ]]; then
                # Content was arriving but stopped — check for turn completion
                # Look for turn_duration system message as definitive completion signal
                local new_lines=$((current_count - baseline))
                if [[ $new_lines -gt 0 ]]; then
                    # Check if any of the new lines contain a turn_duration message
                    local has_turn_duration
                    has_turn_duration=$(tail -n "$new_lines" "$jsonl_file" | jq -r 'select(.type == "system" and .subtype == "turn_duration") | .type' 2>/dev/null | head -1)

                    if [[ -n "$has_turn_duration" ]]; then
                        log_status "INFO" "Turn complete (turn_duration signal detected)"
                        return 0
                    fi
                fi

                # Fallback: if idle for threshold seconds after content started, assume done
                if [[ $idle_seconds -ge $INTERACTIVE_IDLE_THRESHOLD ]]; then
                    log_status "INFO" "Turn complete (${idle_seconds}s idle after content)"
                    return 0
                fi
            else
                # No content yet — check if stuck
                if [[ $idle_seconds -ge $INTERACTIVE_STUCK_TIMEOUT && "$stuck_notified" != "true" ]]; then
                    log_status "WARN" "Claude may need attention (no response for ${idle_seconds}s)"
                    # Send desktop notification if available
                    if command -v notify-send &>/dev/null; then
                        notify-send -u critical "Ralph: Claude needs attention" \
                            "Permission prompt or input required in tmux pane" 2>/dev/null || true
                    fi
                    stuck_notified=true
                    # Keep waiting — user may interact with Claude
                fi
            fi
        fi
    done

    log_status "WARN" "Response wait timed out after ${timeout_seconds}s"
    return 1
}

# extract_response_from_jsonl - Build synthetic JSON output from JSONL
#
# Reads new lines from the JSONL file (after baseline) and constructs
# a JSON object matching the Claude CLI -p --output-format json format.
# This allows the existing analyze_response() pipeline to work unchanged.
#
# Args:
#   $1 - JSONL file path
#   $2 - baseline line count
#   $3 - output file path (where synthetic JSON is written)
#   $4 - elapsed time in ms (optional)
# Returns: 0 on success, 1 on failure
extract_response_from_jsonl() {
    local jsonl_file="$1"
    local baseline="$2"
    local output_file="$3"
    local duration_ms="${4:-0}"

    if [[ ! -f "$jsonl_file" ]]; then
        log_status "ERROR" "JSONL file not found: $jsonl_file"
        return 1
    fi

    local current_count
    current_count=$(wc -l < "$jsonl_file")
    local new_lines=$((current_count - baseline))

    if [[ $new_lines -le 0 ]]; then
        log_status "WARN" "No new lines in JSONL file"
        # Write empty result
        jq -n '{
            "type": "result",
            "subtype": "success",
            "result": "",
            "sessionId": "",
            "is_error": false,
            "duration_ms": 0,
            "num_turns": 0
        }' > "$output_file"
        return 0
    fi

    # Extract new lines only
    local new_content
    new_content=$(tail -n "$new_lines" "$jsonl_file")

    # Extract text from the last assistant message(s) in this turn
    # Assistant messages have .type == "assistant" and .message.content array with text blocks
    # Use jq slurp to collect all messages and join them, preserving newlines within text
    local assistant_text
    assistant_text=$(echo "$new_content" | jq -s -r '
        [.[] | select(.type == "assistant" and .message.content != null) |
         .message.content[] | select(.type == "text") | .text] | join("")
    ' 2>/dev/null)

    # Get session ID from the JSONL lines
    local session_id
    session_id=$(echo "$new_content" | jq -r 'select(.sessionId != null) | .sessionId' 2>/dev/null | head -1)
    session_id="${session_id:-$INTERACTIVE_SESSION_ID}"

    # Count assistant turns in new lines
    local num_turns
    num_turns=$(echo "$new_content" | jq -r 'select(.type == "assistant")' 2>/dev/null | wc -l)
    num_turns=$((num_turns + 0))  # Ensure integer

    # Build synthetic output matching Claude CLI JSON format
    # Key fields consumed by parse_json_response():
    #   .result (text with RALPH_STATUS block), .sessionId, .permission_denials
    # Note: uses sessionId (camelCase) to match Claude CLI format that parse_json_response expects
    jq -n \
        --arg result "$assistant_text" \
        --arg sessionId "$session_id" \
        --argjson duration_ms "$duration_ms" \
        --argjson num_turns "$num_turns" \
        '{
            "type": "result",
            "subtype": "success",
            "result": $result,
            "sessionId": $sessionId,
            "is_error": false,
            "duration_ms": $duration_ms,
            "num_turns": $num_turns
        }' > "$output_file"

    return 0
}

# check_interactive_session_alive - Verify Claude pane is still running
#
# Returns: 0 if alive, 1 if dead
check_interactive_session_alive() {
    if [[ -z "$INTERACTIVE_CLAUDE_PANE" ]]; then
        return 1
    fi

    # Check if the tmux pane still exists
    tmux list-panes -t "$INTERACTIVE_CLAUDE_PANE" &>/dev/null
    return $?
}

# teardown_interactive_session - Kill the interactive Claude pane
#
# Directly kills the tmux pane without sending /exit. This is used for
# per-loop session isolation: each loop gets a fresh Claude session.
teardown_interactive_session() {
    if [[ -z "$INTERACTIVE_CLAUDE_PANE" ]]; then
        return 0
    fi

    log_status "INFO" "Tearing down interactive session..."
    tmux kill-pane -t "$INTERACTIVE_CLAUDE_PANE" 2>/dev/null || true
    INTERACTIVE_CLAUDE_PANE=""
    return 0
}
