# AI Workflow (Validation Suite)
_This document is a concrete workflow for maintaining and extending the validation suite under `validation/`._

It follows the structure of the repository-agnostic template in `AI_WORKFLOW.md`,
but is scoped specifically to **validation** (in-tree ROCm, plus optional third‑party app checks).

---

## Situation

- **Desired outcome:** keep `validation/run_validation.py` and `validation/therock_validation/` a reliable “usability proof” of the in-tree build, and (optionally) a practical integration test bed.
- **Constraints:**
  - Must run against `<builddir>/dist/rocm` (no `/opt/rocm` assumptions).
  - Downloads/builds must be **explicitly confirmed** (Y/n) and bounded; avoid surprise multi‑GB downloads.
  - Prefer user-space install locations under `validation/_cache/` and `validation/_build/`.
  - Keep test numbering stable once published (so notes can reference IDs).
- **Autonomy boundary:** do not install system packages, enable systemd services, modify `/usr`, or download huge artifacts without prompting and documenting size/impact.

---

## Orientation

- Check repo status and `validation/` tree.
- Confirm where ROCm is expected (`build-stage2/dist/rocm` etc.).
- Identify what is already cached under `validation/_cache/`.
- If a check fails, inspect the corresponding log (use `--log`) and the last printed command.

---

## Intent

- Make the smallest changes that:
  - Keep core in-tree ROCm checks reliable (HIP compile+run, rocminfo, benches).
  - Add third-party checks in a way that is:
    - opt-in via Y/n prompt
    - cached
    - reproducible (fixed inputs, stable versions where feasible)
- Do **not** refactor unrelated build scripts or change TheRock build behavior from validation work.

---

## Execution

- Add/modify checks in `validation/therock_validation/checks/`:
  - Keep `idx` stable once released.
  - Use `SKIP` for missing prerequisites; use `FAIL` for real malfunctions.
  - Make expected runtime realistic and hardware-aware (gfx1031 / RX 6700 XT).
- Keep downloads/builds in user-space:
  - `validation/_cache/` for downloads/clones
  - `validation/_build/` for build directories
- Ensure every third-party check can be disabled via `--no-downloads`.

---

## Validation

- Always run a small smoke subset first:
  - `python3 validation/run_validation.py --no-downloads --select 1,2,3,4,5,6 --log /tmp/validation_smoke.log`
- If adding a third-party check:
  - Verify the “plan” (`--select 9`) prints expected size/impact.
  - Run the specific check with `--yes --log ...` and confirm it respects cache locations.
- Clearly label what was actually verified vs. planned.

---

## Knowledge Capture

- Update `validation/README.md` when:
  - new checks are added
  - defaults or prompts change
  - cache/build locations change
- Record new large dependencies (and approximate sizes) in `validation/README.md`.
- Prefer keeping configuration centralized in the validation code; avoid duplicating logic in README.

---

## Change Recording

- Keep commits focused:
  - “validation: add MFEM HIP check”
  - “validation: fix Ollama download URL”
- Ensure generated files and caches stay gitignored (`validation/_cache/`, `_build/`, `_logs/`, `validation/.venv/`).

---

## Resulting State

- Core ROCm usability checks run successfully from a clean clone after building Stage‑2.
- Third-party checks:
  - prompt before downloads/builds
  - can be disabled
  - leave artifacts only under `validation/_cache/`/`validation/_build/`

---

## Handover

- First command to run:
  - `python3 validation/run_validation.py --no-downloads --select 0 --log /tmp/validation.log`
- If third-party checks are desired:
  - `python3 validation/run_validation.py --select 0 --yes --log /tmp/validation_full.log`
- If a check fails: re-run with `--log` and include the last command output + return code.

