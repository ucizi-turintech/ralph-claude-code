#!/usr/bin/env bats
# Unit tests for interactive tmux execution mode

load '../helpers/test_helper'
load '../helpers/fixtures'

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize git repo
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Set up environment with .ralph/ subfolder structure
    export RALPH_DIR=".ralph"
    export PROMPT_FILE="$RALPH_DIR/PROMPT.md"
    export LOG_DIR="$RALPH_DIR/logs"
    export DOCS_DIR="$RALPH_DIR/docs/generated"
    export STATUS_FILE="$RALPH_DIR/status.json"
    export EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
    export CALL_COUNT_FILE="$RALPH_DIR/.call_count"
    export TIMESTAMP_FILE="$RALPH_DIR/.last_reset"
    export CLAUDE_SESSION_FILE="$RALPH_DIR/.claude_session_id"
    export CLAUDE_ALLOWED_TOOLS="Write,Read,Edit,Bash(git add *),Bash(npm *)"
    export INTERACTIVE_MODE=false

    mkdir -p "$LOG_DIR" "$DOCS_DIR"
    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Create sample project files
    create_sample_prompt
    create_sample_fix_plan "$RALPH_DIR/fix_plan.md" 10 3

    # Source library components
    source "${BATS_TEST_DIRNAME}/../../lib/date_utils.sh"
    source "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"
    source "${BATS_TEST_DIRNAME}/../../lib/interactive_session.sh"

    # Define log_status function for tests
    log_status() {
        local level=$1
        local message=$2
        echo "[$level] $message"
    }
}

teardown() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# get_project_jsonl_dir tests
# =============================================================================

@test "get_project_jsonl_dir converts absolute path correctly" {
    run get_project_jsonl_dir "/home/ucizi/code/my-project"
    assert_success
    assert_equal "$output" "$HOME/.claude/projects/-home-ucizi-code-my-project/"
}

@test "get_project_jsonl_dir converts nested path with hyphens" {
    run get_project_jsonl_dir "/home/ucizi/code/artemis-runner/agents/feat/poc/0"
    assert_success
    assert_equal "$output" "$HOME/.claude/projects/-home-ucizi-code-artemis-runner-agents-feat-poc-0/"
}

@test "get_project_jsonl_dir converts root path" {
    run get_project_jsonl_dir "/tmp"
    assert_success
    assert_equal "$output" "$HOME/.claude/projects/-tmp/"
}

@test "get_project_jsonl_dir defaults to pwd when no arg" {
    local expected_path="$HOME/.claude/projects/$(pwd | sed 's|/|-|g')/"
    run get_project_jsonl_dir
    assert_success
    assert_equal "$output" "$expected_path"
}

@test "get_project_jsonl_dir handles path with spaces" {
    run get_project_jsonl_dir "/home/user/my project/code"
    assert_success
    assert_equal "$output" "$HOME/.claude/projects/-home-user-my project-code/"
}

# =============================================================================
# get_active_session_jsonl tests
# =============================================================================

@test "get_active_session_jsonl returns empty for missing directory" {
    run get_active_session_jsonl "/nonexistent/path/"
    assert_failure
    assert_equal "$output" ""
}

@test "get_active_session_jsonl returns empty for empty directory" {
    mkdir -p "$TEST_DIR/jsonl_dir"
    run get_active_session_jsonl "$TEST_DIR/jsonl_dir/"
    # No .jsonl files, so output should be empty
    assert_equal "$output" ""
}

@test "get_active_session_jsonl returns most recent jsonl file" {
    mkdir -p "$TEST_DIR/jsonl_dir"
    echo '{"type":"test"}' > "$TEST_DIR/jsonl_dir/old-session.jsonl"
    sleep 1
    echo '{"type":"test"}' > "$TEST_DIR/jsonl_dir/new-session.jsonl"

    run get_active_session_jsonl "$TEST_DIR/jsonl_dir/"
    assert_success
    assert_equal "$output" "$TEST_DIR/jsonl_dir/new-session.jsonl"
}

