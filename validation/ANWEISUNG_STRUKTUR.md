validation/ liegt bereits im TheRock-Repo und ist Teil des Build-Workflows (post-build “echte Workloads”), nicht ein separates Standalone-Projekt. Dann muss die Struktur zwei Dinge sauber trennen:

Integration ins TheRock-Tree (Pfad-Discovery: wo liegt dist/, welche ROCm-Env soll getestet werden, gfx1031 etc.)

Validierungs-Workloads (llama.cpp via Docker, ollama, whisper, open-interpreter, MFEM meshing/solving)

Hier ist eine passende Ordnerstruktur innerhalb deines bestehenden validation/, logisch und “Build-Kontext aware”:

validation/
├─ README.md
├─ AI_WORKFLOW_VALIDATION.md
├─ run_validation.py                      # ein “freundlicher” Entry (delegiert an src/cli)
│
├─ pyproject.toml
├─ requirements-lock.txt
├─ .env.example
├─ .gitignore
│
├─ config/
│  ├─ defaults.yaml                       # alles enabled default; downloads nur nach Y/n
│  ├─ profiles/
│  │  ├─ full.yaml                        # volle Workloads
│  │  ├─ quick.yaml                       # ROCm sanity + HIP smoke (ohne große downloads)
│  │  └─ airgapped.yaml                   # alias/future-proof
│  └─ layout/
│     ├─ gfx_targets.yaml                 # z.B. gfx1031, default-arch detection rules
│     ├─ install_layouts.yaml             # wo findet man dist/ oder install prefix
│     └─ env_exports.yaml                 # LD_LIBRARY_PATH, PATH, ROCM_PATH etc. Templates
│
├─ scripts/                               # user-facing entrypoints (rufen src/cli auf)
│  ├─ _bootstrap.py                       # optional: venv sicherstellen
│  ├─ doctor.py                           # no downloads: system + in-tree sanity
│  ├─ validate.py                         # Y/n gating, dann pipeline (default full)
│  ├─ cache_gc.py
│  └─ report_open.py
│
├─ src/
│  ├─ __init__.py
│
│  ├─ cli/
│     │  ├─ __init__.py
│     │  ├─ main.py                       # validate/doctor/cache/report
│     │  └─ prompts.py                    # Y/n gating + non-interactive flags
│
│  ├─ core/
│     │  ├─ __init__.py
│     │  ├─ context.py                    # repo_root, validation_root, run_id, paths
│     │  ├─ tree.py                      # erkennt build-stage*, dist/, install prefix
│     │  ├─ rocm_env.py                   # “explizit laden”: env vars aus dist/ ableiten
│     │  ├─ runner.py                     # subprocess wrapper
│     │  ├─ download.py                   # fetch + verify + size policy
│     │  ├─ versions.py                   # optional update check + pinning
│     │  ├─ policy/
│     │  │  ├─ sizes.py                   # “GB-ish” limits
│     │  │  ├─ licenses.py                # notices/attribution checks
│     │  │  └─ timeouts.py
│     │  └─ reporting/
│     │     ├─ models.py
│     │     ├─ json_report.py
│     │     ├─ html_report.py
│     │     └─ summary.py
│
│  ├─ steps/
│     │  ├─ __init__.py
│     │  ├─ plan.py                       # aus profile+defaults Schritte bauen
│     │
│     │  ├─ doctor/
│     │  │  ├─ __init__.py
│     │  │  ├─ system.py                  # rocm-smi, amdsmi, hipcc, kernel modules
│     │  │  ├─ tree.py                    # prüft TheRock Struktur (dist vorhanden etc.)
│     │  │  └─ env.py                     # prüft ob ROCm env korrekt “ladbar” ist
│     │
│     │  ├─ rocm_sanity/
│     │  │  ├─ __init__.py
│     │  │  ├─ hip_smoke.py               # compile+run mini HIP kernel gegen DEIN dist
│     │  │  └─ libs_smoke.py              # optional: rocblas/miopen einfache checks
│     │
│     │  ├─ workloads/                    # “echte” Validierungen
│     │  │  ├─ __init__.py
│     │  │  ├─ llama_cpp/
│     │  │  │  ├─ __init__.py
│     │  │  │  ├─ docker_env.py           # AMD docs: Docker image/pull/run
│     │  │  │  └─ functional.py           # tiny inference
│     │  │  ├─ ollama/
│     │  │  │  ├─ __init__.py
│     │  │  │  ├─ setup.py                # service/local install oder container
│     │  │  │  └─ functional.py
│     │  │  ├─ whisper/
│     │  │  │  ├─ __init__.py
│     │  │  │  ├─ setup.py
│     │  │  │  └─ functional.py
│     │  │  ├─ open_interpreter/
│     │  │  │  ├─ __init__.py
│     │  │  │  ├─ setup.py
│     │  │  └─ functional.py
│     │  │  └─ mfem/
│     │  │     ├─ __init__.py
│     │  │     ├─ fetch.py
│     │  │     ├─ hip_build.py            # cmake -DMFEM_USE_HIP=YES ... gfx1031
│     │  │     ├─ meshing.py              # kleines meshing example
│     │  │     └─ solving.py              # kleines solve example
│     │  │
│     │  └─ post/
│     │     ├─ __init__.py
│     │     └─ cleanup.py
│
│     ├─ assets/
│     │  ├─ samples/
│     │  │  ├─ audio/sample_3s.wav
│     │  │  └─ prompts/tiny_prompt.txt
│     │  └─ notices/THIRD_PARTY_NOTICES.md
│
│     └─ data/
│        └─ pins/
│           ├─ versions.json              # pinned revisions/tags
│           └─ checksums.json
│
├─ workspace/                             # runtime (gitignored)
│  ├─ cache/
│  │  ├─ downloads/
│  │  ├─ git/
│  │  └─ docker/
│  ├─ builds/                             # mfem build dirs etc.
│  └─ runs/
│     └─ 2025-12-26_120102/
│        ├─ logs/
│        ├─ artifacts/
│        ├─ report.json
│        └─ report.html
│
├─ _cache/                                # falls du das bereits nutzt: behalten, aber definieren
│  └─ (legacy_or_symlink_to workspace/cache)
│
├─ tests/
│  ├─ unit/
│  └─ integration/
│
└─ (kein zusätzliches package-dir nötig; Code liegt direkt in `src/`)

Wichtiger Hinweis (weil du es schon im Tree hast)

Du hast aktuell beides: `validation/src` und ein zusätzliches package-dir. Das ist ein typischer Drift. Entscheide dich für eine dieser Varianten:

Empfohlen: `validation/src/…` (sauber, packagable, testbar)

Oder: flach unter `validation/…` (weniger standardkonform)

Wenn du schon Code hast: verschieben statt neu erfinden, aber Ziel ist nur ein Paketpfad.

Wie das zu deinem Build-Kontext passt

core/tree.py und core/rocm_env.py sind die “fehlenden” Teile:
Sie sorgen dafür, dass die Validierung gegen dein gebautes dist/ läuft (und nicht gegen System-ROCm).

doctor ist explizit no-download, genau wie du wolltest: erst “echte Tests” mit dem vorhandenen Build/Install-Layout.
