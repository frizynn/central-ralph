# PRD: GRALPH TODO Roadmap Implementation

prd-id: gralph-todo-implementation

## Introduction/Overview

Implement the complete roadmap in `todo.md` for GRALPH. This includes: passing progress/report context between agents, adding repository issue intake and resolution workflow, enabling web search context for tasks, and adding direct task execution from a single prompt or a task list file. The goal is a full-featured, clean, and reliable CLI workflow that minimizes manual setup and improves task success rates.

## Goals

- Enable end-to-end runs starting from a repository issue, with issue content converted into a PRD and tasks.
- Provide web search context to agents when enabled, with configurable providers and cached results.
- Share task reports and progress context between agents to reduce duplication and improve consistency.
- Allow direct CLI execution for a single task prompt and for a task list file.
- Keep changes clean, modular, and testable with clear error handling.

## User Stories

### US-001: Fetch repository issues into GRALPH
**Description:** As a maintainer, I want GRALPH to load issue data from the repository so I can start a run from an issue.

**Task Definition:** Add a GitHub issue resolver that accepts an issue number or issue URL, fetches issue metadata (title, body, labels, state, author, and URL) using `gh` when available or GitHub REST API when not, validates inputs, and writes a normalized JSON payload to `artifacts/prd/<prd-id>/issue.json` for downstream steps.

**Acceptance Criteria:**
- [ ] `--issue <number>` and `--issue <url>` are accepted and parsed correctly
- [ ] Issue metadata is fetched and normalized into `issue.json` in the run artifacts directory
- [ ] Missing credentials or network errors return clear, actionable errors
- [ ] Unit tests cover success and failure cases for issue resolution

### US-002: Generate PRD from issue content
**Description:** As a maintainer, I want a PRD auto-generated from an issue so GRALPH can proceed without manual PRD writing.

**Task Definition:** Add an "issue to PRD" prompt template and a CLI path that uses the issue JSON to generate `PRD.md` with a valid `prd-id` and a minimal but complete PRD structure, then uses the existing metadata agent flow to generate `tasks.yaml`.

**Acceptance Criteria:**
- [ ] `PRD.md` is generated with `prd-id` directly under the title
- [ ] Generated PRD includes the required sections from the PRD template
- [ ] `tasks.yaml` generation uses the new `PRD.md` without manual intervention
- [ ] Unit tests cover PRD generation path and validate `prd-id` presence

### US-003: Build a shared context pack from reports and progress
**Description:** As a maintainer, I want a summarized context pack so each agent can see prior task outcomes.

**Task Definition:** Implement a context pack builder that aggregates recent task reports and progress notes into a single file (e.g., `artifacts/prd/<prd-id>/context.md`), truncates to a configurable size, removes duplicate lines, and updates after each task completion.

**Acceptance Criteria:**
- [ ] A context pack file is created and updated after each task completes
- [ ] The context pack contains the latest report summary and progress notes
- [ ] Context size is capped (configurable) and deterministic
- [ ] Unit tests cover aggregation, truncation, and deduplication logic

### US-004: Inject shared context into agent prompts
**Description:** As a maintainer, I want agents to see shared context so they avoid conflicting work.

**Task Definition:** Update the task prompt assembly to append the context pack (if present and enabled by a flag) and add a short instruction that the agent should read it and avoid duplicating or contradicting previous task outcomes.

**Acceptance Criteria:**
- [ ] A new flag (e.g., `--share-context`) enables context injection
- [ ] Prompts include a context section when the pack exists and the flag is enabled
- [ ] When the pack is missing or empty, the prompt remains valid and readable
- [ ] Unit tests verify prompt assembly with and without context

### US-005: Add web search provider abstraction
**Description:** As a maintainer, I want configurable web search so agents can be given external context when needed.

**Task Definition:** Add a provider abstraction (environment-configured) and a `scripts/gralph/search.sh` helper that supports at least two providers (e.g., Brave and SerpAPI), accepts a query and max results, returns normalized JSON, and caches results under `artifacts/prd/<prd-id>/search/`.

**Acceptance Criteria:**
- [ ] `SEARCH_PROVIDER` and `SEARCH_API_KEY` (or equivalent) configure the provider
- [ ] Search results are normalized and cached in the run artifacts directory
- [ ] Missing API key or provider misconfiguration returns a clear error
- [ ] Unit tests cover provider selection, caching, and error handling

### US-006: Include web search context in task prompts
**Description:** As a maintainer, I want search results summarized and attached to each task to improve task accuracy.

**Task Definition:** When `--web-search` is enabled, generate a query from the task title and PRD context, run the search helper, summarize the top results into a short context block, and append it to the task prompt with source titles and URLs (if available).

**Acceptance Criteria:**
- [ ] Web search runs only when `--web-search` is enabled
- [ ] Each task prompt includes a summarized web search context block
- [ ] Search failures do not block task execution (graceful fallback)
- [ ] Unit tests cover query generation and prompt injection