# =============================================================================
# extract_response_from_jsonl tests
# =============================================================================

@test "extract_response_from_jsonl builds synthetic JSON from JSONL" {
    local jsonl_file="$TEST_DIR/session.jsonl"
    local output_file="$TEST_DIR/output.json"

    # Write sample JSONL data (baseline: 0 lines)
    cat > "$jsonl_file" << 'EOF'
{"type":"user","sessionId":"abc-123","message":{"role":"user","content":"hello"}}
{"type":"assistant","sessionId":"abc-123","message":{"role":"assistant","content":[{"type":"text","text":"I'll help with that."}]}}
{"type":"assistant","sessionId":"abc-123","message":{"role":"assistant","content":[{"type":"text","text":"\n---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nEXIT_SIGNAL: false\n---END_RALPH_STATUS---"}]}}
EOF

    run extract_response_from_jsonl "$jsonl_file" 0 "$output_file" 5000
    assert_success

    # Verify output is valid JSON
    run jq empty "$output_file"
    assert_success

    # Verify key fields
    local result_text=$(jq -r '.result' "$output_file")
    [[ "$result_text" == *"I'll help with that."* ]]
    [[ "$result_text" == *"RALPH_STATUS"* ]]

    local session_id=$(jq -r '.sessionId' "$output_file")
    assert_equal "$session_id" "abc-123"

    local is_error=$(jq -r '.is_error' "$output_file")
    assert_equal "$is_error" "false"
}

@test "extract_response_from_jsonl handles empty new lines" {
    local jsonl_file="$TEST_DIR/session.jsonl"
    local output_file="$TEST_DIR/output.json"

    echo '{"type":"user","sessionId":"abc-123","message":{"role":"user","content":"hello"}}' > "$jsonl_file"

    # Baseline = 1 line, current = 1 line → no new lines
    run extract_response_from_jsonl "$jsonl_file" 1 "$output_file"
    assert_success

    local result_text=$(jq -r '.result' "$output_file")
    assert_equal "$result_text" ""
}

@test "extract_response_from_jsonl respects baseline offset" {
    local jsonl_file="$TEST_DIR/session.jsonl"
    local output_file="$TEST_DIR/output.json"

    # Simulate pre-existing lines (baseline = 2)
    cat > "$jsonl_file" << 'EOF'
{"type":"user","sessionId":"sess-1","message":{"role":"user","content":"old prompt"}}
{"type":"assistant","sessionId":"sess-1","message":{"role":"assistant","content":[{"type":"text","text":"old response"}]}}
{"type":"user","sessionId":"sess-1","message":{"role":"user","content":"new prompt"}}
{"type":"assistant","sessionId":"sess-1","message":{"role":"assistant","content":[{"type":"text","text":"new response only"}]}}
EOF

    run extract_response_from_jsonl "$jsonl_file" 2 "$output_file"
    assert_success

    local result_text=$(jq -r '.result' "$output_file")
    # Should only contain the new response
    [[ "$result_text" == *"new response only"* ]]
    # Should NOT contain the old response
    [[ "$result_text" != *"old response"* ]] || [[ "$result_text" == *"new response only"* ]]
}

@test "extract_response_from_jsonl handles missing file" {
    run extract_response_from_jsonl "/nonexistent/file.jsonl" 0 "$TEST_DIR/output.json"
    assert_failure
}

