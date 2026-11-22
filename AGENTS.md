# SmartClean project coordination

Before changing user data, read the current effective policy through modules/Load.ps1 + Get-SCPolicy and inspect the relevant decision events. settings.json is not an approval. Do not infer repeat permissions from an old cleanup report or from a file named approved.

User-content changes in this project must use a concrete immutable plan and the shared Operations.ps1 executor, or an explicitly user-authorized app-specific migration with its own recorded plan, verification, and result. Observe the shared mutation lock. Do not run historical research cleanup scripts as a shortcut or re-execute imported completed operations.

Keep protection distinct from scan exclusions. Never delete a directory simply because it is named Cache/Temp. In particular, GoogleDrive/Cache may contain working applications and exports. Preserve application history, profiles, projects, cloud data, and the actual targets of existing junctions unless an exact current decision covers the change.

Read and write decisions through the registry; use expected-revision checks for policy writes and immutable event files for operation results. Do not silently overwrite another chat's policy changes. Record source evidence and distinguish proposed, approved, completed, verified, imported historical observations, and incomplete checks.

Do not perform real cleanup/migration to test this software. Use uniquely named fixtures under tests/features or tests/runs. Before removing generated fixtures, verify absolute target paths remain inside those exact test roots and never traverse junctions/symlinks.

No browser, WebView, Electron, or local web-server UI. WPF and CLI must share the same services. Long jobs run outside the WPF UI thread. Keep per-object checks, cancellation, collision refusal, source fingerprints, reference-copy verification, and quarantine/restore behavior.
