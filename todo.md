# TODO

## Architecture & Communication
- [ ] Pass/(check if) reports and progress context between agents.


## New Features
- [ ] Implement support for reading and resolving repository issues.
- [ ] Implement web search functionality. Must research on internet for this task.
- [ ] Add direct task execution CLI:
    - **Single task**:
      ```bash
      ./gralph.sh "add dark mode"
      ./gralph.sh "fix the auth bug"
      ```
    - **Task list**:
      ```bash
      ./gralph.sh              # defaults to PRD.md
      ./gralph.sh --prd tasks.md
      ```
