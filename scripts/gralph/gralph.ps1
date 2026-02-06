#!/usr/bin/env pwsh
# ============================================
# GRALPH - Autonomous AI Coding Loop (PowerShell)
# Supports Claude Code, OpenCode, Codex, and Cursor
# Runs until PRD is complete
# ============================================

$ErrorActionPreference = "Stop"

# ============================================
# CONFIGURATION & DEFAULTS
# ============================================

$script:VERSION = "3.2.0"

# Runtime options
$script:SKIP_TESTS = $false
$script:SKIP_LINT = $false
$script:AI_ENGINE = "claude"  # claude, opencode, cursor, or codex
$script:OPENCODE_MODEL = "opencode/minimax-m2.1-free"
$script:DRY_RUN = $false
$script:MAX_ITERATIONS = 0
$script:MAX_RETRIES = 3
$script:RETRY_DELAY = 5
$script:VERBOSE = $false
$script:EXTERNAL_FAIL_TIMEOUT = 300

# Git branch options
$script:BRANCH_PER_TASK = $false
$script:CREATE_PR = $false
$script:BASE_BRANCH = ""
$script:PR_DRAFT = $false
$script:RUN_BRANCH = ""

# Parallel execution (default: parallel)
$script:PARALLEL = $true
$script:SEQUENTIAL = $false
$script:MAX_PARALLEL = 3

# PRD options
$script:PRD_FILE = "PRD.md"
$script:PRD_ID = ""
$script:PRD_RUN_DIR = ""
$script:RESUME_PRD_ID = ""

# Skills init options
$script:SKILLS_INIT = $false
$script:SKILLS_BASE_URL = $env:GRALPH_SKILLS_BASE_URL
if (-not $script:SKILLS_BASE_URL) { $script:SKILLS_BASE_URL = $env:RALPH_SKILLS_BASE_URL }
if (-not $script:SKILLS_BASE_URL) { $script:SKILLS_BASE_URL = "https://raw.githubusercontent.com/frizynn/central-ralph/main/skills" }

# Colors (detect if terminal supports)
# Use [char]27 for ESC to support both PS 5.x and PS 7+
$script:ESC = [char]27
$script:RED = ""
$script:GREEN = ""
$script:YELLOW = ""
$script:BLUE = ""
$script:MAGENTA = ""
$script:CYAN = ""
$script:BOLD = ""
$script:DIM = ""
$script:RESET = ""
$script:_supportsColor = $false
if ($PSVersionTable.PSVersion.Major -ge 7) {
  if ($Host.UI -and $Host.UI.SupportsVirtualTerminal) { $script:_supportsColor = $true }
} else {
  # PS 5.x: check if running in Windows Terminal or ConEmu (support ANSI)
  if ($env:WT_SESSION -or $env:ConEmuPID -or $env:TERM_PROGRAM) { $script:_supportsColor = $true }
}
if ($script:_supportsColor) {
  $script:RED = "$($script:ESC)[31m"
  $script:GREEN = "$($script:ESC)[32m"
  $script:YELLOW = "$($script:ESC)[33m"
  $script:BLUE = "$($script:ESC)[34m"
  $script:MAGENTA = "$($script:ESC)[35m"
  $script:CYAN = "$($script:ESC)[36m"
  $script:BOLD = "$($script:ESC)[1m"
  $script:DIM = "$($script:ESC)[2m"
  $script:RESET = "$($script:ESC)[0m"
}

# Global state
$script:ai_pid = $null
$script:monitor_pid = $null
$script:tmpfile = ""
$script:CODEX_LAST_MESSAGE_FILE = ""
$script:current_step = "Thinking"
$script:total_input_tokens = 0
$script:total_output_tokens = 0
$script:total_actual_cost = "0"
$script:total_duration_ms = 0
$script:iteration = 0
$script:retry_count = 0
$script:parallel_pids = @()
$script:task_branches = @()
$script:WORKTREE_BASE = ""
$script:ORIGINAL_DIR = ""
$script:EXTERNAL_FAIL_DETECTED = $false
$script:EXTERNAL_FAIL_REASON = ""
$script:EXTERNAL_FAIL_TASK_ID = ""
$script:ACTIVE_PIDS = @()
$script:ACTIVE_TASK_IDS = @()
$script:ACTIVE_STATUS_FILES = @()
$script:ACTIVE_LOG_FILES = @()

# ============================================
# UTILITY FUNCTIONS
# ============================================

function Log-Info { param([string]$Message) Write-Host "${script:BLUE}[INFO]${script:RESET} $Message" }
function Log-Success { param([string]$Message) Write-Host "${script:GREEN}[OK]${script:RESET} $Message" }
function Log-Warn { param([string]$Message) Write-Host "${script:YELLOW}[WARN]${script:RESET} $Message" }
function Log-Error { param([string]$Message) Write-Host "${script:RED}[ERROR]${script:RESET} $Message" }
function Log-Debug { param([string]$Message) if ($script:VERBOSE) { Write-Host "${script:DIM}[DEBUG] $Message${script:RESET}" } }

function Slugify {
  param([string]$Text)
  $slug = $Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-' -replace '(^-|-$)', ''
  if ($slug.Length -gt 50) { $slug = $slug.Substring(0, 50) }
  return $slug
}

function Extract-PrdId {
  param([string]$PrdFile)
  if (-not (Test-Path $PrdFile)) { return "" }
  $line = Get-Content $PrdFile | Where-Object { $_ -match '^prd-id:' } | Select-Object -First 1
  if (-not $line) { return "" }
  return ($line -replace '^prd-id:\s*', '').Trim()
}

function Setup-PrdRunDir {
  param([string]$PrdId)
  $script:PRD_RUN_DIR = "artifacts/prd/$PrdId"
  New-Item -ItemType Directory -Force -Path "$script:PRD_RUN_DIR/reports" | Out-Null
  $script:ARTIFACTS_DIR = $script:PRD_RUN_DIR
}

function Json-Escape {
  param([string]$Text)
  if ($null -eq $Text) { return "" }
  $escaped = $Text -replace '\\', '\\\\' -replace '"', '\"' -replace "`t", '\t'
  $escaped = $escaped -replace "(`r|`n)", ''
  return $escaped
}

function Normalize-YqScalar {
  param([string]$Value)
  if ($null -eq $Value) { return "" }
  $normalized = ($Value -replace "`r", "").Trim()
  if ($normalized -eq "null") { return "" }
  return $normalized
}

function Resolve-RepoRoot {
  $root = & git rev-parse --show-toplevel 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $root) { return (Get-Location).Path }
  return $root.Trim()
}

function Ensure-ParentDirWritable {
  param([string]$FilePath)
  $dirPath = Split-Path -Parent $FilePath
  try {
    New-Item -ItemType Directory -Force -Path $dirPath | Out-Null
    $testFile = Join-Path $dirPath ([IO.Path]::GetRandomFileName())
    New-Item -ItemType File -Path $testFile -Force | Out-Null
    Remove-Item $testFile -Force
    return $true
  } catch {
    return $false
  }
}

function Extract-ErrorFromLog {
  param([string]$LogFile)
  if (-not (Test-Path $LogFile)) { return "" }
  $lines = Get-Content $LogFile
  if (-not $lines) { return "" }
  $nonDebug = $lines | Where-Object { $_ -notmatch '^\[DEBUG\]' }
  if ($nonDebug) { return $nonDebug[-1] }
  return $lines[-1]
}

function Is-ExternalFailureError {
  param([string]$Message)
  if (-not $Message) { return $false }
  $lower = $Message.ToLowerInvariant()
  return ($lower -match 'buninstallfailederror|command not found|enoent|eacces|permission denied|network|timeout|tls|econnreset|etimedout|lockfile|install|certificate|ssl')
}

function Persist-TaskLog {
  param([string]$TaskId, [string]$LogFile)
  if (-not $script:ARTIFACTS_DIR) { return }
  $reportsDir = Join-Path $script:ORIGINAL_DIR $script:ARTIFACTS_DIR "reports"
  New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null
  if (Test-Path $LogFile -PathType Leaf) {
    Copy-Item $LogFile -Destination (Join-Path $reportsDir "$TaskId.log") -Force -ErrorAction SilentlyContinue
  }
}

function Write-FailedTaskReport {
  param(
    [string]$TaskId,
    [string]$TaskTitle,
    [string]$ErrorMsg,
    [string]$FailureType,
    [string]$Branch
  )
  if (-not $script:ARTIFACTS_DIR) { return }
  $reportsDir = Join-Path $script:ORIGINAL_DIR $script:ARTIFACTS_DIR "reports"
  New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null
  $safeTitle = Json-Escape $TaskTitle
  $safeError = Json-Escape $ErrorMsg
  $safeBranch = Json-Escape $Branch
  $json = @"
{
  "taskId": "$TaskId",
  "title": "$safeTitle",
  "branch": "$safeBranch",
  "status": "failed",
  "failureType": "$FailureType",
  "errorMessage": "$safeError",
  "commits": 0,
  "changedFiles": "",
  "timestamp": "$(Get-Date -AsUTC -Format yyyy-MM-ddTHH:mm:ssZ)"
}
"@
  $json | Set-Content -Path (Join-Path $reportsDir "$TaskId.json")
}

function Print-BlockedTasks {
  Write-Host ""
  Write-Host "${script:RED}Blocked tasks:${script:RESET}"
  foreach ($id in $script:SCHED_STATE.Keys) {
    if ($script:SCHED_STATE[$id] -eq "pending") {
      $reason = Scheduler-ExplainBlock $id
      Write-Host "  ${id}: $reason"
    }
  }
}

function External-FailGracefulStop {
  param([int]$Timeout = 300)
  $deadline = (Get-Date).AddSeconds($Timeout)
  while ((Scheduler-CountRunning) -gt 0 -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
  }
  if ((Scheduler-CountRunning) -gt 0) {
    Log-Warn "External failure timeout reached; terminating remaining tasks."
    foreach ($pid in $script:ACTIVE_PIDS) {
      try { Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue } catch { }
    }
    Start-Sleep -Seconds 2
    foreach ($idx in 0..($script:ACTIVE_PIDS.Count - 1)) {
      $taskId = $script:ACTIVE_TASK_IDS[$idx]
      if ($taskId) {
        Scheduler-FailTask $taskId
        $taskTitle = Get-TaskTitleByIdYamlV1 $taskId
        Write-FailedTaskReport $taskId $taskTitle "external-timeout" "external" ""
      }
      $statusFile = $script:ACTIVE_STATUS_FILES[$idx]
      if ($statusFile) { "failed" | Set-Content -Path $statusFile -ErrorAction SilentlyContinue }
      $logFile = $script:ACTIVE_LOG_FILES[$idx]
      if ($logFile) { Persist-TaskLog $taskId $logFile }
    }
  }
}

# Return candidate skill files to check for existence
function Get-SkillFileCandidates {
  param([string]$Engine, [string]$Skill)
  $repoRoot = Resolve-RepoRoot
  switch ($Engine) {
    "claude" {
      @(
        (Join-Path $repoRoot ".claude/skills/$Skill/SKILL.md"),
        (Join-Path $HOME ".claude/skills/$Skill/SKILL.md")
      )
    }
    "codex" {
      @(
        (Join-Path $repoRoot ".codex/skills/$Skill/SKILL.md"),
        (Join-Path $HOME ".codex/skills/$Skill/SKILL.md")
      )
    }
    "opencode" {
      @(
        (Join-Path $repoRoot ".opencode/skill/$Skill/SKILL.md"),
        (Join-Path $HOME ".config/opencode/skill/$Skill/SKILL.md")
      )
    }
    "cursor" {
      @(
        (Join-Path $repoRoot ".cursor/rules/$Skill.mdc"),
        (Join-Path $repoRoot ".cursor/commands/$Skill.md")
      )
    }
  }
}