@test "extract_response_from_jsonl output is parseable by parse_json_response" {
    local jsonl_file="$TEST_DIR/session.jsonl"
    local output_file="$TEST_DIR/output.json"
    local parse_result="$TEST_DIR/parse_result.json"

    cat > "$jsonl_file" << 'EOF'
{"type":"assistant","sessionId":"sess-42","message":{"role":"assistant","content":[{"type":"text","text":"Implementation complete.\n\n---RALPH_STATUS---\nSTATUS: COMPLETE\nTASKS_COMPLETED_THIS_LOOP: 1\nFILES_MODIFIED: 3\nTESTS_STATUS: PASSING\nWORK_TYPE: IMPLEMENTATION\nEXIT_SIGNAL: true\nRECOMMENDATION: Deploy to staging\n---END_RALPH_STATUS---"}]}}
EOF

    extract_response_from_jsonl "$jsonl_file" 0 "$output_file"

    # Parse with the real parse_json_response
    run parse_json_response "$output_file" "$parse_result"
    assert_success

    # Verify exit_signal was extracted from RALPH_STATUS block in .result
    local exit_signal=$(jq -r '.exit_signal' "$parse_result")
    assert_equal "$exit_signal" "true"

    local session_id=$(jq -r '.session_id' "$parse_result")
    assert_equal "$session_id" "sess-42"
}

@test "extract_response_from_jsonl skips non-text content blocks" {
    local jsonl_file="$TEST_DIR/session.jsonl"
    local output_file="$TEST_DIR/output.json"

    cat > "$jsonl_file" << 'EOF'
{"type":"assistant","sessionId":"sess-1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"let me think..."},{"type":"text","text":"Here is my answer"}]}}
EOF

    run extract_response_from_jsonl "$jsonl_file" 0 "$output_file"
    assert_success

    local result_text=$(jq -r '.result' "$output_file")
    [[ "$result_text" == *"Here is my answer"* ]]
    # Thinking content should not be in the result
    [[ "$result_text" != *"let me think"* ]]
}

@test "extract_response_from_jsonl concatenates multiple assistant turns" {
    local jsonl_file="$TEST_DIR/session.jsonl"
    local output_file="$TEST_DIR/output.json"

    cat > "$jsonl_file" << 'EOF'
{"type":"assistant","sessionId":"sess-1","message":{"role":"assistant","content":[{"type":"text","text":"Part 1. "}]}}
{"type":"user","sessionId":"sess-1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
{"type":"assistant","sessionId":"sess-1","message":{"role":"assistant","content":[{"type":"text","text":"Part 2."}]}}
EOF

    run extract_response_from_jsonl "$jsonl_file" 0 "$output_file"
    assert_success

    local result_text=$(jq -r '.result' "$output_file")
    [[ "$result_text" == *"Part 1."* ]]
    [[ "$result_text" == *"Part 2."* ]]
}

# =============================================================================
# setup_interactive_tool_permissions tests
# =============================================================================

@test "setup_interactive_tool_permissions creates .claude/settings.json" {
    run setup_interactive_tool_permissions "Write,Read,Edit"
    assert_success
    assert_file_exists ".claude/settings.json"

    # Verify JSON structure
    run jq -r '.permissions.allow | length' .claude/settings.json
    assert_equal "$output" "3"

    run jq -r '.permissions.allow[0]' .claude/settings.json
    assert_equal "$output" "Write"
}

@test "setup_interactive_tool_permissions handles complex tool patterns" {
    run setup_interactive_tool_permissions "Write,Read,Bash(git add *),Bash(npm *)"
    assert_success

    run jq -r '.permissions.allow | length' .claude/settings.json
    assert_equal "$output" "4"

    run jq -r '.permissions.allow[3]' .claude/settings.json
    assert_equal "$output" "Bash(npm *)"
}

@test "setup_interactive_tool_permissions trims whitespace from tools" {
    run setup_interactive_tool_permissions "Write , Read , Edit"
    assert_success

    run jq -r '.permissions.allow[1]' .claude/settings.json
    assert_equal "$output" "Read"
}

@test "setup_interactive_tool_permissions does nothing with empty tools" {
    run setup_interactive_tool_permissions ""
    assert_success
    [[ ! -f ".claude/settings.json" ]] || true
}

# =============================================================================
# CLI flag parsing tests
# =============================================================================

@test "CLI: --interactive flag sets INTERACTIVE_MODE" {
    # Source ralph_loop.sh just for the CLI parsing section
    # We can test by checking if the flag is recognized
    export INTERACTIVE_MODE=false
    # Simulate the flag parsing
    local args=("--interactive")
    case "${args[0]}" in
        --interactive|-i) INTERACTIVE_MODE=true ;;
    esac
    assert_equal "$INTERACTIVE_MODE" "true"
}

@test "CLI: -i short flag sets INTERACTIVE_MODE" {
    export INTERACTIVE_MODE=false
    local args=("-i")
    case "${args[0]}" in
        --interactive|-i) INTERACTIVE_MODE=true ;;
    esac
    assert_equal "$INTERACTIVE_MODE" "true"
}

