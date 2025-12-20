# AI Workflow (Template)
#
# This file is intentionally repository-agnostic.
# It defines a structural framework for AI-assisted work without prescribing
# tools, commands, depth, or domain-specific checklists.
#
# The AI is expected to fill this in based on the current situation.

---

## Situation

- What is being asked / desired outcome:
- Constraints (time, risk, environment, scope):
- What is already running / in progress (if relevant):
- Autonomy boundary (when to ask first):
  - Destructive actions, system-wide changes, or irreversible steps.
  - Decisions with multiple reasonable “policy” outcomes.
  - Anything that changes external state beyond the repo/workspace.
- Default autonomy (when intent is clear):
  - Work end-to-end: implement → validate → sync docs/notes → record changes.
  - Keep user-facing docs consistent with actual behavior.
  - If the user requested it, stage/commit/push as part of the same flow.

---

## Orientation

_(What I looked at to understand the repo/state before changing anything)_

- Repo state (branch, dirty/clean, recent changes):
- Relevant files/areas:
- Existing workflows/patterns to respect:
- Risks to avoid:
- If asked for “status” (e.g. build/run progress): identify what is currently running and report the latest observable progress signal(s) and any errors.

---

## Intent

- What I intend to change (minimal set):
- What I explicitly will not change:
- Success criteria:
- If anything is ambiguous: clarify or state assumptions explicitly.

---

## Execution

_(What I changed and why)_

- Changes made:
- Decisions/tradeoffs:
- User-facing workflows impacted:

---

## Validation

_(What I ran/checked to build confidence)_

- Quick checks:
- Targeted checks:
- What remains unverified (and why):
- Always distinguish “verified” vs “assumed/planned”.

---

## Knowledge Capture

_(What I updated so future readers/AIs understand the state)_

- Docs updated:
- Notes/experience captured:
- Open questions / TODOs recorded:
- Prefer a single source of truth for configuration; avoid duplicating it across files.

---

## Change Recording

_(How I recorded changes in version control)_

- What I staged:
- Commit(s) and intent:
- Push/PR context:
- Guidelines (repo-agnostic):
  - Keep commits small and purpose-driven; avoid mixing unrelated changes.
  - If a file changed unintentionally, revert it before committing.
  - Write commit intent so a future reader can understand “what/why” quickly.
  - Treat long-running/stateful operations as explicit steps (make progress observable, capture logs/status).

---

## Resulting State

- What now works:
- What is still broken/blocked:
- How to reproduce:

---

## Handover

- Next steps:
- Where to look for logs/errors:
- Known pitfalls/watchouts:
- Preferred status output style (concise):
  - Current state (running/blocked/complete) in 1 line.
  - 1–3 most relevant signals (latest progress + any error summary).
  - Exact next command(s) to run, if applicable.
  - Avoid repeating commit hashes if the commit/push output is already visible in the session logs.