function Get-SkillInstallTarget {
  param([string]$Engine, [string]$Skill)
  $repoRoot = Resolve-RepoRoot
  $projectTarget = ""
  $userTarget = ""
  switch ($Engine) {
    "claude" {
      $projectTarget = Join-Path $repoRoot ".claude/skills/$Skill/SKILL.md"
      $userTarget = Join-Path $HOME ".claude/skills/$Skill/SKILL.md"
    }
    "codex" {
      $projectTarget = Join-Path $repoRoot ".codex/skills/$Skill/SKILL.md"
      $userTarget = Join-Path $HOME ".codex/skills/$Skill/SKILL.md"
    }
    "opencode" {
      $projectTarget = Join-Path $repoRoot ".opencode/skill/$Skill/SKILL.md"
      $userTarget = Join-Path $HOME ".config/opencode/skill/$Skill/SKILL.md"
    }
    "cursor" {
      $projectTarget = Join-Path $repoRoot ".cursor/rules/$Skill.mdc"
    }
  }
  if ($projectTarget -and (Ensure-ParentDirWritable $projectTarget)) { return $projectTarget }
  if ($userTarget -and (Ensure-ParentDirWritable $userTarget)) { return $userTarget }
  return ""
}

function Skill-Exists {
  param([string]$Engine, [string]$Skill)
  foreach ($candidate in (Get-SkillFileCandidates $Engine $Skill)) {
    if ($candidate -and (Test-Path $candidate)) { return $true }
  }
  return $false
}

function Download-SkillContent {
  param([string]$Skill)
  $baseUrl = $script:SKILLS_BASE_URL.TrimEnd('/')
  $url = "$baseUrl/$Skill/SKILL.md"
  $tmpfile = [IO.Path]::GetTempFileName()
  $repoRoot = Resolve-RepoRoot
  $localSkillPath = Join-Path $repoRoot "skills/$Skill/SKILL.md"
  try {
    Invoke-WebRequest -Uri $url -OutFile $tmpfile -UseBasicParsing | Out-Null
    return $tmpfile
  } catch {
    if (Test-Path $localSkillPath) {
      Copy-Item $localSkillPath $tmpfile -Force
      Log-Warn "Falling back to local skill source for '$Skill'"
      return $tmpfile
    }
    return ""
  }
}

function Install-SkillIfMissing {
  param([string]$Engine, [string]$Skill)
  if (Skill-Exists $Engine $Skill) {
    Log-Info "Skill '$Skill' already installed for $Engine, skipping"
    return $true
  }
  $target = Get-SkillInstallTarget $Engine $Skill
  if (-not $target) {
    Log-Warn "No writable install path for $Engine skill '$Skill'"
    return $false
  }
  $tmpfile = Download-SkillContent $Skill
  if (-not $tmpfile) {
    Log-Error "Failed to download skill '$Skill' from $($script:SKILLS_BASE_URL)"
    return $false
  }
  try {
    Move-Item $tmpfile $target -Force
    Log-Success "Installed '$Skill' for $Engine at $target"
    return $true
  } catch {
    Log-Error "Failed to install '$Skill' for $Engine at $target"
    return $false
  }
}

function Ensure-SkillsForEngine {
  param([string]$Engine, [string]$Mode)
  $skills = @("prd","ralph","task-metadata","dag-planner","parallel-safe-implementation","merge-integrator","semantic-reviewer")
  $missing = $false
  if ($Engine -eq "cursor") { Log-Warn "Cursor skills are not officially supported; installing as rules is best-effort." }
  foreach ($skill in $skills) {
    if (Skill-Exists $Engine $skill) {
      Log-Info "Skill '$skill' found for $Engine"
      continue
    }
    $missing = $true
    if ($Mode -eq "install") {
      Install-SkillIfMissing $Engine $skill | Out-Null
    } else {
      Log-Warn "Missing skill '$skill' for $Engine (run --init to install)"
    }
  }
  if ($Mode -eq "install" -and -not $missing) { Log-Success "All skills already present for $Engine" }
}

# ============================================
# HELP & VERSION
# ============================================

function Show-Help {
  Write-Host @"
${script:BOLD}GRALPH${script:RESET} - Autonomous AI Coding Loop (v$($script:VERSION))

${script:BOLD}USAGE:${script:RESET}
  ./scripts/gralph/gralph.ps1 [options]

${script:BOLD}AI ENGINE OPTIONS:${script:RESET}
  --claude            Use Claude Code (default)
  --opencode          Use OpenCode
  --opencode-model M  OpenCode model to use (e.g., "openai/gpt-4o", "anthropic/claude-sonnet-4-5")
  --cursor            Use Cursor agent
  --codex             Use Codex CLI

${script:BOLD}WORKFLOW OPTIONS:${script:RESET}
  --no-tests          Skip writing and running tests
  --no-lint           Skip linting
  --fast              Skip both tests and linting

${script:BOLD}EXECUTION OPTIONS:${script:RESET}
  --sequential        Run tasks one at a time (default: parallel)
  --max-parallel N    Max concurrent tasks (default: 3)
  --max-iterations N  Stop after N iterations (0 = unlimited)
  --max-retries N     Max retries per task on failure (default: 3)
  --retry-delay N     Seconds between retries (default: 5)
  --external-fail-timeout N  Seconds to wait for running tasks on external failure (default: 300)
  --dry-run           Show what would be done without executing

${script:BOLD}GIT BRANCH OPTIONS:${script:RESET}
  --branch-per-task   Create a new git branch for each task
  --base-branch NAME  Base branch to create task branches from (default: current)
  --create-pr         Create a pull request after each task (requires gh CLI)
  --draft-pr          Create PRs as drafts

${script:BOLD}PRD OPTIONS:${script:RESET}
  --prd FILE          PRD file path (default: PRD.md)
  --resume PRD-ID     Resume a previous run by prd-id

${script:BOLD}OTHER OPTIONS:${script:RESET}
  --init              Install missing skills for the current AI engine and exit
  --update            Update gralph to the latest version
  --skills-url URL    Override skills base URL (default: GitHub raw)
  -v, --verbose       Show debug output
  -h, --help          Show this help
  --show-help         Show this help (safe for powershell.exe -File)
  --version           Show version number
  --show-version      Show version number (safe for powershell.exe -File)

${script:BOLD}EXAMPLES:${script:RESET}
  ./scripts/gralph/gralph.ps1 --opencode             # Run with OpenCode (parallel by default)
  ./scripts/gralph/gralph.ps1 --opencode --sequential  # Run sequentially
  ./scripts/gralph/gralph.ps1 --opencode --max-parallel 4  # Run 4 tasks concurrently
  ./scripts/gralph/gralph.ps1 --resume my-feature    # Resume previous run

${script:BOLD}WORKFLOW:${script:RESET}
  1. Create PRD.md with prd-id line (use /prd skill)
  2. Run gralph: ./scripts/gralph/gralph.ps1 --opencode
  3. GRALPH creates artifacts/prd/<prd-id>/ with tasks.yaml
  4. Tasks run in parallel using DAG scheduler
  5. Resume anytime with --resume <prd-id>

${script:BOLD}PRD FORMAT:${script:RESET}
  PRD.md must include a prd-id line:
    prd-id: my-feature-name

  GRALPH generates tasks.yaml automatically from PRD.md
"@
}

function Show-Version {
  Write-Host "GRALPH v$($script:VERSION)"
}

# ============================================
# ARGUMENT PARSING
# ============================================

function Parse-Args {
  param([string[]]$Arguments)
  for ($i = 0; $i -lt $Arguments.Count; $i++) {
    $arg = $Arguments[$i]
    switch ($arg) {
      "--no-tests" { $script:SKIP_TESTS = $true }
      "--skip-tests" { $script:SKIP_TESTS = $true }
      "--no-lint" { $script:SKIP_LINT = $true }
      "--skip-lint" { $script:SKIP_LINT = $true }
      "--fast" { $script:SKIP_TESTS = $true; $script:SKIP_LINT = $true }
      "--opencode" { $script:AI_ENGINE = "opencode" }
      "--opencode-model" {
        if (-not $Arguments[$i + 1]) { Log-Error "--opencode-model requires a model name"; exit 1 }
        $script:OPENCODE_MODEL = $Arguments[$i + 1]; $i++
      }
      "--claude" { $script:AI_ENGINE = "claude" }
      "--cursor" { $script:AI_ENGINE = "cursor" }
      "--agent" { $script:AI_ENGINE = "cursor" }
      "--codex" { $script:AI_ENGINE = "codex" }
      "--dry-run" { $script:DRY_RUN = $true }
      "--init" { $script:SKILLS_INIT = $true }
      "--skills-url" {
        $script:SKILLS_BASE_URL = $Arguments[$i + 1]
        $i++
      }
      "--max-iterations" { $script:MAX_ITERATIONS = [int]$Arguments[$i + 1]; $i++ }
      "--max-retries" { $script:MAX_RETRIES = [int]$Arguments[$i + 1]; $i++ }
      "--retry-delay" { $script:RETRY_DELAY = [int]$Arguments[$i + 1]; $i++ }
      "--external-fail-timeout" { $script:EXTERNAL_FAIL_TIMEOUT = [int]$Arguments[$i + 1]; $i++ }
      "--parallel" { $script:PARALLEL = $true; $script:SEQUENTIAL = $false }
      "--sequential" { $script:SEQUENTIAL = $true; $script:PARALLEL = $false }
      "--max-parallel" { $script:MAX_PARALLEL = [int]$Arguments[$i + 1]; $i++ }
      "--branch-per-task" { $script:BRANCH_PER_TASK = $true }
      "--base-branch" { $script:BASE_BRANCH = $Arguments[$i + 1]; $i++ }
      "--create-pr" { $script:CREATE_PR = $true }
      "--draft-pr" { $script:PR_DRAFT = $true }
      "--prd" { $script:PRD_FILE = $Arguments[$i + 1]; $i++ }
      "--resume" {
        $script:RESUME_PRD_ID = $Arguments[$i + 1]
        if (-not $script:RESUME_PRD_ID) { Log-Error "--resume requires a prd-id"; exit 1 }
        $i++
      }
      "-v" { $script:VERBOSE = $true }
      "--verbose" { $script:VERBOSE = $true }
      "--update" { Self-Update; exit 0 }
      "-h" { Show-Help; exit 0 }
      "--help" { Show-Help; exit 0 }
      "-help" { Show-Help; exit 0 }
      "--show-help" { Show-Help; exit 0 }
      "-show-help" { Show-Help; exit 0 }
      "--version" { Show-Version; exit 0 }
      "-version" { Show-Version; exit 0 }
      "--show-version" { Show-Version; exit 0 }
      "-show-version" { Show-Version; exit 0 }
      default {
        Log-Error "Unknown option: $arg"
        Write-Host "Use --help for usage"
        exit 1
      }
    }
  }
}

# ============================================
# PRE-FLIGHT CHECKS
# ============================================

