---
name: prd
description: "Generate a Product Requirements Document (PRD) for a new feature. Use when planning a feature, starting a new project, or when asked to create a PRD. The PRD should be detailed enough for execution by AI agents across tools (Amp, Cursor, Codex, etc.). Triggers on: create a prd, write prd for, plan this feature, requirements for, spec out."
---

# PRD Generator

Create detailed Product Requirements Documents that are clear, actionable, and suitable for implementation by AI agents (Amp, Cursor, Codex, etc.).

---

## The Job

1. Build repository context as needed to avoid ambiguity or conflicts
2. Receive a feature description from the user
3. Ask 3-5 essential clarifying questions (with lettered options)
4. Generate a structured PRD based on answers
5. Save to `tasks/prd-[feature-name].md`

**Important:** Do NOT start implementing. Just create the PRD.
**Required Output Detail:** The PRD must include a `prd-id: <kebab-case>` line directly under the `# PRD: ...` title. This is mandatory for `gralph.sh` to run.

---

## Step 0: Repository Context (As Needed)

Gather only the context required to remove ambiguity. Prefer targeted reading:

- Start with high-signal sources (README, docs, config, entry points)
- Scan for related features, data models, and modules that touch the request
- Identify conventions, constraints, and dependencies that affect scope

If the request is highly ambiguous or spans multiple subsystems, expand the review to more of the repo. Summarize findings in brief working notes before writing the PRD.

---

## Step 1: Clarifying Questions

Ask only critical questions where the initial prompt is ambiguous. Focus on:

- **Problem/Goal:** What problem does this solve?
- **Core Functionality:** What are the key actions?
- **Scope/Boundaries:** What should it NOT do?
- **Success Criteria:** How do we know it's done?
- **Constraints/Dependencies:** Any tech, data, or policy constraints?

### Format Questions Like This:

```
1. What is the primary goal of this feature?
   A. Improve user onboarding experience
   B. Increase user retention
   C. Reduce support burden
   D. Other: [please specify]

2. Who is the target user?
   A. New users only
   B. Existing users only
   C. All users
   D. Admin users only

3. What is the scope?
   A. Minimal viable version
   B. Full-featured implementation
   C. Just the backend/API
   D. Just the UI
```

This lets users respond with "1A, 2C, 3B" for quick iteration.

---

## Step 2: PRD Structure

Generate the PRD with these sections:

### 1. Introduction/Overview
Brief description of the feature and the problem it solves.

### 2. Goals
Specific, measurable objectives (bullet list).

### 3. User Stories
Each story needs:
- **Title:** Short descriptive name
- **Description:** "As a [user], I want [feature] so that [benefit]"
- **Task Definition:** A precise, detailed description of the work and expected outcome, written as a single cohesive task (no sub-tasks or step lists)
- **Acceptance Criteria:** Verifiable checklist of what "done" means

Each story should be small enough to implement in one focused session, but detailed enough that the task is unambiguous without needing sub-tasks.

**Format:**
```markdown
### US-001: [Title]
**Description:** As a [user], I want [feature] so that [benefit].

**Task Definition:** Describe the implementation in one detailed task: include the specific data changes, UI behavior, API expectations, and any constraints, but do not break into sub-tasks or steps.

**Acceptance Criteria:**
- [ ] Specific verifiable criterion
- [ ] Another criterion
- [ ] Typecheck/lint passes
- [ ] **[UI stories only]** Verify in browser using dev-browser skill
```

**Important:** 
- Acceptance criteria must be verifiable, not vague. "Works correctly" is bad. "Button shows confirmation dialog before deleting" is good.
- Task Definition must be a single, detailed task statement. Do not include sub-tasks or step-by-step lists.
- **For any story with UI changes:** Always include "Verify in browser using dev-browser skill" as acceptance criteria. This ensures visual verification of frontend work.

### 4. Functional Requirements
Numbered list of specific functionalities:
- "FR-1: The system must allow users to..."
- "FR-2: When a user clicks X, the system must..."

Be explicit and unambiguous.

### 5. Non-Goals (Out of Scope)
What this feature will NOT include. Critical for managing scope.

### 6. Design Considerations (Optional)
- UI/UX requirements
- Link to mockups if available
- Relevant existing components to reuse

### 7. Technical Considerations (Optional)
- Known constraints or dependencies
- Integration points with existing systems
- Performance requirements

### 8. Success Metrics
How will success be measured?
- "Reduce time to complete X by 50%"
- "Increase conversion rate by 10%"

### 9. Open Questions
Remaining questions or areas needing clarification.

### 10. Assumptions & Dependencies
List explicit assumptions and external dependencies (APIs, teams, data sources).

