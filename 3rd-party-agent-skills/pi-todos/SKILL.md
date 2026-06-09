---
name: pi-todos
description: "Manage file-based todos in .pi/todos. Create, list, update, append, delete, claim, and release todos. Shares the same format as pi's built-in todo extension so todos are interoperable across pi, Codex, and other agent tools. Use when the user asks to manage tasks or todos, or when you need to track work items."
compatibility: Requires bash, jq, and openssl
---

# pi-todos

Manage todos stored as files in `.pi/todos/` (or the path in `PI_TODO_PATH`). The file format is fully compatible with pi's built-in todo extension — todos created here are visible in pi and vice versa.

## File Format

Each todo is a file `<hex-id>.md` in the todo directory:

```
{"id":"a1b2c3d4","title":"Add tests","tags":["qa"],"status":"open","created_at":"2026-01-25T17:00:00.000Z"}
```

```
Optional markdown body describing the task.
```

Line 1 is a JSON object. Line 2 is blank. Line 3+ is optional markdown body text.

JSON fields: `id`, `title`, `tags` (array), `status`, `created_at`, `assigned_to_session` (optional).

## Quick Reference

Run `scripts/todo.sh` from this skill's directory:

```bash
# List open + assigned todos
./scripts/todo.sh list

# List all todos including closed
./scripts/todo.sh list --all

# Create a todo
./scripts/todo.sh create --title "Implement auth" --tags "backend,security" --body "Use OAuth2 with PKCE flow"

# Get a specific todo
./scripts/todo.sh get TODO-a1b2c3d4

# Update fields (only specify what you want to change)
./scripts/todo.sh update TODO-a1b2c3d4 --status "in-progress" --body "Updated description"

# Append notes to the body (does not replace existing body)
./scripts/todo.sh append TODO-a1b2c3d4 "Discovered edge case with token refresh"

# Delete a todo
./scripts/todo.sh delete TODO-a1b2c3d4

# Claim a todo for your agent (prevents duplicate work)
./scripts/todo.sh claim TODO-a1b2c3d4 --agent codex

# Release a todo assignment
./scripts/todo.sh release TODO-a1b2c3d4

# Garbage collect closed todos older than 7 days
./scripts/todo.sh gc
```

## Workflow

1. **Before starting work**, run `list` to see open todos. If you see relevant tasks, `claim` one with `--agent <your-tool-name>` to signal ownership.
2. **Create todos** for new tasks with descriptive titles and optional tags/body.
3. **Update status** as you work: `open` → `in-progress` → `closed` (or `done`).
4. **Append notes** to track progress rather than replacing the body.
5. **Release** if you can't finish a task so another agent can pick it up.
6. **Run `gc`** periodically to clean up old closed todos.

## ID Format

Todo IDs are 8-character hex strings displayed as `TODO-XXXXXXXX`. Commands accept both the prefixed form (`TODO-a1b2c3d4`) and raw hex (`a1b2c3d4`).

## Cross-Tool Compatibility

This skill writes the same `.pi/todos/` format as pi's native todo extension. Todos are shared:
- **pi**: Uses the built-in `todo` tool and `/todos` command.
- **Codex / AGY / others**: Use this skill's `scripts/todo.sh`.

All tools read and write the same files. The `assigned_to_session` field tracks which agent owns a task — use `--agent` with a descriptive name (e.g., `pi`, `codex`, `agy`).