function Check-Requirements {
  $missingRequired = @()
  if (-not (Get-Command yq -ErrorAction SilentlyContinue)) {
    $missingRequired += "yq (https://github.com/mikefarah/yq)"
  }
  if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
    $missingRequired += "jq (https://jqlang.github.io/jq/download/)"
  }
  if ($missingRequired.Count -gt 0) {
    Log-Warn "Missing required dependencies: $($missingRequired -join ', ')"
    Log-Error "Install required dependencies and re-run."
    exit 1
  }

  if ($script:RESUME_PRD_ID) {
    $script:PRD_ID = $script:RESUME_PRD_ID
    $script:PRD_RUN_DIR = "artifacts/prd/$($script:PRD_ID)"
    if (-not (Test-Path $script:PRD_RUN_DIR)) {
      Log-Error "No run found for prd-id: $($script:PRD_ID)"
      exit 1
    }
    if (-not (Test-Path (Join-Path $script:PRD_RUN_DIR "tasks.yaml"))) {
      Log-Error "No tasks.yaml found in $($script:PRD_RUN_DIR)"
      exit 1
    }
    $script:PRD_FILE = Join-Path $script:PRD_RUN_DIR "tasks.yaml"
    $script:ARTIFACTS_DIR = $script:PRD_RUN_DIR
    Log-Info "Resuming PRD: $($script:PRD_ID)"
  } else {
    if (-not (Test-Path $script:PRD_FILE)) {
      $root = Resolve-RepoRoot
      Push-Location $root
      try {
        $found = Find-PrdFile
        if ($found) {
          if ($found -is [System.IO.FileInfo]) { $script:PRD_FILE = $found.FullName }
          else { $script:PRD_FILE = (Resolve-Path $found).Path }
        }
      } finally { Pop-Location }
      if (-not (Test-Path $script:PRD_FILE)) {
        Log-Error "PRD.md not found"
        exit 1
      }
    }
    $script:PRD_ID = Extract-PrdId $script:PRD_FILE
    if (-not $script:PRD_ID) {
      Log-Error "PRD missing prd-id. Add 'prd-id: your-id' to the PRD file."
      exit 1
    }
    Setup-PrdRunDir $script:PRD_ID
    Copy-Item $script:PRD_FILE (Join-Path $script:PRD_RUN_DIR "PRD.md") -Force
    if (Test-Path (Join-Path $script:PRD_RUN_DIR "tasks.yaml")) {
      Log-Info "Resuming existing run for $($script:PRD_ID)"
    } else {
      Log-Info "Generating tasks.yaml for $($script:PRD_ID)..."
      if (-not (Run-MetadataAgent (Join-Path $script:PRD_RUN_DIR "PRD.md") (Join-Path $script:PRD_RUN_DIR "tasks.yaml"))) {
        Log-Error "Failed to generate tasks.yaml"
        exit 1
      }
    }
    $script:PRD_FILE = Join-Path $script:PRD_RUN_DIR "tasks.yaml"
  }

  if (-not (Validate-TasksYamlV1)) { exit 1 }

  switch ($script:AI_ENGINE) {
    "opencode" {
      if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
        Log-Error "OpenCode CLI not found. Install from https://opencode.ai/docs/"
        exit 1
      }
    }
    "codex" {
      if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
        Log-Error "Codex CLI not found. Make sure 'codex' is in your PATH."
        exit 1
      }
    }
    "cursor" {
      if (-not (Get-Command agent -ErrorAction SilentlyContinue)) {
        Log-Error "Cursor agent CLI not found. Make sure Cursor is installed and 'agent' is in your PATH."
        exit 1
      }
    }
    default {
      if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Log-Error "Claude Code CLI not found. Install from https://github.com/anthropics/claude-code"
        exit 1
      }
    }
  }

  if ($script:CREATE_PR -and -not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Log-Error "GitHub CLI (gh) is required for --create-pr. Install from https://cli.github.com/"
    exit 1
  }

  if (-not (Test-Path "scripts/gralph/progress.txt")) {
    Log-Warn "progress.txt not found, creating it..."
    New-Item -ItemType File -Force -Path "scripts/gralph/progress.txt" | Out-Null
  }

  if ($script:BRANCH_PER_TASK -and -not $script:BASE_BRANCH) {
    $script:BASE_BRANCH = (& git rev-parse --abbrev-ref HEAD 2>$null) -join ""
    if (-not $script:BASE_BRANCH) { $script:BASE_BRANCH = "main" }
    Log-Debug "Using base branch: $($script:BASE_BRANCH)"
  }
}

# ============================================
# CLEANUP HANDLER
# ============================================

function Cleanup {
  # Kill background processes
  if ($script:monitor_pid) { try { Stop-Process -Id $script:monitor_pid -Force -ErrorAction SilentlyContinue } catch { } }
  if ($script:ai_pid) { try { Stop-Process -Id $script:ai_pid -Force -ErrorAction SilentlyContinue } catch { } }
  foreach ($pid in $script:parallel_pids) {
    try { Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue } catch { }
  }
  if ($script:tmpfile -and (Test-Path $script:tmpfile)) { Remove-Item $script:tmpfile -Force }
  if ($script:CODEX_LAST_MESSAGE_FILE -and (Test-Path $script:CODEX_LAST_MESSAGE_FILE)) { Remove-Item $script:CODEX_LAST_MESSAGE_FILE -Force }
  if ($script:WORKTREE_BASE -and (Test-Path $script:WORKTREE_BASE)) {
    Get-ChildItem -Path $script:WORKTREE_BASE -Directory -Filter "agent-*" | ForEach-Object {
      $dir = $_.FullName
      $status = & git -C $dir status --porcelain 2>$null
      if ($status) {
        Log-Warn "Preserving dirty worktree: $dir"
        return
      }
      & git worktree remove $dir 2>$null | Out-Null
    }
    $remaining = Get-ChildItem -Path $script:WORKTREE_BASE -Directory -Filter "agent-*" -ErrorAction SilentlyContinue
    if (-not $remaining) { Remove-Item $script:WORKTREE_BASE -Force -Recurse -ErrorAction SilentlyContinue }
    else { Log-Warn "Preserving worktree base with dirty agents: $($script:WORKTREE_BASE)" }
  }
}

# ============================================
# TASK SOURCES - YAML
# ============================================

function Get-TasksYaml {
  & yq -r '.tasks[] | select(.completed != true) | .title' $script:PRD_FILE 2>$null
}

function Get-NextTaskYaml {
  $task = & yq -r '.tasks[] | select(.completed != true) | .title' $script:PRD_FILE 2>$null | Select-Object -First 1
  if (-not $task) { return "" }
  if ($task.Length -gt 50) { return $task.Substring(0, 50) }
  return $task
}

function Count-RemainingYaml {
  $val = & yq -r '[.tasks[] | select(.completed != true)] | length' $script:PRD_FILE 2>$null
  if (-not $val) { return 0 }
  return [int]$val
}

function Count-CompletedYaml {
  $val = & yq -r '[.tasks[] | select(.completed == true)] | length' $script:PRD_FILE 2>$null
  if (-not $val) { return 0 }
  return [int]$val
}

function Invoke-YqWithEnv {
  param(
    [string]$EnvName,
    [string]$EnvValue,
    [string]$Expression,
    [switch]$InPlace
  )
  $prev = Get-Item -Path "Env:$EnvName" -ErrorAction SilentlyContinue
  try {
    Set-Item -Path "Env:$EnvName" -Value $EnvValue
    if ($InPlace) { & yq -i $Expression $script:PRD_FILE }
    else { & yq -r $Expression $script:PRD_FILE 2>$null }
  } finally {
    if ($null -eq $prev) { Remove-Item -Path "Env:$EnvName" -ErrorAction SilentlyContinue }
    else { Set-Item -Path "Env:$EnvName" -Value $prev.Value }
  }
}

function Mark-TaskCompleteYaml {
  param([string]$Task)
  Invoke-YqWithEnv "GRALPH_TASK_TITLE" $Task '(.tasks[] | select(.title == strenv(GRALPH_TASK_TITLE))).completed = true' -InPlace
}

# ============================================
# YAML V1 VALIDATION (DAG + MUTEX)
# ============================================

function Is-YamlV1 {
  $version = Normalize-YqScalar (& yq -r '.version' $script:PRD_FILE 2>$null)
  if ($version -eq "1") { return $true }
  if ($version -and $version -ne "1") { return $false }
  $hasId = Normalize-YqScalar ((& yq -r '.tasks[]?.id' $script:PRD_FILE 2>$null | Select-Object -First 1))
  return [bool]$hasId
}

function Get-TaskIdYamlV1 {
  param([int]$Index)
  Normalize-YqScalar (& yq -r ".tasks[$Index].id" $script:PRD_FILE 2>$null)
}

function Get-AllTaskIdsYamlV1 {
  & yq -r '.tasks[].id' $script:PRD_FILE 2>$null
}

function Get-PendingTaskIdsYamlV1 {
  & yq -r '.tasks[] | select(.completed != true) | .id' $script:PRD_FILE 2>$null
}

function Get-TaskTitleByIdYamlV1 {
  param([string]$Id)
  Invoke-YqWithEnv "GRALPH_TASK_ID" $Id '.tasks[] | select(.id == strenv(GRALPH_TASK_ID)) | .title'
}

function Get-TaskDepsByIdYamlV1 {
  param([string]$Id)
  Invoke-YqWithEnv "GRALPH_TASK_ID" $Id '.tasks[] | select(.id == strenv(GRALPH_TASK_ID)) | .dependsOn[]?'
}

function Get-TaskMutexByIdYamlV1 {
  param([string]$Id)
  Invoke-YqWithEnv "GRALPH_TASK_ID" $Id '.tasks[] | select(.id == strenv(GRALPH_TASK_ID)) | .mutex[]?'
}

function Is-TaskCompletedYamlV1 {
  param([string]$Id)
  $completed = Invoke-YqWithEnv "GRALPH_TASK_ID" $Id '.tasks[] | select(.id == strenv(GRALPH_TASK_ID)) | .completed'
  return ($completed -eq "true")
}

function Mark-TaskCompleteByIdYamlV1 {
  param([string]$Id)
  Invoke-YqWithEnv "GRALPH_TASK_ID" $Id '(.tasks[] | select(.id == strenv(GRALPH_TASK_ID))).completed = true' -InPlace
}

function Load-MutexCatalog {
  $baseDir = $script:ORIGINAL_DIR
  if (-not $baseDir) { $baseDir = (Get-Location).Path }
  $catalogFile = Join-Path $baseDir "mutex-catalog.json"
  if (-not (Test-Path $catalogFile)) { return "" }
  & jq -r '.mutex | keys[]' $catalogFile 2>$null
}

function Is-ValidMutex {
  param([string]$Mutex, [string[]]$Catalog)
  if ($Mutex -like "contract:*") { return $true }
  if (-not $Catalog) { return $true }
  return $Catalog -contains $Mutex
}

