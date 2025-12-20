# AI Workflow

This document defines the structure of AI-assisted work in this repository.
It intentionally contains no concrete instructions.
The AI is expected to fill in the details based on context, repository state,
and ongoing work.
We are enthusiastic about contributions to our code and documentation.

---

## 1. Context & Initial State

- Repository purpose:
  - Provide a reproducible, GPU-targeted build of TheRock/ROCm components (plus docs and helper scripts) with a strong emphasis on repeatability, path/toolchain hygiene, and clear operational handover.
- Current branch / focus:
  - Work happens on the currently checked out feature/maintenance branch (e.g. `hashcat/rocm-7.11-gfx103X`) and is scoped to the requested deliverable (scripts, build fixes, docs updates).
- Relevant constraints (platform, tooling, scope):
  - Linux system environment (systemd available), large builds (RAM-sensitive), heavy dependency graph, and “superbuild” style CMake/Ninja orchestration.
  - Prefer `ninja` directly over `cmake --build` to reduce indirection and make ordering explicit.
  - Use memory limits for long builds via `systemd-run --user --scope` / `systemd-run --user --no-block --collect`.
  - Avoid mixing system ROCm (`/opt/rocm`) with in-tree/dist artifacts unless explicitly desired.
  - Keep changes minimal and targeted; no unrelated refactors.
- Known limitations or assumptions:
  - Not all build paths can be validated end-to-end within a single session; anything unverified must be explicitly documented.
  - Long-running builds cannot be “live monitored” by an AI outside tool calls; monitoring is implemented via logs and systemd units (human can tail/inspect at will).
  - Tool availability varies; scripts should fail fast with actionable messages.

---

## 2. Inspection

_(What the AI checked before making changes)_

- Repository state:
  - `git status` / current branch / last commit.
  - Whether a build is currently running (process list + systemd units).
  - Presence of expected directories (`rocm-libraries/`, `rocm-systems/`, `build_tools/`).
- Relevant files / areas:
  - The entry scripts (`build_*.sh`, `test_*.sh`, `monitor_*.sh`), config (`config_*.yaml`), and docs (`README.md`, `BUILD_EXPERIENCE_NOTES.md`).
  - Any generated or cached state that could influence behavior (CMake caches, `dist/` layout, logs).
- Existing workflows or patterns:
  - How the repo expects configure/build/stage/dist to be driven (CMake topology, Ninja targets like `<name>+configure/+build/+stage/+dist/+expunge`).
  - Existing helper scripts and their conventions (logging, memory limits, ccache, venv).
- Signals from history, scripts, or documentation:
  - Docs describing recommended build flags and known failure modes.
  - Evidence of path/toolchain contamination in `build/**/CMakeCache.txt` and logs (e.g. `/opt/rocm`, `/usr/lib/llvm-18` fallback).
  - Prior “lessons learned” in `BUILD_EXPERIENCE_NOTES.md` that should be preserved or updated.

---

## 3. Working Plan (Ephemeral)

_(Short-lived plan derived from inspection; may change during work)_

- Objective:
  - Deliver the smallest possible change set that achieves the request (e.g. repeatable scripts, toolchain hygiene, consistent docs, correct Git history).
- Sub-steps:
  - Align on the desired workflow and constraints (toolchain, stage separation, logging, locking).
  - Implement the requested change in code/scripts first (minimal diff, no unrelated churn).
  - Add guard rails (sanity checks, lock, consistent defaults).
  - Update docs/notes to reflect the *actual* behavior.
  - Validate with quick checks (syntax, targeted runs, consistency scans).
  - Commit/push in focused commits.
- Files likely affected:
  - The relevant script(s) and the docs that describe them (`README.md`, `BUILD_EXPERIENCE_NOTES.md`), plus config files if requested.
- Validation approach:
  - Shell syntax checks (`bash -n`).
  - Targeted “smoke” execution of scripts where feasible (configure/bootstrap/build/test consistency).
  - Lightweight consistency scans (e.g. `/opt/rocm` in CMake caches, compiler/toolchain paths).
  - Avoid running full suites unless required; document what remains unverified.

---

## 4. Implementation

_(What was changed and why)_

- Scripts / code touched:
  - Prefer a small number of repo-entry scripts that cover the whole lifecycle:
    - Configure (top-level CMake)
    - Bootstrap (early sysdeps / dist configs)
    - Build/Rebuild/Expunge (Ninja targets)
    - Test/Consistency checks
    - Monitor (systemd/log tail helper)
  - Add “guard rails” inside scripts:
    - fail-fast prerequisites
    - lock to prevent concurrent builds in same build dir
    - log rotation and consistent logging
    - explicit env hygiene (avoid accidental path mixing)
- Configuration changes:
  - Prefer a single editable configuration file (`config_*.yaml`) as the source of defaults.
  - Allow overrides via environment variables and CLI flags (env always wins).