### US-007: Direct single-task execution CLI
**Description:** As a user, I want to run GRALPH with a single task string without creating a PRD manually.

**Task Definition:** Add a CLI mode that accepts a quoted task string (positional argument), generates a minimal PRD and a single-task `tasks.yaml`, assigns a `prd-id` derived from the task text, and runs the standard pipeline with artifacts stored under `artifacts/prd/<prd-id>/`.

**Acceptance Criteria:**
- [ ] `./scripts/gralph/gralph.sh "fix auth bug"` runs end-to-end without a PRD file
- [ ] The generated `PRD.md` includes a valid `prd-id`
- [ ] The generated `tasks.yaml` contains exactly one task with the given title
- [ ] Unit tests cover argument parsing and artifact generation

### US-008: Direct task list execution from a file
**Description:** As a user, I want to run GRALPH from a simple task list file.

**Task Definition:** Accept a task list file (e.g., `--prd tasks.md`) that does not contain `prd-id:` and treat each non-empty line (or markdown bullet) as a task title; generate a PRD and `tasks.yaml` from those tasks and run the standard pipeline.

**Acceptance Criteria:**
- [ ] A task list file without `prd-id:` is detected and parsed into task titles
- [ ] Generated `tasks.yaml` includes one task per parsed title
- [ ] The generated PRD is stored in the artifacts directory and used for the run
- [ ] Unit tests cover task list parsing and fallbacks

### US-009: Documentation and tests for new CLI modes
**Description:** As a user, I want clear docs and test coverage for the new features.

**Task Definition:** Update `README.md` and CLI help text to document `--issue`, `--web-search`, `--share-context`, and direct-task modes, and add tests to cover the new flows and error handling.

**Acceptance Criteria:**
- [ ] README documents new flags and usage examples
- [ ] CLI `--help` output includes the new modes
- [ ] Tests cover new execution paths and failure cases
- [ ] Test suite passes

## Functional Requirements

- FR-1: The system must resolve GitHub issues by number or URL and store normalized issue data in artifacts.
- FR-2: The system must generate a PRD from issue content and produce `tasks.yaml` without manual edits.
- FR-3: The system must build and maintain a shared context pack from reports and progress notes.
- FR-4: The system must inject the shared context pack into agent prompts when enabled.
- FR-5: The system must provide configurable web search with cached, normalized results.
- FR-6: The system must summarize search results and append them to task prompts when enabled.
- FR-7: The system must support single-task runs from a positional CLI string.
- FR-8: The system must support task list files that do not contain `prd-id:` by generating a PRD and `tasks.yaml`.
- FR-9: The system must provide clear CLI help, documentation updates, and tests for all new features.

## Non-Goals (Out of Scope)

- Support for non-GitHub issue trackers (GitLab, Jira, Linear) in this iteration
- Automatic issue closing or comment updates after task completion
- Interactive UI or web dashboard
- Long-running background search indexing or crawling

## Design Considerations (Optional)

- Prefer new helper scripts under `scripts/gralph/` to keep `gralph.sh` readable.
- Keep CLI flags consistent with existing naming patterns and `--help` formatting.
- Store all generated artifacts inside `artifacts/prd/<prd-id>/` to preserve isolation.

## Technical Considerations (Optional)

- Use `gh` for issue retrieval when available; fall back to GitHub REST API if not.
- Add provider configuration via environment variables to avoid storing secrets in files.
- Implement caching for web search results to reduce API usage and speed retries.
- Truncate context and search summaries to avoid prompt bloat.
- Follow existing error handling patterns (clear messages, context in logs).

## Success Metrics

- A full run can be started from an issue in under 1 minute of manual setup.
- Direct single-task mode completes successfully with no manual PRD edits.
- At least 80% of tasks include helpful context from prior work or search.
- No regressions in existing scheduler tests or DAG validation.

## Open Questions

- Which web search provider should be the default (Brave vs SerpAPI)?
- What is the exact parsing format for `tasks.md` (bullets only, or any non-empty line)?
- Should `--issue` also accept a search query (e.g., most recent open issue)?

## Assumptions & Dependencies

- Network access is available when `--web-search` or `--issue` is used.
- Users can provide API keys or tokens through environment variables.
- `jq` and `yq` are installed (existing dependency).

## Risks & Mitigations

- **Prompt bloat from context/search results:** cap size and summarize deterministically.
- **Rate limits or API outages:** cache results and fail gracefully without blocking tasks.
- **Prompt injection via web content:** sanitize summaries and avoid direct instruction use.
- **Issue body quality varies:** include a validation step and allow manual override via PRD file.

## Rollout & Monitoring (Optional)

- Add feature flags: `--issue`, `--web-search`, and `--share-context`.
- Log search provider usage and cache hits in verbose mode.
- Keep a rollback path by disabling flags and using the existing PRD flow.

## Privacy & Security (Optional)

- Never write API keys to disk.
- Redact tokens and secrets from logs and reports.
- Limit stored web search data to titles, snippets, and URLs only.