function Validate-TasksYamlV1 {
  $errors = @()
  $version = Normalize-YqScalar (& yq -r '.version' $script:PRD_FILE 2>$null)
  if ($version -and $version -ne "1") { $errors += "version must be 1 if specified (got: $version)" }
  $mutexCatalog = Load-MutexCatalog
  $allIds = @()
  foreach ($idRaw in (Get-AllTaskIdsYamlV1)) {
    $id = Normalize-YqScalar $idRaw
    if ($id) { $allIds += $id }
  }
  $seen = @{}
  foreach ($id in $allIds) {
    if ($seen.ContainsKey($id)) { $errors += "Duplicate id: $id" } else { $seen[$id] = $true }
  }

  $taskCount = [int](& yq -r '.tasks | length' $script:PRD_FILE 2>$null)
  for ($i = 0; $i -lt $taskCount; $i++) {
    $id = Normalize-YqScalar (& yq -r ".tasks[$i].id" $script:PRD_FILE)
    $title = Normalize-YqScalar (& yq -r ".tasks[$i].title" $script:PRD_FILE)
    $completedRaw = & yq -r ".tasks[$i].completed" $script:PRD_FILE
    $completed = ($completedRaw -replace "`r", "").Trim().ToLowerInvariant()
    if (-not $id) { $errors += "Task $($i + 1): missing id" }
    if (-not $title) { $errors += "Task $($i + 1): missing title" }
    if ($completed -ne "true" -and $completed -ne "false") { $errors += "Task ${id}: completed must be true/false" }
    foreach ($dep in (& yq -r ".tasks[$i].dependsOn[]?" $script:PRD_FILE 2>$null)) {
      if ($dep -and -not ($allIds -contains $dep)) { $errors += "Task ${id}: dependsOn '$dep' not found" }
    }
    foreach ($mutex in (& yq -r ".tasks[$i].mutex[]?" $script:PRD_FILE 2>$null)) {
      if ($mutex -and -not (Is-ValidMutex $mutex $mutexCatalog)) { $errors += "Task ${id}: unknown mutex '$mutex'" }
    }
  }
  $cycle = Detect-CyclesYamlV1
  if ($cycle) { $errors += "Cycle detected: $cycle" }
  if ($errors.Count -gt 0) {
    Log-Error "tasks.yaml validation failed:"
    foreach ($err in $errors) { Write-Host "  - $err" }
    return $false
  }
  Log-Success "tasks.yaml valid ($($allIds.Count) tasks)"
  return $true
}

function Detect-CyclesYamlV1 {
  $state = @{}
  $parent = @{}
  $allIds = @()
  foreach ($id in (Get-AllTaskIdsYamlV1)) {
    if ($id) { $allIds += $id; $state[$id] = 0 }
  }
  function Dfs-Check([string]$Start) {
    $stack = New-Object System.Collections.Stack
    $pathStack = New-Object System.Collections.Stack
    $stack.Push($Start)
    $pathStack.Push($Start)
    while ($stack.Count -gt 0) {
      $current = $stack.Peek()
      if ($state[$current] -eq 0) {
        $state[$current] = 1
        foreach ($dep in (Get-TaskDepsByIdYamlV1 $current)) {
          if (-not $dep) { continue }
          if ($state[$dep] -eq 1) {
            $cyclePath = $dep
            $pathArray = $pathStack.ToArray()
            foreach ($node in $pathArray) {
              $cyclePath = "$node -> $cyclePath"
              if ($node -eq $dep) { break }
            }
            return $cyclePath
          } elseif ($state[$dep] -eq 0) {
            $stack.Push($dep)
            $pathStack.Push($dep)
            $parent[$dep] = $current
          }
        }
      } else {
        $null = $stack.Pop()
        $null = $pathStack.Pop()
        $state[$current] = 2
      }
    }
    return ""
  }
  foreach ($id in $allIds) {
    if ($state[$id] -eq 0) {
      $result = Dfs-Check $id
      if ($result) { return $result }
    }
  }
  return ""
}

# ============================================
# DAG SCHEDULER (YAML V1)
# ============================================

$script:SCHED_STATE = @{}
$script:SCHED_LOCKED = @{}

function Scheduler-InitYamlV1 {
  $script:SCHED_STATE = @{}
  $script:SCHED_LOCKED = @{}
  foreach ($id in (Get-AllTaskIdsYamlV1)) {
    if (-not $id) { continue }
    if (Is-TaskCompletedYamlV1 $id) { $script:SCHED_STATE[$id] = "done" }
    else { $script:SCHED_STATE[$id] = "pending" }
  }
}

function Scheduler-DepsSatisfied {
  param([string]$Id)
  foreach ($dep in (Get-TaskDepsByIdYamlV1 $Id)) {
    if (-not $dep) { continue }
    if ($script:SCHED_STATE[$dep] -ne "done") { return $false }
  }
  return $true
}

function Scheduler-MutexAvailable {
  param([string]$Id)
  foreach ($mutex in (Get-TaskMutexByIdYamlV1 $Id)) {
    if (-not $mutex) { continue }
    if ($script:SCHED_LOCKED.ContainsKey($mutex) -and $script:SCHED_LOCKED[$mutex]) { return $false }
  }
  return $true
}

function Scheduler-LockMutex {
  param([string]$Id)
  foreach ($mutex in (Get-TaskMutexByIdYamlV1 $Id)) {
    if (-not $mutex) { continue }
    $script:SCHED_LOCKED[$mutex] = $Id
  }
}

function Scheduler-UnlockMutex {
  param([string]$Id)
  foreach ($mutex in (Get-TaskMutexByIdYamlV1 $Id)) {
    if (-not $mutex) { continue }
    $script:SCHED_LOCKED.Remove($mutex) | Out-Null
  }
}

function Scheduler-GetReady {
  $ready = @()
  foreach ($id in $script:SCHED_STATE.Keys) {
    if ($script:SCHED_STATE[$id] -eq "pending") {
      if (Scheduler-DepsSatisfied $id -and (Scheduler-MutexAvailable $id)) { $ready += $id }
    }
  }
  return $ready
}

function Scheduler-CountRunning {
  ($script:SCHED_STATE.Values | Where-Object { $_ -eq "running" }).Count
}

function Scheduler-CountPending {
  ($script:SCHED_STATE.Values | Where-Object { $_ -eq "pending" }).Count
}

function Scheduler-StartTask {
  param([string]$Id)
  $script:SCHED_STATE[$Id] = "running"
  Scheduler-LockMutex $Id
  Log-Debug "Task ${Id}: pending -> running (mutex locked)"
}

function Scheduler-CompleteTask {
  param([string]$Id)
  $script:SCHED_STATE[$Id] = "done"
  Scheduler-UnlockMutex $Id
  Mark-TaskCompleteByIdYamlV1 $Id
  Log-Debug "Task ${Id}: running -> done (mutex released)"
}

function Scheduler-FailTask {
  param([string]$Id)
  $script:SCHED_STATE[$Id] = "failed"
  Scheduler-UnlockMutex $Id
  Log-Debug "Task ${Id}: running -> failed (mutex released)"
}

function Scheduler-ExplainBlock {
  param([string]$Id)
  $reasons = @()
  $blockedDeps = @()
  foreach ($dep in (Get-TaskDepsByIdYamlV1 $Id)) {
    if (-not $dep) { continue }
    if ($script:SCHED_STATE[$dep] -ne "done") { $blockedDeps += "$dep ($($script:SCHED_STATE[$dep]))" }
  }
  if ($blockedDeps.Count -gt 0) { $reasons += "dependsOn: $($blockedDeps -join ' ')" }
  $blockedMutex = @()
  foreach ($mutex in (Get-TaskMutexByIdYamlV1 $Id)) {
    if (-not $mutex) { continue }
    if ($script:SCHED_LOCKED.ContainsKey($mutex) -and $script:SCHED_LOCKED[$mutex]) {
      $blockedMutex += "$mutex (held by $($script:SCHED_LOCKED[$mutex]))"
    }
  }
  if ($blockedMutex.Count -gt 0) { $reasons += "mutex: $($blockedMutex -join ' ')" }
  return ($reasons -join ' ')
}

function Scheduler-CheckDeadlock {
  $pending = Scheduler-CountPending
  $running = Scheduler-CountRunning
  $ready = (Scheduler-GetReady).Count
  if ($pending -gt 0 -and $running -eq 0 -and $ready -eq 0) { return $true }
  return $false
}

# ============================================
# PIPELINE AGENTS (PRD -> TASKS -> RUN -> REVIEW)
# ============================================

$script:ARTIFACTS_DIR = ""

function Init-ArtifactsDir {
  $script:ARTIFACTS_DIR = "artifacts/run-$(Get-Date -Format yyyyMMdd-HHmmss)"
  New-Item -ItemType Directory -Force -Path (Join-Path $script:ARTIFACTS_DIR "reports") | Out-Null
  $env:ARTIFACTS_DIR = $script:ARTIFACTS_DIR
}

function Find-PrdFile {
  $candidates = @("PRD.md","prd.md","tasks/prd-*.md")
  foreach ($pattern in $candidates) {
    foreach ($f in Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue) {
      if ($f -and (Test-Path $f)) { return $f }
    }
  }
  return ""
}

# ============================================
# STAGE 0: PRD -> tasks.yaml (Metadata Agent)
# ============================================

function Run-MetadataAgent {
  param([string]$PrdFile, [string]$OutputFile)
  $outputDir = Split-Path -Parent $OutputFile
  Log-Info "Generating $OutputFile from $PrdFile..."
  $prompt = @"
Read the PRD file and convert it to tasks.yaml format.

@$PrdFile

Create a tasks.yaml file with this EXACT format:

branchName: gralph/your-feature-name
tasks:
  - id: TASK-001
    title: "First task description"
    completed: false
    dependsOn: []
    mutex: []
  - id: TASK-002
    title: "Second task description"
    completed: false
    dependsOn: ["TASK-001"]
    mutex: []

Rules:
1. Each task gets a unique ID (TASK-001, TASK-002, etc.)
2. Order tasks by dependency (database first, then backend, then frontend)
3. Use dependsOn to link tasks that must run after others
4. Use mutex for shared resources: db-migrations, lockfile, router, global-config
5. Set branchName to a short kebab-case feature name prefixed with "gralph/" (based on the PRD)
6. Keep tasks small and focused (completable in one session)

Save the file as $OutputFile.
Do NOT implement anything - only create the tasks.yaml file.
"@
  $tmpfile = [IO.Path]::GetTempFileName()
  Execute-AiPrompt $prompt $tmpfile
  Remove-Item $tmpfile -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path $OutputFile)) {
    Log-Error "Metadata agent failed to create $OutputFile"
    return $false
  }
  Log-Success "Generated $OutputFile"
  return $true
}

# ============================================
# STAGE 2: Task Reports
# ============================================

function Get-TaskMergeNotesYamlV1 {
  param([string]$Id)
  Normalize-YqScalar (Invoke-YqWithEnv "GRALPH_TASK_ID" $Id '.tasks[] | select(.id == strenv(GRALPH_TASK_ID)) | .mergeNotes')
}

function Save-TaskReport {
  param([string]$TaskId, [string]$Branch, [string]$WorktreeDir, [string]$Status)
  if (-not $script:ARTIFACTS_DIR) { return }
  $changedFiles = (& git -C $WorktreeDir diff --name-only "$($script:BASE_BRANCH)..HEAD" 2>$null) -join "," | ForEach-Object { $_.Trim() }
  $commitCount = & git -C $WorktreeDir rev-list --count "$($script:BASE_BRANCH)..HEAD" 2>$null
  if (-not $commitCount) { $commitCount = 0 }
  $safeBranch = Json-Escape $Branch
  $safeChanged = Json-Escape $changedFiles
  $json = @"
{
  "taskId": "$TaskId",
  "branch": "$safeBranch",
  "status": "$Status",
  "commits": $commitCount,
  "changedFiles": "$safeChanged",
  "timestamp": "$(Get-Date -AsUTC -Format yyyy-MM-ddTHH:mm:ssZ)"
}
"@
  $json | Set-Content -Path (Join-Path $script:ARTIFACTS_DIR "reports/$TaskId.json")
}

