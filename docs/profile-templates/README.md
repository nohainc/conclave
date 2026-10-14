# Canonical Worker Profile sources

The canonical source JSON files used by Profile Lab are bundled with the app:

- `apps/profile_lab/assets/profiles/chatgpt.json` — Codex CLI
- `apps/profile_lab/assets/profiles/gemini.json` — Antigravity `agy` CLI
- `apps/profile_lab/assets/profiles/claude.json` — Claude Code CLI

**One source file per logical Worker.** The file name is always `<workerTypeId>.json`, without release/version suffixes. Update these files when changing a source Profile, then rebuild Profile Lab to include the changed Flutter assets.

In Profile Lab, selecting a first-party Worker loads its bundled source file into the local candidate while keeping the current Cloud Profile available for comparison and revision tracking. **More → Load source Profile…** refreshes that candidate explicitly after confirmation. Loading source replaces the local candidate only; it never publishes or overwrites the current Cloud Profile. Test, validate and explicitly publish the candidate through the usual V9 flow.

The Cloud's current published Profile and historical revisions are runtime state, separate from the bundled editable source. Keep Cloud history and API revision metadata: removing source *filenames* with version suffixes does not remove required Profile schema/version fields. The source JSON was selected from the most recent corresponding profile **in this repository** at the time of consolidation, not fetched from production D1. Review current Cloud differences before publication.

Historical migrations and test fixtures are not authoritative source Profiles. They must not be used as the editor's default source.