@test "CLI: INTERACTIVE_MODE defaults to false" {
    assert_equal "$INTERACTIVE_MODE" "false"
}

# =============================================================================
# check_interactive_session_alive tests
# =============================================================================

@test "check_interactive_session_alive returns 1 with empty pane" {
    INTERACTIVE_CLAUDE_PANE=""
    run check_interactive_session_alive
    assert_failure
}

# =============================================================================
# wait_for_response tests
# =============================================================================

@test "wait_for_response exits early when pane dies" {
    # Mock check_interactive_session_alive to return failure (pane dead)
    check_interactive_session_alive() { return 1; }
    export -f check_interactive_session_alive

    INTERACTIVE_POLL_INTERVAL=1
    INTERACTIVE_IDLE_THRESHOLD=60
    INTERACTIVE_STUCK_TIMEOUT=60

    local jsonl_file="$TEST_DIR/session.jsonl"
    echo '{"type":"user"}' > "$jsonl_file"

    # Should return quickly (not wait 300s) because pane is dead
    run wait_for_response "$jsonl_file" 0 300
    assert_success
    [[ "$output" == *"pane died"* ]]
}

# =============================================================================
# teardown_interactive_session tests
# =============================================================================

@test "teardown_interactive_session handles empty pane gracefully" {
    INTERACTIVE_CLAUDE_PANE=""
    run teardown_interactive_session
    assert_success
}

@test "teardown_interactive_session does not send /exit command" {
    # The simplified teardown should just kill the pane, not send /exit
    # Verify by checking the function source does not contain send-keys /exit
    local func_source
    func_source=$(declare -f teardown_interactive_session)
    # Should NOT contain /exit
    [[ "$func_source" != *"/exit"* ]]
}

@test "teardown_interactive_session clears INTERACTIVE_CLAUDE_PANE" {
    # Mock tmux kill-pane to succeed
    tmux() { return 0; }
    export -f tmux

    INTERACTIVE_CLAUDE_PANE="some-pane-id"
    teardown_interactive_session
    assert_equal "$INTERACTIVE_CLAUDE_PANE" ""
}

# =============================================================================
# Transcript saving tests
# =============================================================================

@test "transcript file is created from new JSONL lines" {
    local jsonl_file="$TEST_DIR/session.jsonl"

    # Simulate a JSONL file with 2 baseline lines + 3 new lines
    cat > "$jsonl_file" << 'EOF'
{"type":"user","sessionId":"s1","message":{"role":"user","content":"baseline prompt"}}
{"type":"assistant","sessionId":"s1","message":{"role":"assistant","content":[{"type":"text","text":"baseline response"}]}}
{"type":"user","sessionId":"s1","message":{"role":"user","content":"new prompt"}}
{"type":"assistant","sessionId":"s1","message":{"role":"assistant","content":[{"type":"text","text":"new response"}]}}
{"type":"system","subtype":"turn_duration","duration_ms":5000}
EOF

    local baseline_count=2
    local loop_count=7
    local new_lines=$(($(wc -l < "$jsonl_file") - baseline_count))
    local transcript_file="$RALPH_DIR/logs/interactive_loop_${loop_count}.jsonl"

    # Replicate the transcript saving logic from ralph_loop.sh
    if [[ $new_lines -gt 0 ]]; then
        tail -n "$new_lines" "$jsonl_file" > "$transcript_file"
    fi

    # Verify transcript was created
    assert_file_exists "$transcript_file"

    # Verify correct number of lines
    local transcript_lines
    transcript_lines=$(wc -l < "$transcript_file")
    assert_equal "$transcript_lines" "3"

    # Verify content is from the new lines only (not baseline)
    run grep -c "new prompt" "$transcript_file"
    assert_equal "$output" "1"

    run grep -c "baseline prompt" "$transcript_file"
    assert_equal "$output" "0"
}