# ============================================
# STAGE 3: Integration Branch + Merge Agent
# ============================================

$script:INTEGRATION_BRANCH = ""

function Create-IntegrationBranch {
  $script:INTEGRATION_BRANCH = "gralph/integration-$(Get-Date -Format yyyyMMdd-HHmmss)"
  & git checkout -b $script:INTEGRATION_BRANCH $script:BASE_BRANCH >$null 2>$null
  Log-Info "Created integration branch: $($script:INTEGRATION_BRANCH)"
}

function Merge-BranchWithFallback {
  param([string]$Branch, [string]$TaskId)
  & git merge --no-edit $Branch >$null 2>$null
  if ($LASTEXITCODE -eq 0) { return $true }
  Log-Warn "Conflict merging $Branch, attempting AI resolution..."
  $conflictedFiles = & git diff --name-only --diff-filter=U 2>$null
  $mergeNotes = Get-TaskMergeNotesYamlV1 $TaskId
  $prompt = @"
Resolve git merge conflicts in these files:

$conflictedFiles

Merge notes from task: $mergeNotes

For each file:
1. Read the conflict markers (<<<<<<< HEAD, =======, >>>>>>>)
2. Combine BOTH changes intelligently
3. Remove all conflict markers
4. Ensure valid syntax

Then run:
git add <files>
git commit --no-edit
"@
  $tmpfile = [IO.Path]::GetTempFileName()
  Execute-AiPrompt $prompt $tmpfile
  Remove-Item $tmpfile -Force -ErrorAction SilentlyContinue
  $stillConflicted = & git diff --name-only --diff-filter=U 2>$null
  if ($stillConflicted) {
    Log-Error "AI failed to resolve conflicts in $Branch"
    & git merge --abort 2>$null | Out-Null
    return $false
  }
  Log-Success "AI resolved conflicts in $Branch"
  return $true
}

# ============================================
# STAGE 5: Semantic Reviewer
# ============================================

function Run-ReviewerAgent {
  if (-not $script:ARTIFACTS_DIR -or -not $script:INTEGRATION_BRANCH) { return $true }
  Log-Info "Running semantic reviewer..."
  $diffSummary = & git diff --stat "$($script:BASE_BRANCH)..$($script:INTEGRATION_BRANCH)" 2>$null | Select-Object -Last 20
  $reportsSummary = ""
  $reportFiles = Get-ChildItem -Path (Join-Path $script:ARTIFACTS_DIR "reports") -Filter "*.json" -ErrorAction SilentlyContinue
  foreach ($report in $reportFiles) { $reportsSummary += "`n$(Get-Content $report.FullName -Raw)" }
  $prompt = @"
Review the integrated code changes for issues.

Diff summary:
$diffSummary

Task reports:
$reportsSummary

Check for:
1. Type mismatches between modules
2. Broken imports or references
3. Inconsistent patterns (error handling, naming)
4. Missing exports

Create a file review-report.json with this format:
{
  "issues": [
    {"severity": "blocker|critical|warning", "file": "path", "description": "...", "suggestedFix": "..."}
  ],
  "summary": "Brief overall assessment"
}

If no issues found, create an empty issues array.
Save to $($script:ARTIFACTS_DIR)/review-report.json
"@
  $tmpfile = [IO.Path]::GetTempFileName()
  Execute-AiPrompt $prompt $tmpfile
  Remove-Item $tmpfile -Force -ErrorAction SilentlyContinue
  $reportPath = Join-Path $script:ARTIFACTS_DIR "review-report.json"
  if (Test-Path $reportPath) {
    $blockers = & jq -r '[.issues[] | select(.severity == "blocker")] | length' $reportPath 2>$null
    if ($blockers -and [int]$blockers -gt 0) {
      Log-Warn "Reviewer found $blockers blocker(s)"
      return $false
    }
    Log-Success "Review passed (no blockers)"
  }
  return $true
}

function Generate-FixTasks {
  $reportPath = Join-Path $script:ARTIFACTS_DIR "review-report.json"
  if (-not (Test-Path $reportPath)) { return }
  $blockers = & jq -r '.issues[] | select(.severity == "blocker")' $reportPath 2>$null
  if (-not $blockers) { return }
  Log-Info "Generating fix tasks from blockers..."
  $fixNum = 1
  $blockerItems = $blockers | & jq -c '.' 2>$null
  foreach ($issue in $blockerItems) {
    $desc = ($issue | & jq -r '.description') -join ""
    $fix = ($issue | & jq -r '.suggestedFix') -join ""
    & yq -i ".tasks += [{
      `"id`": `"FIX-$(("{0:000}" -f $fixNum))`",
      `"title`": `"Fix: $desc`",
      `"completed`": false,
      `"dependsOn`": [],
      `"mutex`": []
    }]" $script:PRD_FILE
    $fixNum++
  }
  Log-Success "Added fix tasks"
}

# ============================================
# GIT BRANCH MANAGEMENT
# ============================================

function Get-RunBranchFromTasksYaml {
  $name = Normalize-YqScalar (& yq -r '.branchName' $script:PRD_FILE 2>$null)
  return $name
}

function Ensure-RunBranch {
  $script:RUN_BRANCH = Get-RunBranchFromTasksYaml
  if (-not $script:RUN_BRANCH) { return }
  $baseRef = $script:BASE_BRANCH
  if (-not $baseRef) {
    $baseRef = (& git rev-parse --abbrev-ref HEAD 2>$null) -join ""
    if (-not $baseRef) { $baseRef = "main" }
  }
  $exists = & git show-ref --verify --quiet "refs/heads/$($script:RUN_BRANCH)"
  if ($LASTEXITCODE -eq 0) {
    Log-Info "Switching to run branch: $($script:RUN_BRANCH)"
    & git checkout $script:RUN_BRANCH >$null 2>$null
  } else {
    Log-Info "Creating run branch: $($script:RUN_BRANCH) from $baseRef"
    & git checkout $baseRef >$null 2>$null | Out-Null
    & git pull origin $baseRef >$null 2>$null | Out-Null
    & git checkout -b $script:RUN_BRANCH >$null 2>$null | Out-Null
  }
  $script:BASE_BRANCH = $script:RUN_BRANCH
}

function Create-TaskBranch {
  param([string]$Task)
  $branchName = "gralph/$(Slugify $Task)"
  Log-Debug "Creating branch: $branchName from $($script:BASE_BRANCH)"
  $stashBefore = (& git stash list -1 --format='%gd %s' 2>$null) -join ""
  & git stash push -m "gralph-autostash" >$null 2>$null | Out-Null
  $stashAfter = (& git stash list -1 --format='%gd %s' 2>$null) -join ""
  $stashed = $false
  if ($stashAfter -and $stashAfter -ne $stashBefore -and $stashAfter -match "gralph-autostash") { $stashed = $true }
  & git checkout $script:BASE_BRANCH >$null 2>$null | Out-Null
  & git pull origin $script:BASE_BRANCH >$null 2>$null | Out-Null
  & git checkout -b $branchName >$null 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { & git checkout $branchName >$null 2>$null | Out-Null }
  if ($stashed) { & git stash pop >$null 2>$null | Out-Null }
  $script:task_branches += $branchName
  return $branchName
}

function Create-PullRequest {
  param([string]$Branch, [string]$Task, [string]$Body = "Automated PR created by GRALPH")
  $draftFlag = if ($script:PR_DRAFT) { "--draft" } else { "" }
  Log-Info "Creating pull request for $Branch..."
  & git push -u origin $Branch >$null 2>$null
  if ($LASTEXITCODE -ne 0) {
    Log-Warn "Failed to push branch $Branch"
    return ""
  }
  $prUrl = & gh pr create --base $script:BASE_BRANCH --head $Branch --title $Task --body $Body $draftFlag 2>$null
  if ($LASTEXITCODE -ne 0) {
    Log-Warn "Failed to create PR for $Branch"
    return ""
  }
  Log-Success "PR created: $prUrl"
  return $prUrl
}

function Return-ToBaseBranch {
  if ($script:BRANCH_PER_TASK) { & git checkout $script:BASE_BRANCH >$null 2>$null | Out-Null }
}

# ============================================
# PROGRESS MONITOR
# ============================================

function Get-AgentCurrentStep {
  param([string]$File)
  $step = "Thinking"
  if (-not (Test-Path $File)) { return $step }
  $content = Get-Content $File -Raw -ErrorAction SilentlyContinue
  if (-not $content) { return $step }
  if ($content -match 'git commit|"command":"git commit') { return "Committing" }
  if ($content -match 'git add|"command":"git add') { return "Staging" }
  if ($content -match 'progress\.txt') { return "Logging" }
  if ($content -match 'PRD\.md|tasks\.yaml') { return "Updating PRD" }
  if ($content -match 'lint|eslint|biome|prettier') { return "Linting" }
  if ($content -match 'vitest|jest|bun test|npm test|pytest|go test') { return "Testing" }
  if ($content -match '\.test\.|\.spec\.|__tests__|_test\.go') { return "Writing tests" }
  if ($content -match '"tool":"[Ww]rite"|"tool":"[Ee]dit"|"name":"write"|"name":"edit"|"tool_name":"write"|"tool_name":"edit"') { return "Implementing" }
  if ($content -match '"tool":"[Rr]ead"|"tool":"[Gg]lob"|"tool":"[Gg]rep"|"name":"read"|"name":"glob"|"name":"grep"|"tool_name":"read"') { return "Reading code" }
  if ($content -match '"tool":"[Bb]ash"|"tool":"[Tt]erminal"|"name":"bash"|"tool_name":"bash"') { return "Running cmd" }
  return $step
}

function Get-StepColor {
  param([string]$Step)
  switch ($Step) {
    "Thinking" { return $script:CYAN }
    "Reading code" { return $script:CYAN }
    "Implementing" { return $script:MAGENTA }
    "Writing tests" { return $script:MAGENTA }
    "Testing" { return $script:YELLOW }
    "Linting" { return $script:YELLOW }
    "Running cmd" { return $script:YELLOW }
    "Staging" { return $script:GREEN }
    "Committing" { return $script:GREEN }
    default { return $script:BLUE }
  }
}

# ============================================
# NOTIFICATION (Cross-platform)
# ============================================

function Notify-Done {
  param([string]$Message = "GRALPH has completed all tasks!")
  try { & powershell.exe -Command "[System.Media.SystemSounds]::Asterisk.Play()" 2>$null | Out-Null } catch { }
}

function Notify-Error {
  param([string]$Message = "GRALPH encountered an error")
  # No-op on Windows beyond sound/console
}

# ============================================
# AI ENGINE ABSTRACTION
# ============================================

