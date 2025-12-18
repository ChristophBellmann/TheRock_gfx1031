# Short Doc Comparison: gfx1031-support-and-docs vs current branch

Date: 2025-12-18

## Scope

Quick delta between:
- Branch: `gfx1031-support-and-docs`
- Current: `hashcat/rocm-7.11-gfx103X`
- Local notes: `README.md` + `BUILD_EXPERIENCE_NOTES.md`

## Key Differences (short)

1) **ROCm version + focus**
   - Old branch docs: ROCm 7.10, RX 6700 XT (gfx1031) only.
   - Current docs/notes: ROCm 7.11, gfx103X family, more general.

2) **Build workflow**
   - Old docs: custom scripts (`build_low_memory.sh`, `install_systemwide.sh`, etc.).
   - Current notes: direct CMake/Ninja with `-j1`, optional `systemd-run` memory caps.
   - Result: old workflow files referenced in docs are missing in current branch.

3) **Doc layout**
   - Old branch: many root-level guides (LOW_MEMORY_BUILD.md, TEST_ROCM.md, BUILD_SUCCESS_*.md, COMMANDS_CHEATSHEET.md, QUICK_COMMANDS.md).
   - Current branch: reorganized into `docs/` with index in `docs/README.md`.

4) **Known issues / status**
   - Old docs: generic “hipBLASLt/hipSPARSELt excluded”.
   - Current notes: explicit hipBLASLt segfault + unsupported gfx1031 in standalone CMake.

5) **Repo scope guidance**
   - Old branch: `docs/REPO_SCOPE.md` explains what to keep/prune.
   - Current branch: no equivalent scope/cleanup guide.

## Items that are outdated vs current experience

- ROCm 7.10 references (old); current is 7.11.
- Low-memory scripts listed in old README are not present now.
- Old file map (root-level docs) doesn’t match current `docs/` layout.

## Items worth reusing or porting (if desired)

- `docs/REPO_SCOPE.md` (clear keep/prune rules).
- Concise quick-start + test checklist idea (but update for ROCm 7.11 + current tooling).
