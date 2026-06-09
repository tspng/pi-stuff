#!/usr/bin/env bash
# todo.sh — Cross-agent todo manager compatible with pi's todos extension.
# Reads/writes the same .pi/todos/<id>.md format (JSON front matter + markdown body).
# Requires: bash 4+, jq, openssl (for ID generation)

set -euo pipefail

# Lock TTL in seconds (matches pi's todos extension default of 30 minutes)
LOCK_TTL_SECONDS=$((30 * 60))

# --- Dependency Check ---
for cmd in jq openssl stat; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' is not installed." >&2
        exit 1
    fi
done

# --- Resolve todo directory ---
resolve_todos_dir() {
    local override
    override="${PI_TODO_PATH:-}"
    if [[ -n "$override" ]]; then
        # Resolve relative to current working directory
        if [[ "$override" = /* ]]; then
            echo "$override"
        else
            echo "${PWD}/${override}"
        fi
    else
        echo "${PWD}/.pi/todos"
    fi
}

TODOS_DIR="$(resolve_todos_dir)"

# --- ID helpers ---
normalize_id() {
    local id="$1"
    # Strip TODO- prefix (case-insensitive) or # prefix
    id="${id#\#}"
    local upper="${id^^}"
    if [[ "$upper" == TODO-* ]]; then
        id="${id:5}"
    fi
    echo "${id,,}"
}

validate_id() {
    local id
    id="$(normalize_id "$1")"
    if [[ ! "$id" =~ ^[a-f0-9]{8}$ ]]; then
        echo "Error: Invalid todo id. Expected TODO-<hex> (8 hex chars)." >&2
        return 1
    fi
    echo "$id"
}

generate_id() {
    local attempt=0
    while ((attempt < 10)); do
        local id
        id="$(openssl rand -hex 4)"
        if [[ ! -f "${TODOS_DIR}/${id}.md" ]]; then
            echo "$id"
            return 0
        fi
        attempt=$((attempt + 1))
    done
    echo "Error: Failed to generate unique todo id." >&2
    return 1
}

# --- File format helpers ---
# The file format is: JSON object (single or multi-line), blank line, then markdown body.
# {
#   "id": "deadbeef",
#   "title": "...",
#   "tags": [...],
#   "status": "open",
#   "created_at": "...",
#   "assigned_to_session": "..."
# }
#
# Markdown body text here.

# Extract just the JSON line (first line) from a todo file
read_front_matter() {
    local file="$1"
    sed '/^[[:space:]]*}[[:space:]]*$/q' "$file"
}

# Extract the body (everything after the JSON front matter and blank separator)
read_body() {
    local file="$1"
    # Delete everything from line 1 up to (and including) the first line that is
    # a closing brace '}', then delete the first blank line that follows it.
    # This handles both single-line and multi-line (JSON.stringify with indent) JSON.
    sed '1,/^[[:space:]]*}[[:space:]]*$/d' "$file" | sed '1,/^$/d'
}

# Get a single field from the front matter JSON
get_field() {
    local file="$1"
    local field="$2"
    read_front_matter "$file" | jq -r --arg f "$field" '.[$f] // ""'
}

# Write a complete todo file
write_todo_file() {
    local file="$1"
    local json="$2"
    local body="${3:-}"

    # Write JSON on line 1
    echo "$json" >"$file"
    if [[ -n "$body" ]]; then
        # Blank line separator, then body
        echo "" >>"$file"
        printf '%s\n' "$body" >>"$file"
    else
        echo "" >>"$file"
    fi
}

# --- Lock helpers ---

# Check whether a todo is locked by an active session.
# Exits with an error if the lock exists and is younger than LOCK_TTL_SECONDS.
check_lock() {
    local id="$1"
    local lockfile="${TODOS_DIR}/${id}.lock"

    if [[ ! -f "$lockfile" ]]; then
        return 0
    fi

    # Get lock mtime as epoch seconds (macOS / Linux compatible)
    local lock_epoch
    lock_epoch="$(stat -f %m "$lockfile" 2>/dev/null || stat -c %Y "$lockfile" 2>/dev/null)" || return 0

    local now_epoch
    now_epoch="$(date +%s)"

    local age=$(( now_epoch - lock_epoch ))
    if (( age < LOCK_TTL_SECONDS )); then
        echo "Error: TODO-${id^^} is locked by an active session (lock age ${age}s < ${LOCK_TTL_SECONDS}s). Try again later or remove ${lockfile} manually." >&2
        return 1
    fi

    # Lock is stale – ignore it (optionally clean up)
    rm -f "$lockfile"
    return 0
}

# --- Ensure directory exists ---
ensure_dir() {
    mkdir -p "$TODOS_DIR"
}

# --- Commands ---

cmd_list() {
    local show_all=false
    if [[ "${1:-}" == "--all" ]]; then
        show_all=true
    fi

    if [[ ! -d "$TODOS_DIR" ]]; then
        echo "No todos."
        return 0
    fi

    local assigned=()
    local open=()
    local closed=()

    for file in "$TODOS_DIR"/*.md; do
        [[ -f "$file" ]] || continue
        local id
        id="$(basename "$file" .md)"

        local status title tags assigned_to
        status="$(get_field "$file" "status")"
        title="$(get_field "$file" "title")"
        tags="$(read_front_matter "$file" | jq -r 'if (.tags // []) | length > 0 then " [" + (.tags | join(", ")) + "]" else "" end')"
        assigned_to="$(get_field "$file" "assigned_to_session")"

        local display_id="TODO-${id^^}"
        : "${status:=open}"
        : "${title:=(untitled)}"

        local assignment=""
        if [[ -n "$assigned_to" ]]; then
            assignment=" (assigned: ${assigned_to})"
        fi

        local line="  ${display_id} ${title}${tags}${assignment} (${status})"

        case "$status" in
        closed | done)
            if $show_all; then
                closed+=("$line")
            fi
            ;;
        *)
            if [[ -n "$assigned_to" ]]; then
                assigned+=("$line")
            else
                open+=("$line")
            fi
            ;;
        esac
    done

    if [[ ${#assigned[@]} -eq 0 && ${#open[@]} -eq 0 && ${#closed[@]} -eq 0 ]]; then
        echo "No todos."
        return 0
    fi

    print_section() {
        local label="$1"
        shift
        local items=("$@")
        echo "${label} (${#items[@]}):"
        if [[ ${#items[@]} -eq 0 ]]; then
            echo "  none"
        else
            for item in "${items[@]}"; do
                echo "$item"
            done
        fi
    }

    print_section "Assigned todos" "${assigned[@]}"
    echo ""
    print_section "Open todos" "${open[@]}"
    if $show_all; then
        echo ""
        print_section "Closed todos" "${closed[@]}"
    fi
}

cmd_get() {
    local raw_id="$1"
    local id
    id="$(validate_id "$raw_id")" || return 1
    local file="${TODOS_DIR}/${id}.md"

    if [[ ! -f "$file" ]]; then
        echo "Error: TODO-${id^^} not found." >&2
        return 1
    fi

    local body
    body="$(read_body "$file")"

    # Print full JSON with formatted id, then body
    read_front_matter "$file" | jq --arg prefix "TODO-" --arg raw "$id" '.id = ($prefix + ($raw | ascii_upcase))'
    if [[ -n "$body" ]]; then
        echo ""
        echo "$body"
    fi
}

cmd_create() {
    local title="" tags="" status="open" body=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --title)
            title="$2"
            shift 2
            ;;
        --tags)
            tags="$2"
            shift 2
            ;;
        --status)
            status="$2"
            shift 2
            ;;
        --body)
            body="$2"
            shift 2
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            return 1
            ;;
        esac
    done

    if [[ -z "$title" ]]; then
        echo "Error: --title is required." >&2
        return 1
    fi

    ensure_dir

    local id
    id="$(generate_id)" || return 1

    # Build tags JSON array
    local tags_json
    if [[ -n "$tags" ]]; then
        # Split by comma
        tags_json="$(echo "$tags" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";""))')"
    else
        tags_json="[]"
    fi

    local created_at
    created_at="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"

    local json
    json="$(jq -n \
        --arg id "$id" \
        --arg title "$title" \
        --argjson tags "$tags_json" \
        --arg status "$status" \
        --arg created_at "$created_at" \
        '{id: $id, title: $title, tags: $tags, status: $status, created_at: $created_at}' | jq .)"

    local file="${TODOS_DIR}/${id}.md"
    write_todo_file "$file" "$json" "$body"

    # Output the created todo
    echo "$json" | jq --arg prefix "TODO-" --arg raw "$id" '.id = ($prefix + ($raw | ascii_upcase))'
    if [[ -n "$body" ]]; then
        echo ""
        echo "$body"
    fi
}

cmd_update() {
    local raw_id="$1"
    shift
    local id
    id="$(validate_id "$raw_id")" || return 1
    local file="${TODOS_DIR}/${id}.md"

    if [[ ! -f "$file" ]]; then
        echo "Error: TODO-${id^^} not found." >&2
        return 1
    fi

    check_lock "$id" || return 1

    local json
    json="$(read_front_matter "$file")"
    local body
    body="$(read_body "$file")"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --title)
            json="$(echo "$json" | jq --arg v "$2" '.title = $v')"
            shift 2
            ;;
        --status)
            json="$(echo "$json" | jq --arg v "$2" '.status = $v')"
            # Clear assignment if closing
            if [[ "$2" == "closed" || "$2" == "done" ]]; then
                json="$(echo "$json" | jq 'del(.assigned_to_session)')"
            fi
            shift 2
            ;;
        --tags)
            local tags_json
            if [[ -n "$2" ]]; then
                tags_json="$(echo "$2" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";""))')"
            else
                tags_json="[]"
            fi
            json="$(echo "$json" | jq --argjson v "$tags_json" '.tags = $v')"
            shift 2
            ;;
        --body)
            body="$2"
            shift 2
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            return 1
            ;;
        esac
    done

    write_todo_file "$file" "$(echo "$json" | jq .)" "$body"

    # Output updated todo
    echo "$json" | jq --arg prefix "TODO-" --arg raw "$id" '.id = ($prefix + ($raw | ascii_upcase))'
    if [[ -n "$body" ]]; then
        echo ""
        echo "$body"
    fi
}

cmd_append() {
    local raw_id="$1"
    local text="$2"
    local id
    id="$(validate_id "$raw_id")" || return 1
    local file="${TODOS_DIR}/${id}.md"

    if [[ ! -f "$file" ]]; then
        echo "Error: TODO-${id^^} not found." >&2
        return 1
    fi

    check_lock "$id" || return 1

    local json
    json="$(read_front_matter "$file")"
    local body
    body="$(read_body "$file")"

    if [[ -n "$body" ]]; then
        # Strip trailing whitespace/newlines to avoid massive gaps (matches todos.ts .replace(/\s+$/, ""))
        body="$(printf '%s' "$body" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
        body="${body}

${text}"
    else
        body="$text"
    fi

    write_todo_file "$file" "$(echo "$json" | jq .)" "$body"

    # Output updated todo
    echo "$json" | jq --arg prefix "TODO-" --arg raw "$id" '.id = ($prefix + ($raw | ascii_upcase))'
    echo ""
    echo "$body"
}

cmd_delete() {
    local raw_id="$1"
    local id
    id="$(validate_id "$raw_id")" || return 1
    local file="${TODOS_DIR}/${id}.md"

    if [[ ! -f "$file" ]]; then
        echo "Error: TODO-${id^^} not found." >&2
        return 1
    fi

    check_lock "$id" || return 1

    # Print the todo before deleting
    local json
    json="$(read_front_matter "$file")"
    echo "Deleted TODO-${id^^}: $(echo "$json" | jq -r '.title')"

    rm "$file"
    rm -f "${TODOS_DIR}/${id}.lock"
}

cmd_claim() {
    local raw_id="$1"
    shift
    local agent_name=""
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --agent)
            agent_name="$2"
            shift 2
            ;;
        --force)
            force=true
            shift
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            return 1
            ;;
        esac
    done

    if [[ -z "$agent_name" ]]; then
        echo "Error: --agent <name> is required (e.g. pi, codex, agy)." >&2
        return 1
    fi

    local id
    id="$(validate_id "$raw_id")" || return 1
    local file="${TODOS_DIR}/${id}.md"

    if [[ ! -f "$file" ]]; then
        echo "Error: TODO-${id^^} not found." >&2
        return 1
    fi

    check_lock "$id" || return 1

    local json
    json="$(read_front_matter "$file")"
    local body
    body="$(read_body "$file")"

    local status
    status="$(echo "$json" | jq -r '.status')"
    if [[ "$status" == "closed" || "$status" == "done" ]]; then
        echo "Error: TODO-${id^^} is closed." >&2
        return 1
    fi

    local current
    current="$(echo "$json" | jq -r '.assigned_to_session // ""')"
    if [[ -n "$current" && "$current" != "$agent_name" ]]; then
        if ! $force; then
            echo "Error: TODO-${id^^} is assigned to '${current}'. Use --force to override." >&2
            return 1
        fi
    fi

    json="$(echo "$json" | jq --arg v "$agent_name" '.assigned_to_session = $v')"
    write_todo_file "$file" "$(echo "$json" | jq .)" "$body"

    echo "Claimed TODO-${id^^} for '${agent_name}'."
}

cmd_release() {
    local raw_id="$1"
    local id
    id="$(validate_id "$raw_id")" || return 1
    local file="${TODOS_DIR}/${id}.md"

    if [[ ! -f "$file" ]]; then
        echo "Error: TODO-${id^^} not found." >&2
        return 1
    fi

    check_lock "$id" || return 1

    local json
    json="$(read_front_matter "$file")"
    local body
    body="$(read_body "$file")"

    json="$(echo "$json" | jq 'del(.assigned_to_session)')"
    write_todo_file "$file" "$(echo "$json" | jq .)" "$body"

    echo "Released TODO-${id^^}."
}

cmd_gc() {
    local gc=true
    local gc_days=7

    # Read settings if they exist
    if [[ -f "${TODOS_DIR}/settings.json" ]]; then
        gc="$(jq -r '.gc // true' "${TODOS_DIR}/settings.json")"
        gc_days="$(jq -r '.gcDays // 7' "${TODOS_DIR}/settings.json")"
    fi

    if [[ "$gc" != "true" ]]; then
        echo "Garbage collection is disabled in settings."
        return 0
    fi

    if [[ ! -d "$TODOS_DIR" ]]; then
        return 0
    fi

    local cutoff_epoch
    # macOS and Linux compatible date calculation
    if date -v-${gc_days}d +%s &>/dev/null; then
        cutoff_epoch="$(date -v-${gc_days}d +%s)"
    else
        cutoff_epoch="$(date -d "${gc_days} days ago" +%s)"
    fi

    local deleted=0
    for file in "$TODOS_DIR"/*.md; do
        [[ -f "$file" ]] || continue

        local status
        status="$(get_field "$file" "status")"
        [[ "$status" == "closed" || "$status" == "done" ]] || continue

        local created_at
        created_at="$(get_field "$file" "created_at")"
        [[ -n "$created_at" ]] || continue

        local created_epoch
        created_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%S" "${created_at:0:19}" +%s 2>/dev/null)" ||
            created_epoch="$(date -d "$created_at" +%s 2>/dev/null)" || continue

        if [[ "$created_epoch" -lt "$cutoff_epoch" ]]; then
            rm "$file"
            deleted=$((deleted + 1))
        fi
    done

    echo "Garbage collection complete. Deleted ${deleted} closed todo(s) older than ${gc_days} day(s)."
}

# --- Main dispatch ---
usage() {
    cat <<'EOF'
Usage: todo.sh <command> [options]

Commands:
  list [--all]                           List todos (open + assigned; --all includes closed)
  get <id>                               Show a single todo (id: TODO-xxxx or hex)
  create --title "..." [--tags t1,t2]    Create a new todo
          [--status open] [--body "..."]
  update <id> [--title "..."]            Update todo fields
          [--status ...] [--tags t1,t2]
          [--body "..."]
  append <id> "text"                     Append text to a todo's body
  delete <id>                            Delete a todo
  claim <id> --agent <name> [--force]    Claim a todo for an agent
  release <id>                           Release a todo's assignment
  gc                                     Garbage collect old closed todos

Environment:
  PI_TODO_PATH  Override todo directory (default: .pi/todos)
EOF
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

command="$1"
shift

case "$command" in
list) cmd_list "$@" ;;
get) cmd_get "$@" ;;
create) cmd_create "$@" ;;
update) cmd_update "$@" ;;
append) cmd_append "$@" ;;
delete) cmd_delete "$@" ;;
claim) cmd_claim "$@" ;;
release) cmd_release "$@" ;;
gc) cmd_gc ;;
--help | -h) usage ;;
*)
    echo "Error: Unknown command: ${command}" >&2
    usage
    exit 1
    ;;
esac