function Execute-AiPrompt {
  param(
    [string]$Prompt,
    [string]$OutputFile,
    [string]$Options = ""
  )
  $async = $false
  $workingDir = ""
  $logFile = ""
  $teeFile = ""
  foreach ($opt in $Options.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)) {
    if ($opt -eq "async") { $async = $true }
    elseif ($opt -like "wd=*") { $workingDir = $opt.Substring(3) }
    elseif ($opt -like "log=*") { $logFile = $opt.Substring(4) }
    elseif ($opt -like "tee=*") { $teeFile = $opt.Substring(4) }
  }

  $cmd = @()
  $restorePermission = $null
  switch ($script:AI_ENGINE) {
    "opencode" {
      $restorePermission = $env:OPENCODE_PERMISSION
      $env:OPENCODE_PERMISSION = '{"*":"allow"}'
      $cmd = @("opencode","run","--format","json")
      if ($script:OPENCODE_MODEL) { $cmd += @("--model",$script:OPENCODE_MODEL) }
      $cmd += $Prompt
    }
    "cursor" { $cmd = @("agent","--print","--force","--output-format","stream-json",$Prompt) }
    "codex" { $cmd = @("codex","exec","--full-auto","--json",$Prompt) }
    default { $cmd = @("claude","--dangerously-skip-permissions","--verbose","-p",$Prompt,"--output-format","stream-json") }
  }

  $runCmd = {
    param([string[]]$Cmd, [string]$OutFile, [string]$LogFile, [string]$TeeFile)
    if (-not $Cmd -or $Cmd.Count -eq 0) { throw "Empty command" }
    $exe = $Cmd[0]
    $args = @()
    if ($Cmd.Count -gt 1) { $args = $Cmd[1..($Cmd.Count - 1)] }
    if ($TeeFile) {
      if ($LogFile) {
        & $exe @args 2>> $LogFile | Tee-Object -FilePath $TeeFile -Append | Tee-Object -FilePath $OutFile | Out-Null
      } else {
        & $exe @args | Tee-Object -FilePath $TeeFile -Append | Tee-Object -FilePath $OutFile | Out-Null
      }
    } else {
      if ($LogFile) { & $exe @args 2>> $LogFile | Set-Content -Path $OutFile }
      else { & $exe @args | Set-Content -Path $OutFile }
    }
  }

  try {
    if ($workingDir) { Push-Location $workingDir }
    if ($async) {
      $proc = Start-Process -FilePath $cmd[0] -ArgumentList $cmd[1..($cmd.Count - 1)] -NoNewWindow -RedirectStandardOutput $OutputFile -PassThru
      $script:ai_pid = $proc.Id
    } else {
      & $runCmd -Cmd $cmd -OutFile $OutputFile -LogFile $logFile -TeeFile $teeFile
    }
  } finally {
    if ($workingDir) { Pop-Location }
    if ($restorePermission -ne $null) { $env:OPENCODE_PERMISSION = $restorePermission }
  }
}

function Run-AiCommand {
  param([string]$Prompt, [string]$OutputFile)
  if ($script:AI_ENGINE -eq "codex") {
    $script:CODEX_LAST_MESSAGE_FILE = "$OutputFile.last"
    if (Test-Path $script:CODEX_LAST_MESSAGE_FILE) { Remove-Item $script:CODEX_LAST_MESSAGE_FILE -Force }
  }
  Execute-AiPrompt $Prompt $OutputFile "async"
}

function Parse-AiResult {
  param([string]$Result)
  $response = ""
  $inputTokens = 0
  $outputTokens = 0
  $actualCost = "0"
  switch ($script:AI_ENGINE) {
    "opencode" {
      $stepFinish = ($Result -split "`n" | Where-Object { $_ -match '"type":"step_finish"' } | Select-Object -Last 1)
      if ($stepFinish) {
        try {
          $obj = $stepFinish | ConvertFrom-Json
          $inputTokens = $obj.part.tokens.input
          $outputTokens = $obj.part.tokens.output
          $actualCost = $obj.part.cost
        } catch { }
      }
      $textLines = ($Result -split "`n" | Where-Object { $_ -match '"type":"text"' })
      if ($textLines) {
        $parts = @()
        foreach ($line in $textLines) {
          try { $parts += ((ConvertFrom-Json $line).part.text) } catch { }
        }
        $response = ($parts -join "")
      }
      if (-not $response) { $response = "Task completed" }
    }
    "cursor" {
      $resultLine = ($Result -split "`n" | Where-Object { $_ -match '"type":"result"' } | Select-Object -Last 1)
      if ($resultLine) {
        try {
          $obj = $resultLine | ConvertFrom-Json
          $response = $obj.result
          $durationMs = $obj.duration_ms
          if ($durationMs -and $durationMs -gt 0) { $actualCost = "duration:$durationMs" }
        } catch { $response = "Task completed" }
      }
      if (-not $response -or $response -eq "Task completed") {
        $assistant = ($Result -split "`n" | Where-Object { $_ -match '"type":"assistant"' } | Select-Object -Last 1)
        if ($assistant) {
          try {
            $obj = $assistant | ConvertFrom-Json
            $response = $obj.message.content[0].text
          } catch { }
        }
      }
    }
    "codex" {
      if ($script:CODEX_LAST_MESSAGE_FILE -and (Test-Path $script:CODEX_LAST_MESSAGE_FILE)) {
        $response = Get-Content $script:CODEX_LAST_MESSAGE_FILE -Raw
        $response = $response -replace '^Task completed successfully\.\s*$',''
      }
    }
    default {
      $resultLine = ($Result -split "`n" | Where-Object { $_ -match '"type":"result"' } | Select-Object -Last 1)
      if ($resultLine) {
        try {
          $obj = $resultLine | ConvertFrom-Json
          $response = $obj.result
          $inputTokens = $obj.usage.input_tokens
          $outputTokens = $obj.usage.output_tokens
        } catch {
          $response = "Could not parse result"
        }
      }
    }
  }
  if ($inputTokens -notmatch '^\d+$') { $inputTokens = 0 }
  if ($outputTokens -notmatch '^\d+$') { $outputTokens = 0 }
  return @($response, "---TOKENS---", $inputTokens, $outputTokens, $actualCost) -join "`n"
}

function Check-ForErrors {
  param([string]$Result)
  if ($Result -match '"type":"error"') {
    $line = ($Result -split "`n" | Where-Object { $_ -match '"type":"error"' } | Select-Object -First 1)
    try {
      $obj = $line | ConvertFrom-Json
      return $obj.error.message
    } catch {
      return "Unknown error"
    }
  }
  return ""
}

# ============================================
# COST CALCULATION
# ============================================

function Calculate-Cost {
  param([int]$Input, [int]$Output)
  if (-not (Get-Command bc -ErrorAction SilentlyContinue)) { return "N/A" }
  $expr = "scale=4; ($Input * 0.000003) + ($Output * 0.000015)"
  return ($expr | & bc -l) 2>$null
}

# ============================================
# PARALLEL TASK EXECUTION
# ============================================

function Create-AgentWorktree {
  param([string]$TaskName, [int]$AgentNum)
  $branchName = "gralph/agent-$AgentNum-$(Slugify $TaskName)"
  $worktreeDir = Join-Path $script:WORKTREE_BASE "agent-$AgentNum"
  Push-Location $script:ORIGINAL_DIR
  try {
    & git worktree prune 2>$null | Out-Null
    $existing = & git worktree list 2>$null | Select-String "\[$branchName\]" | ForEach-Object { ($_ -split '\s+')[0] }
    if ($existing) {
      Write-Error "Removing existing worktree for $branchName at $existing"
      & git worktree remove --force $existing 2>$null | Out-Null
      & git worktree prune 2>$null | Out-Null
    }
    & git branch -D $branchName 2>$null | Out-Null
    & git branch $branchName $script:BASE_BRANCH 2>$null | Out-Null
    Remove-Item $worktreeDir -Recurse -Force -ErrorAction SilentlyContinue
    & git worktree add $worktreeDir $branchName 2>$null | Out-Null
  } finally {
    Pop-Location
  }
  return "$worktreeDir|$branchName"
}

function Cleanup-AgentWorktree {
  param([string]$WorktreeDir, [string]$BranchName, [string]$LogFile)
  $dirty = $false
  if (Test-Path $WorktreeDir) {
    $status = & git -C $WorktreeDir status --porcelain 2>$null
    if ($status) { $dirty = $true }
  }
  if ($dirty) {
    if ($LogFile) { Add-Content -Path $LogFile -Value "Worktree left in place due to uncommitted changes: $WorktreeDir" }
    return
  }
  Push-Location $script:ORIGINAL_DIR
  try { & git worktree remove -f $WorktreeDir 2>$null | Out-Null } finally { Pop-Location }
}

function Run-ParallelAgentYamlV1 {
  param(
    [string]$TaskId,
    [int]$AgentNum,
    [string]$OutputFile,
    [string]$StatusFile,
    [string]$LogFile,
    [string]$StreamFile
  )
  $taskTitle = Get-TaskTitleByIdYamlV1 $TaskId
  "setting up" | Set-Content -Path $StatusFile
  Add-Content -Path $LogFile -Value "Agent $AgentNum starting for task: $TaskId - $taskTitle"
  Add-Content -Path $LogFile -Value "[DEBUG] AI_ENGINE=$($script:AI_ENGINE) OPENCODE_MODEL=$($script:OPENCODE_MODEL)"
  $worktreeInfo = Create-AgentWorktree $TaskId $AgentNum
  $worktreeDir = $worktreeInfo.Split("|")[0]
  $branchName = $worktreeInfo.Split("|")[1]
  if (-not (Test-Path $worktreeDir)) {
    "failed" | Set-Content -Path $StatusFile
    "0 0" | Set-Content -Path $OutputFile
    return $false
  }
  "running" | Set-Content -Path $StatusFile
  Copy-Item (Join-Path $script:ORIGINAL_DIR $script:PRD_FILE) $worktreeDir -Force -ErrorAction SilentlyContinue
  New-Item -ItemType File -Force -Path (Join-Path $worktreeDir "scripts/gralph/progress.txt") | Out-Null
  $prompt = @"
You are working on a specific task. Focus ONLY on this task:

TASK ID: $TaskId
TASK: $taskTitle

Instructions:
1. Implement this specific task completely
2. Write tests if appropriate
3. Update progress.txt with what you did
4. Commit your changes with a descriptive message

Do NOT modify tasks.yaml or mark tasks complete - that will be handled separately.
Focus only on implementing: $taskTitle
"@
  $tmpfile = [IO.Path]::GetTempFileName()
  $success = $false
  $retry = 0
  $result = ""
  while ($retry -lt $script:MAX_RETRIES) {
    if ($StreamFile) { "" | Set-Content -Path $StreamFile }
    $aiOpts = "wd=$worktreeDir log=$LogFile"
    if ($StreamFile) { $aiOpts = "$aiOpts tee=$StreamFile" }
    Execute-AiPrompt $prompt $tmpfile $aiOpts
    $result = Get-Content $tmpfile -Raw -ErrorAction SilentlyContinue
    if ($result) {
      $errMsg = Check-ForErrors $result
      if (-not $errMsg) { $success = $true; break }
    }
    $retry++
    Start-Sleep -Seconds $script:RETRY_DELAY
  }
  Remove-Item $tmpfile -Force -ErrorAction SilentlyContinue
  if ($success) {
    $commitCount = & git -C $worktreeDir rev-list --count "$($script:BASE_BRANCH)..HEAD" 2>$null
    if (-not $commitCount -or [int]$commitCount -eq 0) {
      "failed" | Set-Content -Path $StatusFile
      "0 0" | Set-Content -Path $OutputFile
      Cleanup-AgentWorktree $worktreeDir $branchName $LogFile
      return $false
    }
    if ($script:CREATE_PR) {
      Push-Location $worktreeDir
      try {
        & git push -u origin $branchName 2>>$LogFile | Out-Null
        $draftArg = $null
        if ($script:PR_DRAFT) { $draftArg = "--draft" }
        if ($draftArg) {
          & gh pr create --base $script:BASE_BRANCH --head $branchName --title $taskTitle --body "Automated: $TaskId" $draftArg 2>>$LogFile | Out-Null
        } else {
          & gh pr create --base $script:BASE_BRANCH --head $branchName --title $taskTitle --body "Automated: $TaskId" 2>>$LogFile | Out-Null
        }
      } finally { Pop-Location }
    }
    if ($script:ARTIFACTS_DIR) {
      $changedFiles = (& git -C $worktreeDir diff --name-only "$($script:BASE_BRANCH)..HEAD" 2>$null) -join "," | ForEach-Object { $_.Trim() }
      $progressNotes = ""
      $progressPath = Join-Path $worktreeDir "scripts/gralph/progress.txt"
      if (Test-Path $progressPath) { $progressNotes = (Get-Content $progressPath | Select-Object -Last 50) -join "`n" }
      $safeNotes = Json-Escape $progressNotes
      $safeTitle = Json-Escape $taskTitle
      $safeBranch = Json-Escape $branchName
      $safeChanged = Json-Escape $changedFiles
      $reportsDir = Join-Path $script:ORIGINAL_DIR $script:ARTIFACTS_DIR "reports"
      New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null
      $json = @"
{
  "taskId": "$TaskId",
  "title": "$safeTitle",
  "branch": "$safeBranch",
  "status": "done",
  "commits": $commitCount,
  "changedFiles": "$safeChanged",
  "progressNotes": "$safeNotes",
  "timestamp": "$(Get-Date -AsUTC -Format yyyy-MM-ddTHH:mm:ssZ)"
}
"@
      $json | Set-Content -Path (Join-Path $reportsDir "$TaskId.json")
      $progressFile = Join-Path $worktreeDir "progress.txt"
      if (Test-Path $progressFile -PathType Leaf) {
        Add-Content -Path (Join-Path $script:ORIGINAL_DIR "scripts/gralph/progress.txt") -Value ""
        Add-Content -Path (Join-Path $script:ORIGINAL_DIR "scripts/gralph/progress.txt") -Value "### $TaskId - $taskTitle ($(Get-Date -Format yyyy-MM-dd))"
        Get-Content $progressFile | Select-Object -Last 20 | Add-Content -Path (Join-Path $script:ORIGINAL_DIR "scripts/gralph/progress.txt")
      }
    }
    "done" | Set-Content -Path $StatusFile
    "0 0 $branchName $TaskId" | Set-Content -Path $OutputFile
    Cleanup-AgentWorktree $worktreeDir $branchName $LogFile
    return $true
  }
  "failed" | Set-Content -Path $StatusFile
  "0 0" | Set-Content -Path $OutputFile
  Cleanup-AgentWorktree $worktreeDir $branchName $LogFile
  return $false
}

