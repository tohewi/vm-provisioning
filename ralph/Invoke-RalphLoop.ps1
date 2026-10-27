<#
.SYNOPSIS
    Runs a "Ralph loop": the same prompt is fed to a coding agent repeatedly, with the
    repository build/test suite as back-pressure between iterations.

.DESCRIPTION
    Each iteration:
      1. Sends ralph/PROMPT.md (plus the previous validation failure, if any) to the agent CLI.
      2. Runs the validation command (default: ./build.ps1) as back-pressure.
      3. On success, commits the iteration locally (unless -NoCommit). Nothing is ever pushed.
      4. Stops when the plan has no unchecked items and validation passes, when the agent
         prints the completion promise, or when -MaxIterations is reached.

    The agent CLI is configurable. Defaults to the GitHub Copilot CLI:
        copilot -p "<prompt>" --allow-all-tools
    Use the token {prompt} in -AgentArguments where the prompt text should be inserted.

    Logs are written to .ralph/ (git-ignored). Agent transcripts can contain anything the
    agent printed, so never commit them.

.EXAMPLE
    ./ralph/Invoke-RalphLoop.ps1 -MaxIterations 5

.EXAMPLE
    ./ralph/Invoke-RalphLoop.ps1 -AgentCommand claude -AgentArguments '-p', '{prompt}', '--dangerously-skip-permissions'
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 200)]
    [int]$MaxIterations = 10,

    [string]$AgentCommand = 'copilot',

    [string[]]$AgentArguments = @('-p', '{prompt}', '--allow-all-tools'),

    [string]$PromptFile = (Join-Path $PSScriptRoot 'PROMPT.md'),

    [string]$PlanFile = (Join-Path $PSScriptRoot 'IMPLEMENTATION_PLAN.md'),

    # Script block used as back-pressure. Must throw or set a non-zero $LASTEXITCODE on failure.
    [scriptblock]$Validate = { & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..' 'build.ps1') },

    [string]$LogDirectory = (Join-Path $PSScriptRoot '..' '.ralph'),

    [string]$CompletionPromise = '<promise>COMPLETE</promise>',

    # Do not create local commits after green iterations.
    [switch]$NoCommit,

    # Allow running on main/master (off by default: run loops on a feature branch).
    [switch]$AllowMainBranch
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Set-StrictMode -Version Latest

function Get-OpenPlanItemCount {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    @(Select-String -Path $Path -Pattern '^\s*[-*]\s+\[ \]' -AllMatches).Count
}

function Test-InGitRepository {
    $null = & git rev-parse --is-inside-work-tree 2>$null
    return $LASTEXITCODE -eq 0
}

if (-not (Test-Path $PromptFile)) { throw "Prompt file not found: $PromptFile" }
if (-not (Get-Command $AgentCommand -ErrorAction SilentlyContinue)) {
    throw "Agent CLI '$AgentCommand' not found. Install it or pass -AgentCommand."
}

$inGit = Test-InGitRepository
if ($inGit -and -not $AllowMainBranch) {
    $branch = "$(& git symbolic-ref --short HEAD 2>$null)".Trim()
    if ($branch -in 'main', 'master') {
        throw "Refusing to run a Ralph loop on '$branch'. Create a feature branch or pass -AllowMainBranch."
    }
}

New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
$failureFile = Join-Path $LogDirectory 'last-validation-failure.log'
Remove-Item $failureFile -ErrorAction SilentlyContinue

$status = 'MaxIterations'
$iteration = 0
for ($iteration = 1; $iteration -le $MaxIterations; $iteration++) {
    Write-Information "===== Ralph iteration $iteration/$MaxIterations ====="

    $prompt = Get-Content $PromptFile -Raw
    if (Test-Path $failureFile) {
        $prompt += "`n`n## Previous iteration failed validation`nFix this before anything else. Output (tail):`n````n" +
            ((Get-Content $failureFile -Tail 80) -join "`n") + "`n````n"
    }

    $agentArgs = @($AgentArguments | ForEach-Object { $_.Replace('{prompt}', $prompt) })
    $agentLog = Join-Path $LogDirectory ("iteration-{0:D3}-agent.log" -f $iteration)
    $global:LASTEXITCODE = 0
    $agentOutput = & $AgentCommand @agentArgs 2>&1 | Tee-Object -FilePath $agentLog | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Agent exited with code $LASTEXITCODE (see $agentLog)."
    }

    $validationLog = Join-Path $LogDirectory ("iteration-{0:D3}-validation.log" -f $iteration)
    Set-Content -Path $validationLog -Value '' -NoNewline
    $validated = $true
    try {
        $global:LASTEXITCODE = 0
        & $Validate *>&1 | Tee-Object -FilePath $validationLog | Out-Null
        if ($LASTEXITCODE -ne 0) { $validated = $false }
    }
    catch {
        $_ | Out-String | Add-Content -Path $validationLog
        $validated = $false
    }

    if (-not $validated) {
        Copy-Item $validationLog $failureFile -Force
        Write-Warning "Validation failed in iteration $iteration; the next iteration will be asked to fix it."
        continue
    }
    Remove-Item $failureFile -ErrorAction SilentlyContinue

    if ($inGit -and -not $NoCommit) {
        & git add -A
        & git diff --cached --quiet
        if ($LASTEXITCODE -ne 0) {
            & git commit --quiet -m "ralph: iteration $iteration" | Out-Null
            Write-Information "Committed iteration $iteration."
        }
    }

    $open = Get-OpenPlanItemCount -Path $PlanFile
    Write-Information "Validation passed. Open plan items: $open."
    if ($agentOutput.Contains($CompletionPromise) -or $open -eq 0) {
        $status = 'Complete'
        break
    }
}

[pscustomobject]@{
    Status     = $status
    Iterations = [Math]::Min($iteration, $MaxIterations)
    OpenItems  = Get-OpenPlanItemCount -Path $PlanFile
    Logs       = (Resolve-Path $LogDirectory).Path
}