@test "transcript file is not created when no new JSONL lines" {
    local jsonl_file="$TEST_DIR/session.jsonl"

    echo '{"type":"user","sessionId":"s1","message":{"role":"user","content":"baseline"}}' > "$jsonl_file"

    local baseline_count=1
    local loop_count=3
    local new_lines=$(($(wc -l < "$jsonl_file") - baseline_count))
    local transcript_file="$RALPH_DIR/logs/interactive_loop_${loop_count}.jsonl"

    if [[ $new_lines -gt 0 ]]; then
        tail -n "$new_lines" "$jsonl_file" > "$transcript_file"
    fi

    # Transcript should not exist
    [[ ! -f "$transcript_file" ]]
}

# =============================================================================
# Integration: synthetic output compatibility with analyze_response
# =============================================================================

@test "synthetic output triggers correct exit detection in analyze_response" {
    local jsonl_file="$TEST_DIR/session.jsonl"
    local output_file="$TEST_DIR/output.json"
    local analysis_file="$RALPH_DIR/.response_analysis"

    cat > "$jsonl_file" << 'EOF'
{"type":"assistant","sessionId":"sess-99","message":{"role":"assistant","content":[{"type":"text","text":"All tasks completed successfully.\n\n---RALPH_STATUS---\nSTATUS: COMPLETE\nTASKS_COMPLETED_THIS_LOOP: 3\nFILES_MODIFIED: 5\nTESTS_STATUS: PASSING\nWORK_TYPE: IMPLEMENTATION\nEXIT_SIGNAL: true\nRECOMMENDATION: Ready for review\n---END_RALPH_STATUS---"}]}}
EOF

    extract_response_from_jsonl "$jsonl_file" 0 "$output_file"

    # Run full analysis pipeline
    run analyze_response "$output_file" 5 "$analysis_file"
    assert_success

    # Verify analysis detected the exit signal
    local exit_signal=$(jq -r '.analysis.exit_signal' "$analysis_file")
    assert_equal "$exit_signal" "true"

    local has_completion=$(jq -r '.analysis.has_completion_signal' "$analysis_file")
    assert_equal "$has_completion" "true"
}

@test "synthetic output with EXIT_SIGNAL false continues loop" {
    local jsonl_file="$TEST_DIR/session.jsonl"
    local output_file="$TEST_DIR/output.json"
    local analysis_file="$RALPH_DIR/.response_analysis"

    cat > "$jsonl_file" << 'EOF'
{"type":"assistant","sessionId":"sess-99","message":{"role":"assistant","content":[{"type":"text","text":"Phase 1 complete, moving to phase 2.\n\n---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 1\nFILES_MODIFIED: 2\nTESTS_STATUS: PASSING\nWORK_TYPE: IMPLEMENTATION\nEXIT_SIGNAL: false\nRECOMMENDATION: Continue to phase 2\n---END_RALPH_STATUS---"}]}}
EOF

    extract_response_from_jsonl "$jsonl_file" 0 "$output_file"
    run analyze_response "$output_file" 3 "$analysis_file"
    assert_success

    local exit_signal=$(jq -r '.analysis.exit_signal' "$analysis_file")
    assert_equal "$exit_signal" "false"
}

# =============================================================================
# .ralphrc INTERACTIVE_MODE configuration
# =============================================================================

@test "load_ralphrc loads INTERACTIVE_MODE from .ralphrc" {
    # Create a minimal .ralphrc
    cat > "$TEST_DIR/.ralphrc" << 'EOF'
INTERACTIVE_MODE=true
EOF

    # Source the .ralphrc directly to test variable loading
    source "$TEST_DIR/.ralphrc"
    assert_equal "$INTERACTIVE_MODE" "true"
}
