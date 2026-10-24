# Issue tracker: br (beads)

Issues and specs for this repo live in the local beads workspace at `.beads/`, managed with the `br` CLI. State is stored in SQLite (`.beads/beads.db`, git-ignored) and exported to `.beads/issues.jsonl` (committed) for handoff. Never use `gh` or `glab` for this repo.

IDs are prefixed `zsa-` (e.g. `zsa-q20`, child `zsa-q20.1`).

## Conventions

- **Create an issue**: `br create --title "..." --description "..." --type task|bug|feature|epic|chore|docs|question --priority 0-4 --labels "..."`. Use `--description-file -` for multi-paragraph markdown. `--parent <id>` creates a child issue; `--silent` prints only the new ID.
- **Read an issue**: `br show <id> --json` (includes labels, comments, dependencies, dependents, parent).
- **List issues**: `br list --status open --json` (JSON envelope: `{"issues": [...]}`); filter with `--label` (AND) / `--label-any` (OR), `--status`, `--type`, `--assignee`.
- **Find actionable work**: `br ready --json` — open, unblocked, non-deferred issues. This is the work-discovery entrypoint; don't hand-roll status filters.
- **Search**: `br search "keyword" --json`.
- **Comment**: `br comments add <id> --message "..."` (or `--file <path>`).
- **Apply / remove labels**: `br label add <id> --label "needs-triage"` / `br label remove <id> --label "..."`; `br label list-all --json`.
- **Claim**: `br update <id> --claim --actor "$AGENT_NAME" --json` (sets `in_progress` + assignee).
- **Close**: `br close <id> --reason "Completed: <specific proof>" --json`; `--transition-comment "..."` commits a comment with the close.
- **Dependencies**: `br dep add <child> <blocker>` (child depends on blocker); `br dep remove <child> <blocker>`; `br blocked --json`; `br dep tree <id>`.
- **Epics / children**: `br create --parent <id> ...`; `br epic status --json`; `br epic close-eligible`.

## Sync and commits

`br` never runs git. Writes auto-export to `.beads/issues.jsonl` by default; run `br sync --flush-only` before ending a session to be certain. Commit `.beads/issues.jsonl` together with the code changes it describes. Never commit `.beads/beads.db` or its sidecars — `.beads/.gitignore` already excludes them.

## Pull requests as a triage surface

**PRs as a request surface: no.** `/triage` handles issues only in this repo.

## When a skill says "publish to the issue tracker"

Create a `br` issue.

## When a skill says "fetch the relevant ticket"

Run `br show <id> --json`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is an epic; **child** issues are tickets.

- **Map**: `br create --title "..." --type epic --labels wayfinder:map --description "..."`.
- **Child ticket**: `br create --title "..." --parent <map-id> --labels wayfinder:<research|prototype|grilling|task> --type task`. Child IDs inherit the map ID (`<map-id>.<n>`).
- **Blocking**: `br dep add <child> <blocker>`. A ticket is unblocked when every blocker is closed; `br ready --json` reflects this.
- **Frontier query**: `br show <map-id> --json`, take `dependents[]` that are `open`/`in_progress`, drop any absent from `br ready --json` (blocked or deferred) or already assigned; first in map order wins.
- **Claim**: `br update <id> --claim --actor "$AGENT_NAME" --json` as the session's first write.
- **Resolve**: `br comments add <id> --message "<answer>"`, then `br close <id> --reason "<proof>"`, then `br update <map-id> --append-notes "<gist + issue id>"`.
