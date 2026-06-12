# Agent Guide

- Do not commit downloaded archives, ISO/WIM/ESD images, mount directories, or reports.
- Do not run the full ISO test locally unless the user explicitly requests it.
- Prefer PowerShell parsing and `actionlint` for lightweight validation.
- Keep registry inspection read-only. The workflow loads an offline hive under a temporary name and always unloads it in cleanup.
- Preserve support for direct ZIP URLs and GitHub Actions run/artifact URLs.
