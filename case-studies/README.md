# case-studies/

Real-world integrations of `ai_debug` into substantial Flutter codebases. Each case study is a separate repo, included here as a git submodule.

| project | submodule repo | scope |
|---|---|---|
| [Immich](https://github.com/immich-app/immich) | [`immich_ai_debug_tools`](https://github.com/santoshakil/immich_ai_debug_tools) → [`immich/`](immich) | 22 dart files registering ~130 inspection commands across auth, sync, backup, drift, lifecycle, riverpod state. The same submodule is also mounted at `mobile/lib/utils/ai_debug/` inside an Immich fork — the `.dart` files become Immich source there, and the same content serves as case-study reference here. |

## adding a case study

1. Create a separate public repo with the integration's instrumentation code (typically the per-feature `AiDebug.register(...)` files specific to the target app).
2. Add it as a submodule under this directory: `git submodule add <repo-url> case-studies/<name>`.
3. Add a row to the table above.
4. Cross-reference from the case-study repo's README back here.

Case studies live in their own repos so they can be consumed two ways:
- Vendored into the target app (e.g., as `mobile/lib/utils/<name>_ai_debug/`) — the `.dart` files become source code there.
- Mounted here as documentation — same content, no impact on consumers.