function Run-ParallelTasksYamlV1 {
  Log-Info "Running DAG-aware parallel execution (max $($script:MAX_PARALLEL) agents)..."
  $script:ORIGINAL_DIR = (Get-Location).Path
  $script:WORKTREE_BASE = Join-Path ([IO.Path]::GetTempPath()) ("gralph-" + [guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Force -Path $script:WORKTREE_BASE | Out-Null
  if (-not $script:BASE_BRANCH) {
    $script:BASE_BRANCH = (& git rev-parse --abbrev-ref HEAD 2>$null) -join ""
    if (-not $script:BASE_BRANCH) { $script:BASE_BRANCH = "main" }
  }
  $env:BASE_BRANCH = $script:BASE_BRANCH
  $env:AI_ENGINE = $script:AI_ENGINE
  $env:MAX_RETRIES = $script:MAX_RETRIES
  $env:RETRY_DELAY = $script:RETRY_DELAY
  $env:PRD_FILE = $script:PRD_FILE
  $env:CREATE_PR = $script:CREATE_PR
  $env:PR_DRAFT = $script:PR_DRAFT
  $env:OPENCODE_MODEL = $script:OPENCODE_MODEL
  $env:ORIGINAL_DIR = $script:ORIGINAL_DIR
  $env:WORKTREE_BASE = $script:WORKTREE_BASE
  Init-ArtifactsDir
  Log-Info "Artifacts: $($script:ARTIFACTS_DIR)"
  Scheduler-InitYamlV1
  $script:EXTERNAL_FAIL_DETECTED = $false
  $script:EXTERNAL_FAIL_REASON = ""
  $script:EXTERNAL_FAIL_TASK_ID = ""
  $pending = Scheduler-CountPending
  Log-Info "Tasks: $pending pending"
  $completedBranches = @()
  $completedTaskIds = @()
  $agentNum = 0

  while ($true) {
    $pending = Scheduler-CountPending
    $running = Scheduler-CountRunning
    if ($pending -eq 0 -and $running -eq 0) { break }
    if (Scheduler-CheckDeadlock) {
      Log-Error "DEADLOCK: No progress possible"
      Write-Host ""
      Write-Host "${script:RED}Blocked tasks:${script:RESET}"
      foreach ($id in $script:SCHED_STATE.Keys) {
        if ($script:SCHED_STATE[$id] -eq "pending") {
          $reason = Scheduler-ExplainBlock $id
          Write-Host "  ${id}: $reason"
        }
      }
      return $false
    }
    $readyTasks = Scheduler-GetReady
    $slotsAvailable = $script:MAX_PARALLEL - $running
    $tasksToStart = @()
    for ($i = 0; $i -lt $readyTasks.Count -and $i -lt $slotsAvailable; $i++) { $tasksToStart += $readyTasks[$i] }
    if ($tasksToStart.Count -eq 0) { Start-Sleep -Milliseconds 500; continue }

    Write-Host ""
    Write-Host "${script:BOLD}Starting $($tasksToStart.Count) agent(s)${script:RESET}"
    $batchPids = @()
    $batchIds = @()
    $batchTitles = @()
    $batchAgentNums = @()
    $statusFiles = @()
    $outputFiles = @()
    $logFiles = @()
    $streamFiles = @()

    foreach ($taskId in $tasksToStart) {
      $agentNum++
      $script:iteration++
      Scheduler-StartTask $taskId
      $statusFile = [IO.Path]::GetTempFileName()
      $outputFile = [IO.Path]::GetTempFileName()
      $logFile = [IO.Path]::GetTempFileName()
      $streamFile = [IO.Path]::GetTempFileName()
      $statusFiles += $statusFile
      $outputFiles += $outputFile
      $logFiles += $logFile
      $streamFiles += $streamFile
      $batchIds += $taskId
      $batchAgentNums += $agentNum
      $title = Get-TaskTitleByIdYamlV1 $taskId
      $batchTitles += $title
      Write-Host ("  ${script:CYAN}*${script:RESET} Agent {0}: {1} ({2})" -f $agentNum, $title.Substring(0, [Math]::Min(40, $title.Length)), $taskId)

      $createPrArg = if ($script:CREATE_PR) { "true" } else { "false" }
      $draftPrArg = if ($script:PR_DRAFT) { "true" } else { "false" }
      $argList = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath,
        "--internal-run-agent-yaml-v1", $taskId, $agentNum, $outputFile, $statusFile, $logFile, $streamFile,
        $script:PRD_FILE, $script:BASE_BRANCH, $script:AI_ENGINE, $script:OPENCODE_MODEL,
        $createPrArg, $draftPrArg,
        $script:ORIGINAL_DIR, $script:WORKTREE_BASE, $script:ARTIFACTS_DIR,
        $script:MAX_RETRIES, $script:RETRY_DELAY
      )
      $psExe = (Get-Process -Id $PID).Path
      $proc = Start-Process -FilePath $psExe -ArgumentList $argList -PassThru -NoNewWindow
      $batchPids += $proc.Id
    }

    $script:ACTIVE_PIDS = $batchPids
    $script:ACTIVE_TASK_IDS = $batchIds
    $script:ACTIVE_STATUS_FILES = $statusFiles
    $script:ACTIVE_LOG_FILES = $logFiles

    $startTime = Get-Date
    $allDone = $false
    while (-not $allDone) {
      $allDone = $true
      for ($j = 0; $j -lt $batchPids.Count; $j++) {
        $status = if (Test-Path $statusFiles[$j]) { Get-Content $statusFiles[$j] -Raw } else { "waiting" }
        $pidAlive = Get-Process -Id $batchPids[$j] -ErrorAction SilentlyContinue
        if ($pidAlive) { $allDone = $false }
        if ($status -ne "done" -and $status -ne "failed" -and $pidAlive) { $allDone = $false }
      }
      Start-Sleep -Milliseconds 300
    }

    foreach ($pid in $batchPids) { try { Wait-Process -Id $pid -ErrorAction SilentlyContinue } catch { } }

    for ($j = 0; $j -lt $batchIds.Count; $j++) {
      $taskId = $batchIds[$j]
      $logFile = $logFiles[$j]
      $status = if (Test-Path $statusFiles[$j]) { Get-Content $statusFiles[$j] -Raw } else { "unknown" }
      $title = Get-TaskTitleByIdYamlV1 $taskId
      Persist-TaskLog $taskId $logFile
      if ($status -match "done") {
        Scheduler-CompleteTask $taskId
        $branch = ""
        if (Test-Path $outputFiles[$j]) { $branch = ((Get-Content $outputFiles[$j] -Raw) -split '\s+')[2] }
        if ($branch) { $completedBranches += $branch }
        $completedTaskIds += $taskId
        Write-Host "  ${script:GREEN}*${script:RESET} $($title.Substring(0, [Math]::Min(45, $title.Length))) ($taskId)"
      } else {
        Scheduler-FailTask $taskId
        Write-Host "  ${script:RED}*${script:RESET} $($title.Substring(0, [Math]::Min(45, $title.Length))) ($taskId)"
        $errMsg = Extract-ErrorFromLog $logFile
        if ($errMsg) { Write-Host "${script:DIM}    Error: $errMsg${script:RESET}" }
        $failureType = "unknown"
        if ($errMsg) {
          if (Is-ExternalFailureError $errMsg) { $failureType = "external" } else { $failureType = "internal" }
        }
        Write-FailedTaskReport $taskId $title $errMsg $failureType ""
        if ($failureType -eq "external" -and -not $script:EXTERNAL_FAIL_DETECTED) {
          $script:EXTERNAL_FAIL_DETECTED = $true
          $script:EXTERNAL_FAIL_TASK_ID = $taskId
          $script:EXTERNAL_FAIL_REASON = $errMsg
        }
      }
      foreach ($f in @($statusFiles[$j], $outputFiles[$j], $logFiles[$j], $streamFiles[$j])) {
        if ($f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
      }
    }

    if ($script:EXTERNAL_FAIL_DETECTED) {
      Log-Error "External failure detected: $($script:EXTERNAL_FAIL_TASK_ID) - $($script:EXTERNAL_FAIL_REASON)"
      Print-BlockedTasks
      External-FailGracefulStop $script:EXTERNAL_FAIL_TIMEOUT
      return $false
    }

    $script:ACTIVE_PIDS = @()
    $script:ACTIVE_TASK_IDS = @()
    $script:ACTIVE_STATUS_FILES = @()
    $script:ACTIVE_LOG_FILES = @()

    if ($script:MAX_ITERATIONS -gt 0 -and $script:iteration -ge $script:MAX_ITERATIONS) {
      Log-Warn "Reached max iterations ($($script:MAX_ITERATIONS))"
      break
    }
  }

  if ($script:WORKTREE_BASE -and (Test-Path $script:WORKTREE_BASE)) {
    Remove-Item $script:WORKTREE_BASE -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($completedBranches.Count -gt 0 -and -not $script:CREATE_PR) {
    Write-Host ""
    Write-Host "${script:BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${script:RESET}"
    Write-Host "${script:BOLD}Integration Phase${script:RESET}"
    Write-Host "${script:BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${script:RESET}"
    Create-IntegrationBranch
    Write-Host ""
    Write-Host "${script:BOLD}Merging $($completedBranches.Count) branch(es) to integration...${script:RESET}"
    $mergeSuccess = $true
    for ($i = 0; $i -lt $completedBranches.Count; $i++) {
      $branch = $completedBranches[$i]
      $taskId = if ($i -lt $completedTaskIds.Count) { $completedTaskIds[$i] } else { "" }
      if (Merge-BranchWithFallback $branch $taskId) {
        Write-Host "  ${script:GREEN}*${script:RESET} $branch"
        & git branch -d $branch >$null 2>$null | Out-Null
      } else {
        Write-Host "  ${script:RED}*${script:RESET} $branch (unresolved conflict)"
        $mergeSuccess = $false
      }
    }
    if ($mergeSuccess) {
      Write-Host ""
      Write-Host "${script:BOLD}Review Phase${script:RESET}"
      if (Run-ReviewerAgent) {
        Write-Host ""
        Log-Info "Merging integration to $($script:BASE_BRANCH)..."
        & git checkout $script:BASE_BRANCH >$null 2>$null | Out-Null
        & git merge --no-edit $script:INTEGRATION_BRANCH >$null 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
          Log-Success "Integration merged to $($script:BASE_BRANCH)"
          & git branch -d $script:INTEGRATION_BRANCH >$null 2>$null | Out-Null
        } else {
          Log-Warn "Merge to base failed, integration branch preserved: $($script:INTEGRATION_BRANCH)"
        }
      } else {
        Generate-FixTasks
        Log-Warn "Review found issues. Fix tasks added to tasks.yaml"
        Log-Info "Integration branch preserved: $($script:INTEGRATION_BRANCH)"
      }
    } else {
      Log-Warn "Some merges failed. Integration branch preserved: $($script:INTEGRATION_BRANCH)"
    }
  }

  if ($script:ARTIFACTS_DIR -and (Test-Path $script:ARTIFACTS_DIR)) {
    Write-Host ""
    Log-Info "Artifacts saved to: $($script:ARTIFACTS_DIR)"
  }
  return $true
}

# ============================================
# SUMMARY
# ============================================

function Show-Summary {
  Write-Host ""
  Write-Host "${script:BOLD}============================================${script:RESET}"
  Write-Host "${script:GREEN}PRD complete!${script:RESET} Finished $($script:iteration) task(s)."
  Write-Host "${script:BOLD}============================================${script:RESET}"
  Write-Host ""
  Write-Host "${script:BOLD}>>> Cost Summary${script:RESET}"
  if ($script:AI_ENGINE -eq "cursor") {
    Write-Host "${script:DIM}Token usage not available (Cursor CLI doesn't expose this data)${script:RESET}"
    if ($script:total_duration_ms -gt 0) {
      $durSec = [int]($script:total_duration_ms / 1000)
      $durMin = [int]($durSec / 60)
      $durSecRem = $durSec % 60
      if ($durMin -gt 0) { Write-Host "Total API time: ${durMin}m ${durSecRem}s" }
      else { Write-Host "Total API time: ${durSec}s" }
    }
  } else {
    Write-Host "Input tokens:  $($script:total_input_tokens)"
    Write-Host "Output tokens: $($script:total_output_tokens)"
    Write-Host "Total tokens:  $($script:total_input_tokens + $script:total_output_tokens)"
    $cost = Calculate-Cost $script:total_input_tokens $script:total_output_tokens
    Write-Host "Est. cost:     `$$cost"
  }
  if ($script:task_branches.Count -gt 0) {
    Write-Host ""
    Write-Host "${script:BOLD}>>> Branches Created${script:RESET}"
    foreach ($branch in $script:task_branches) { Write-Host "  - $branch" }
  }
  Write-Host "${script:BOLD}============================================${script:RESET}"
}

# ============================================
# SELF-UPDATE
# ============================================

function Self-Update {
  # Temporarily allow stderr from git (PS 5.x treats it as terminating error)
  $prevPref = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    # Find the gralph installation root (two levels up from this script)
    $scriptDir = Split-Path -Parent $PSCommandPath
    $installRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
    $gitDir = Join-Path $installRoot ".git"
    if (-not (Test-Path $gitDir)) {
      Write-Host "[ERROR] Not a git installation. Re-install with:" -ForegroundColor Red
      Write-Host "  irm https://raw.githubusercontent.com/frizynn/gralph/main/install.ps1 | iex" -ForegroundColor Yellow
      exit 1
    }
    Write-Host "Updating gralph..." -ForegroundColor Cyan
    $before = (& git -C $installRoot rev-parse --short HEAD 2>$null)
    & git -C $installRoot pull --ff-only 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Host "[WARN] Fast-forward failed, resetting to origin/main..." -ForegroundColor Yellow
      & git -C $installRoot fetch origin 2>$null | Out-Null
      & git -C $installRoot reset --hard origin/main 2>$null | Out-Null
    }
    $after = (& git -C $installRoot rev-parse --short HEAD 2>$null)
    if ($before -eq $after) {
      Write-Host "[OK] Already up to date (${after})" -ForegroundColor Green
    } else {
      Write-Host "[OK] Updated ${before} -> ${after}" -ForegroundColor Green
    }
  } finally {
    $ErrorActionPreference = $prevPref
  }
}