- Structural decisions:
  - Separate Stage-1 vs Stage-2 bootstrapping with distinct build directories (avoid compiler switching inside one build dir).
  - Prefer absolute compiler paths for “regenerate during build” robustness.
  - Keep the build graph driven by Ninja targets (no custom sequencing beyond what’s necessary).
- Removed or consolidated components (if any):
  - Remove redundant wrappers once their behavior is fully integrated elsewhere, but only after:
    - functionality parity is confirmed,
    - README/notes are updated,
    - the change is committed as a clearly described, intentional action.

---

## 5. Verification

_(How correctness and consistency were assessed)_

- Syntax / consistency checks:
  - `bash -n` on modified shell scripts.
  - Spot-checks with `rg`/`sed` for removed references, renamed units, updated workflow steps.
- Build / run validation:
  - Run `configure` and `bootstrap` in a controlled way (memory limits, logs).
  - For long builds: run detached via systemd and verify via monitor + log tail.
  - Use consistency checks to catch “silent” issues (path/toolchain leakage).
- Runtime or environment assumptions:
  - systemd user services are available.
  - `.venv` can be created and `requirements.txt` installed locally.
  - `ccache` is available and configured via the repo helper.
- What was intentionally not verified yet:
  - Any full “end-to-end” build that was not actually executed is called out as pending in notes.
  - Deep runtime/linkage checks are optional; they are run only when requested because they can be slow/noisy.

---

## 6. Documentation Synchronization

_(How knowledge was captured)_

- README updates:
  - Update commands to match *current* scripts and defaults.
  - Document workflows (clean build, reconfigure, Stage-1/Stage-2, detached builds, monitoring, consistency tests).
  - Document important environment assumptions (memory limits, LD_LIBRARY_PATH hygiene, ccache/venv).
- Experience / notes updates:
  - Record what failed, what fixed it, and what the recovery steps are.
  - Prefer concrete paths and commands; avoid “hand-wavy” statements.
  - Clearly mark anything “not yet validated end-to-end”.
- Inline comments or rationale added:
  - Add concise comments in build scripts or CMake where a future maintainer would otherwise re-discover the rationale (e.g. expensive optional features, bootstrap gating).
- Things explicitly documented as open or pending:
  - Anything that “should work” but was not executed is explicitly labeled as pending verification.

---

## 7. Version Control

_(How changes were recorded)_

- Files staged:
  - Stage only files relevant to the request; avoid opportunistic edits.
  - If a file changed unintentionally (editor noise), revert it before committing.
- Commit granularity rationale:
  - Prefer small, purpose-driven commits:
    - “Refactor/config change” separated from “doc update”, unless they must land together to stay accurate.
    - If a change is risky or structural (e.g. removing a script), isolate it with a clear commit message.
- Commit intent (what this commit represents):
  - The commit message should answer: “what problem does this solve, at a glance?”
  - Include key nouns (e.g. `gfx1031`, `bootstrap`, `stage2 toolchain`, `consistency checks`).
- Branch / push context:
  - Work is pushed to the active branch used for the build.
  - Push after commits are consistent with docs and tests run (or clearly noted as pending).

---

## 8. Resulting State

_(Snapshot after the work)_

- What now works:
  - A repeatable command sequence exists (configure → bootstrap → build), with logging and memory limits.
  - Consistency checks exist to catch common “phantom” failure causes (path/toolchain leakage).
  - Monitoring of detached builds is possible via systemd + log helpers.
- What remains unresolved:
  - Anything not actually built/tested is listed explicitly in notes (and not silently assumed).
  - Unsupported/unstable optional components are kept off by default and documented as such.
- Current system/build state:
  - Build state is represented by build directories and logs; scripts avoid modifying system state by default.
  - Detached builds are discoverable as systemd user units.
- Reproducibility notes:
  - Defaults are in config YAML, overrides are explicit (env/CLI).
  - Concurrency is guarded by a lock per build directory.
  - Bootstrap verification prevents building a “half-prepared” tree.

---

## 9. End-of-Session Summary

_(Compact handover for humans and future AI sessions)_

- Key changes:
  - List the entrypoints that should be used (scripts/config) and any removed legacy paths.
  - Note the key safety mechanisms added (lock, bootstrap verification, consistency checks).
- How to continue:
  - Provide copy/paste command sequences for the next step (Stage-2 configure/build, running tests, monitoring).
  - Point to the relevant log files and how to interpret failures.
- Next logical steps:
  - Run the next stage or enable a new component; re-run configure/bootstrap as needed.
  - Run consistency checks after major changes.
- Known risks or watchouts:
  - Don’t switch compilers in-place inside a build dir; use a fresh directory.
  - Watch for `/opt/rocm` leakage and unintended system compiler fallback.
  - Be careful with background builds: unit names and log files matter for diagnosis.

---

## Notes

- This workflow is descriptive, not prescriptive.
- Details are expected to emerge from context.
- The structure matters more than the content.
