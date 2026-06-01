# general-scripts — Repo Context

A collection of independent scripts and deployable packages. Each project is
self-contained in its own subfolder.

## Layout

```
general-scripts/
├── README.md                  # repo index + "Adding a new project" guide
├── CLAUDE.md                  # this file — repo-wide conventions
├── _template/                 # starting point for new projects (not a real project)
│   └── README.md
└── <project-name>/            # one folder per project, with its own README
```

## Conventions

- **One folder per project.** Each project lives in its own subfolder with a
  self-contained README. Don't put project files at the repo root.
- **Folder names** are lowercase, hyphen-separated (e.g. `file-replication-monitoring`).
- **Every project has a README** following `_template/README.md`: description,
  files table, prerequisites, usage, verification, notes.
- **Keep the index current.** When adding a project, add a row to the **Index**
  table in the top-level `README.md` (folder link, one-line description, stack).
  A per-file table is encouraged when a project has several files.
- **`_template/` is not a project** — leave it in place; copy it to start new work.
- **Project-specific context** (locked design decisions, etc.) belongs in a
  `CLAUDE.md` inside that project's folder, not here. This file is repo-wide only.

## Adding a new project

1. `cp -r _template <project-name>`
2. Fill in `<project-name>/README.md` and add the scripts alongside it.
3. Add a row to the Index table in the top-level `README.md`.
