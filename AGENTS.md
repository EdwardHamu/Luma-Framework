# AGENTS.md

## GBFR packaging

- Changes must be committed before running the script; `git push` cannot publish uncommitted changes.
- Keep `Source/External/reshade` on the publicly reachable `v6.8.0` commit `18deaa52de0c425a78b329e9cb3c497281cd00ec` unless a fork containing the custom ReShade commit is configured. The local-only commit `160467c2540531bc3905bce67b3608f4e11493d3` cannot be fetched by Actions.
- The GBFR workflow must use the `windows-2025-vs2026` runner because the projects require `PlatformToolset=v145`. The ReShade MSBuild step must also pass `/p:PlatformToolset=v145`.