# ============================================
# EARLY EXIT FOR HELP / VERSION / UPDATE
# ============================================

if ($args.Count -gt 0) {
  switch ($args[0]) {
    { $_ -in @('-h','--help','-help','--show-help','-show-help') } { Show-Help; exit 0 }
    { $_ -in @('--version','-version','--show-version','-show-version') } { Show-Version; exit 0 }
    '--update' { Self-Update; exit 0 }
  }
}

# ============================================
# INTERNAL MODE FOR PARALLEL AGENTS
# ============================================

if ($args.Count -gt 0 -and $args[0] -eq "--internal-run-agent-yaml-v1") {
  $taskId = $Args[1]
  $agentNum = [int]$Args[2]
  $outputFile = $Args[3]
  $statusFile = $Args[4]
  $logFile = $Args[5]
  $streamFile = $Args[6]
  $script:PRD_FILE = $Args[7]
  $script:BASE_BRANCH = $Args[8]
  $script:AI_ENGINE = $Args[9]
  $script:OPENCODE_MODEL = $Args[10]
  $script:CREATE_PR = ($Args[11] -eq "true")
  $script:PR_DRAFT = ($Args[12] -eq "true")
  $script:ORIGINAL_DIR = $Args[13]
  $script:WORKTREE_BASE = $Args[14]
  $script:ARTIFACTS_DIR = $Args[15]
  $script:MAX_RETRIES = [int]$Args[16]
  $script:RETRY_DELAY = [int]$Args[17]
  try { Run-ParallelAgentYamlV1 $taskId $agentNum $outputFile $statusFile $logFile $streamFile | Out-Null } catch { }
  exit 0
}

# ============================================
# MAIN
# ============================================

function Show-DryRunSummary {
  Write-Host ""
  Write-Host "${script:BOLD}============================================${script:RESET}"
  Write-Host "${script:BOLD}GRALPH${script:RESET} - Dry run (no execution)"
  $script:RUN_BRANCH = Get-RunBranchFromTasksYaml
  if ($script:RUN_BRANCH) { Write-Host "Run branch: ${script:CYAN}$($script:RUN_BRANCH)${script:RESET}" }
  $pendingIds = @()
  foreach ($idRaw in (Get-PendingTaskIdsYamlV1)) {
    $id = Normalize-YqScalar $idRaw
    if ($id) { $pendingIds += $id }
  }
  if ($pendingIds.Count -eq 0) {
    Log-Success "No pending tasks."
    Write-Host "${script:BOLD}============================================${script:RESET}"
    return
  }
  Log-Info "Pending tasks: $($pendingIds.Count)"
  foreach ($id in $pendingIds) {
    $title = Normalize-YqScalar (Get-TaskTitleByIdYamlV1 $id)
    if ($title) { Write-Host "  - [$id] $title" }
    else { Write-Host "  - [$id]" }
  }
  Write-Host "${script:BOLD}============================================${script:RESET}"
}

function Main {
  param([string[]]$Arguments)
  Parse-Args $Arguments
  if ($script:SKILLS_INIT) { Ensure-SkillsForEngine $script:AI_ENGINE "install"; exit 0 }
  if ($script:DRY_RUN -and $script:MAX_ITERATIONS -eq 0) { $script:MAX_ITERATIONS = 1 }
  try {
    Check-Requirements
    Ensure-SkillsForEngine $script:AI_ENGINE "warn"
    if ($script:DRY_RUN) {
      Show-DryRunSummary
      exit 0
    }
    Ensure-RunBranch
    Write-Host "${script:BOLD}============================================${script:RESET}"
    Write-Host "${script:BOLD}GRALPH${script:RESET} - Running until PRD is complete"
    $engineDisplay = switch ($script:AI_ENGINE) {
      "opencode" { "${script:CYAN}OpenCode${script:RESET}" }
      "cursor" { "${script:YELLOW}Cursor Agent${script:RESET}" }
      "codex" { "${script:BLUE}Codex${script:RESET}" }
      default { "${script:MAGENTA}Claude Code${script:RESET}" }
    }
    Write-Host "Engine: $engineDisplay"
    Write-Host "PRD: ${script:CYAN}$($script:PRD_ID)${script:RESET} ($($script:PRD_RUN_DIR))"
    $modeParts = @()
    if ($script:SKIP_TESTS) { $modeParts += "no-tests" }
    if ($script:SKIP_LINT) { $modeParts += "no-lint" }
    if ($script:DRY_RUN) { $modeParts += "dry-run" }
    if ($script:SEQUENTIAL) { $modeParts += "sequential" } else { $modeParts += "parallel:$($script:MAX_PARALLEL)" }
    if ($script:BRANCH_PER_TASK) { $modeParts += "branch-per-task" }
    if ($script:RUN_BRANCH) { $modeParts += "run-branch:$($script:RUN_BRANCH)" }
    if ($script:CREATE_PR) { $modeParts += "create-pr" }
    if ($script:MAX_ITERATIONS -gt 0) { $modeParts += "max:$($script:MAX_ITERATIONS)" }
    if ($modeParts.Count -gt 0) { Write-Host "Mode: ${script:YELLOW}$($modeParts -join ' ')${script:RESET}" }
    Write-Host "${script:BOLD}============================================${script:RESET}"
    if ($script:SEQUENTIAL) { $script:MAX_PARALLEL = 1 }
    $result = Run-ParallelTasksYamlV1
    if (-not $result) {
      Notify-Error "GRALPH stopped due to external failure or deadlock"
      exit 1
    }
    Show-Summary
    Notify-Done
    exit 0
  } finally {
    Cleanup
  }
}

Main $args
