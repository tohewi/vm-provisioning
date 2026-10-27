BeforeAll {
    $script:Loop = Join-Path (Split-Path $PSScriptRoot -Parent) 'ralph' 'Invoke-RalphLoop.ps1'

    # Fake agent: records the prompt it received and ticks the first open plan item.
    $script:FakeAgent = Join-Path $TestDrive 'fake-agent.ps1'
    @'
param([string]$Flag, [string]$Prompt)
Add-Content -Path $env:RALPH_TEST_PROMPTS -Value ("---PROMPT---`n" + $Prompt)
$plan = Get-Content $env:RALPH_TEST_PLAN
$done = $false
$plan = foreach ($line in $plan) {
    if (-not $done -and $line -match '^- \[ \]') { $done = $true; $line -replace '^- \[ \]', '- [x]' } else { $line }
}
Set-Content -Path $env:RALPH_TEST_PLAN -Value $plan
if ($env:RALPH_TEST_PROMISE) { Write-Output '<promise>COMPLETE</promise>' }
'@ | Set-Content $FakeAgent

    $script:Prompt = Join-Path $TestDrive 'PROMPT.md'
    'Do the next thing.' | Set-Content $Prompt
}

Describe 'Invoke-RalphLoop.ps1' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $Work | Out-Null
        $script:Plan = Join-Path $Work 'IMPLEMENTATION_PLAN.md'
        "# Plan`n- [ ] one`n- [ ] two`n- [x] done" | Set-Content $Plan
        $env:RALPH_TEST_PLAN = $Plan
        $env:RALPH_TEST_PROMPTS = Join-Path $Work 'prompts.log'
        $env:RALPH_TEST_PROMISE = ''
        Push-Location $Work
        $script:Common = @{
            AgentCommand   = $FakeAgent
            AgentArguments = @('-p', '{prompt}')
            PromptFile     = $Prompt
            PlanFile       = $Plan
            LogDirectory   = Join-Path $Work '.ralph'
            NoCommit       = $true
        }
    }

    AfterEach {
        Pop-Location
        Remove-Item Env:RALPH_TEST_PLAN, Env:RALPH_TEST_PROMPTS, Env:RALPH_TEST_PROMISE -ErrorAction SilentlyContinue
    }

    It 'loops until every plan item is checked' {
        $r = & $Loop @Common -MaxIterations 5 -Validate { $global:LASTEXITCODE = 0 } -InformationAction SilentlyContinue

        $r.Status | Should -Be 'Complete'
        $r.Iterations | Should -Be 2
        $r.OpenItems | Should -Be 0
        (Get-Content $env:RALPH_TEST_PROMPTS -Raw) | Should -Match 'Do the next thing'
    }

    It 'stops when the agent prints the completion promise' {
        $env:RALPH_TEST_PROMISE = '1'
        $r = & $Loop @Common -MaxIterations 5 -Validate { $global:LASTEXITCODE = 0 } -InformationAction SilentlyContinue

        $r.Status | Should -Be 'Complete'
        $r.Iterations | Should -Be 1
    }

    It 'feeds validation failures into the next prompt and never completes while red' {
        $r = & $Loop @Common -MaxIterations 2 -Validate { throw 'BUILD-IS-RED' } -InformationAction SilentlyContinue -WarningAction SilentlyContinue

        $r.Status | Should -Be 'MaxIterations'
        $prompts = (Get-Content $env:RALPH_TEST_PROMPTS -Raw) -split '---PROMPT---' | Where-Object { $_.Trim() }
        $prompts[0] | Should -Not -Match 'Previous iteration failed validation'
        $prompts[1] | Should -Match 'Previous iteration failed validation'
        $prompts[1] | Should -Match 'BUILD-IS-RED'
    }

    It 'treats a non-zero exit code from validation as a failure' {
        $r = & $Loop @Common -MaxIterations 1 -Validate { $global:LASTEXITCODE = 1 } -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        $r.Status | Should -Be 'MaxIterations'
    }

    It 'refuses to run on the main branch' {
        & git init --quiet -b main $Work
        { & $Loop @Common -MaxIterations 1 -Validate { } } | Should -Throw '*Refusing*main*'
    }
}