### 11. Risks & Mitigations
Call out likely risks (performance, security, UX, data quality) and mitigations.

### 12. Rollout & Monitoring (Optional)
- Rollout plan (feature flag, staged release, rollback)
- Analytics/telemetry needed to measure success

### 13. Privacy & Security (Optional)
Data handling, PII, access controls, and compliance notes.

---

## Writing for Junior Developers

The PRD reader may be a junior developer or AI agent. Therefore:

- Be explicit and unambiguous
- Avoid jargon or explain it
- Provide enough detail to understand purpose and core logic
- Number requirements for easy reference
- Use concrete examples where helpful
- Prefer tool-agnostic instructions; only mention specific tools when required

---

## Output

- **Format:** Markdown (`.md`)
- **Location:** `tasks/`
- **Filename:** `prd-[feature-name].md` (kebab-case)
- **Include (Required):** Add a line `prd-id: <feature-name-kebab-case>` immediately after the `# PRD: ...` title. If you invent the name, generate a kebab-case `prd-id` and keep it consistent with the filename.

---

## Example PRD

```markdown
# PRD: Task Priority System

prd-id: task-priority-system

## Introduction

Add priority levels to tasks so users can focus on what matters most. Tasks can be marked as high, medium, or low priority, with visual indicators and filtering to help users manage their workload effectively.

## Goals

- Allow assigning priority (high/medium/low) to any task
- Provide clear visual differentiation between priority levels
- Enable filtering and sorting by priority
- Default new tasks to medium priority

## User Stories

### US-001: Add priority field to database
**Description:** As a developer, I need to store task priority so it persists across sessions.

**Task Definition:** Add a `priority` field to the tasks data model with allowed values 'high' | 'medium' | 'low', default to 'medium', ensure it is persisted in storage, and update any necessary types or validation to accept and return the field consistently.

**Acceptance Criteria:**
- [ ] Add priority column to tasks table: 'high' | 'medium' | 'low' (default 'medium')
- [ ] Generate and run migration successfully
- [ ] Typecheck passes

### US-002: Display priority indicator on task cards
**Description:** As a user, I want to see task priority at a glance so I know what needs attention first.

**Task Definition:** Display a priority badge on each task card using the existing badge component, map colors to priority values (red/high, yellow/medium, gray/low), and ensure the badge is visible in the default card layout without additional interaction.

**Acceptance Criteria:**
- [ ] Each task card shows colored priority badge (red=high, yellow=medium, gray=low)
- [ ] Priority visible without hovering or clicking
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

### US-003: Add priority selector to task edit
**Description:** As a user, I want to change a task's priority when editing it.

**Task Definition:** Add a priority dropdown to the task edit modal that reflects the current value, persists changes immediately on selection, and updates the UI to the new priority without a full page refresh.

**Acceptance Criteria:**
- [ ] Priority dropdown in task edit modal
- [ ] Shows current priority as selected
- [ ] Saves immediately on selection change
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

### US-004: Filter tasks by priority
**Description:** As a user, I want to filter the task list to see only high-priority items when I'm focused.

**Task Definition:** Add a priority filter control to the task list header with options All | High | Medium | Low, persist the selection in URL params, and show a clear empty state when no tasks match the selected filter.

**Acceptance Criteria:**
- [ ] Filter dropdown with options: All | High | Medium | Low
- [ ] Filter persists in URL params
- [ ] Empty state message when no tasks match filter
- [ ] Typecheck passes
- [ ] Verify in browser using dev-browser skill

## Functional Requirements

- FR-1: Add `priority` field to tasks table ('high' | 'medium' | 'low', default 'medium')
- FR-2: Display colored priority badge on each task card
- FR-3: Include priority selector in task edit modal
- FR-4: Add priority filter dropdown to task list header
- FR-5: Sort by priority within each status column (high to medium to low)

## Non-Goals

- No priority-based notifications or reminders
- No automatic priority assignment based on due date
- No priority inheritance for subtasks

## Technical Considerations

- Reuse existing badge component with color variants
- Filter state managed via URL search params
- Priority stored in database, not computed

## Success Metrics

- Users can change priority in under 2 clicks
- High-priority tasks immediately visible at top of lists
- No regression in task list performance

## Open Questions

- Should priority affect task ordering within a column?
- Should we add keyboard shortcuts for priority changes?
```

---

## Checklist

Before saving the PRD:

- [ ] Asked clarifying questions with lettered options
- [ ] Incorporated user's answers
- [ ] User stories are small and specific
- [ ] Functional requirements are numbered and unambiguous
- [ ] Non-goals section defines clear boundaries
- [ ] `prd-id: <kebab-case>` present directly under the `# PRD:` title
- [ ] Saved to `tasks/prd-[feature-name].md`
