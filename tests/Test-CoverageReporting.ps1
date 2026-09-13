#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$reporter = Join-Path $root 'scripts' 'coverage' 'New-GoCoverageReport.ps1'
$workflowPath = Join-Path $root '.github' 'workflows' 'ci.yml'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'pitcrew-coverage-tests-' + [guid]::NewGuid().ToString('N'))
$errors = [Collections.Generic.List[string]]::new()
$checks = 0

function Add-Check {
    param(
        [object]$Condition,
        [string]$Failure
    )

    $script:checks++
    if (-not [bool]$Condition) {
        $script:errors.Add($Failure)
    }
}

function Add-ThrowsCheck {
    param(
        [scriptblock]$Action,
        [string]$ExpectedMessage,
        [string]$Failure
    )

    $script:checks++
    try {
        & $Action
        $script:errors.Add("$Failure No error was thrown.")
    } catch {
        if ($_.Exception.Message -notmatch $ExpectedMessage) {
            $script:errors.Add(
                "$Failure Expected '$ExpectedMessage', got '$($_.Exception.Message)'.")
        }
    }
}

function Write-CoverageFixture {
    param(
        [string]$ModuleRoot,
        [string]$ModulePath,
        [string]$ProfilePath,
        [string]$SourceName,
        [string]$Source,
        [string[]]$Blocks
    )

    New-Item -ItemType Directory -Path $ModuleRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $ModuleRoot 'go.mod') -Encoding utf8NoBOM `
        -Value "module $ModulePath`n`ngo 1.25.3`n"
    Set-Content -LiteralPath (Join-Path $ModuleRoot $SourceName) -Encoding utf8NoBOM `
        -Value $Source
    Set-Content -LiteralPath $ProfilePath -Encoding utf8NoBOM `
        -Value (@('mode: set') + $Blocks)
}

try {
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    $admissionRoot = Join-Path $temporaryRoot 'manager' 'admission'
    $autoscalerRoot = Join-Path $temporaryRoot 'manager' 'autoscaler'
    $admissionProfile = Join-Path $temporaryRoot 'admission.out'
    $autoscalerProfile = Join-Path $temporaryRoot 'autoscaler.out'
    $reportPath = Join-Path $temporaryRoot 'coverage.md'
    $changedPath = Join-Path $temporaryRoot 'changed.txt'

    Write-CoverageFixture `
        -ModuleRoot $admissionRoot `
        -ModulePath 'example.test/manager/admission' `
        -ProfilePath $admissionProfile `
        -SourceName 'coordinator.go' `
        -Source @'
package admission

func Covered() int {
	return 1
}

func Uncovered() int {
	return 0
}
'@ `
        -Blocks @(
            'example.test/manager/admission/coordinator.go:3.20,5.2 2 1',
            'example.test/manager/admission/coordinator.go:7.22,9.2 2 0'
        )

    Write-CoverageFixture `
        -ModuleRoot $autoscalerRoot `
        -ModulePath 'example.test/manager/autoscaler' `
        -ProfilePath $autoscalerProfile `
        -SourceName 'scaler.go' `
        -Source @'
package autoscaler

func Scale() int {
	return 2
}
'@ `
        -Blocks @(
            'example.test/manager/autoscaler/scaler.go:3.18,5.2 6 1'
        )

    Set-Content -LiteralPath $changedPath -Encoding utf8NoBOM -Value @(
        'manager/admission/coordinator.go',
        'manager/autoscaler/scaler.go',
        'manager/manage-runners.sh',
        'docs/index.md'
    )

    Add-Check (Test-Path -LiteralPath $reporter -PathType Leaf) (
        'The Go coverage reporter script is missing.')

    if (Test-Path -LiteralPath $reporter -PathType Leaf) {
        & $reporter `
            -ProjectRoot $temporaryRoot `
            -AdmissionProfile $admissionProfile `
            -AutoscalerProfile $autoscalerProfile `
            -ChangedFilesPath $changedPath `
            -OutputPath $reportPath

        $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8
        Add-Check ($report -match '\| Admission \| 2 / 4 \| 50\.0% \|') (
            'Admission coverage was not calculated from statements.')
        Add-Check ($report -match '\| Autoscaler \| 6 / 6 \| 100\.0% \|') (
            'Autoscaler coverage was not calculated from statements.')
        Add-Check ($report -match '\| Combined \| 8 / 10 \| 80\.0% \|') (
            'Combined coverage was not weighted by statement count.')
        Add-Check ($report -match 'Uncovered.*0\.0%') (
            'The lowest-covered function was not reported.')
        Add-Check ($report -match 'coordinator\.go.*50\.0%') (
            'The lowest-covered file was not reported.')
        Add-Check (
            $report -match 'manager/admission/coordinator\.go' -and
            $report -match 'manager/autoscaler/scaler\.go' -and
            $report -notmatch 'manager/manage-runners\.sh' -and
            $report -notmatch 'docs/index\.md'
        ) 'Changed-file reporting did not retain only required-module Go files.'
        Add-Check (
            $report -match
                'PowerShell and shell coverage is not fabricated\.' -and
            $report -match 'normal contract tests remain required'
        ) 'The report did not state the PowerShell and shell coverage boundary.'
        Add-Check (
            [Text.Encoding]::UTF8.GetByteCount($report) -le 49152
        ) 'The generated report exceeded the bounded job-output budget.'

        Add-ThrowsCheck {
            & $reporter `
                -ProjectRoot $temporaryRoot `
                -AdmissionProfile (Join-Path $temporaryRoot 'missing.out') `
                -AutoscalerProfile $autoscalerProfile `
                -OutputPath $reportPath
        } 'Coverage profile.*does not exist' (
            'The reporter accepted a missing required profile.')

        $malformedProfile = Join-Path $temporaryRoot 'malformed.out'
        Set-Content -LiteralPath $malformedProfile -Encoding utf8NoBOM -Value @(
            'mode: set',
            'not a coverage block'
        )
        Add-ThrowsCheck {
            & $reporter `
                -ProjectRoot $temporaryRoot `
                -AdmissionProfile $malformedProfile `
                -AutoscalerProfile $autoscalerProfile `
                -OutputPath $reportPath
        } 'Malformed coverage profile' (
            'The reporter accepted a malformed coverage profile.')

        $wrongModuleProfile = Join-Path $temporaryRoot 'wrong-module.out'
        Set-Content -LiteralPath $wrongModuleProfile -Encoding utf8NoBOM -Value @(
            'mode: set',
            'example.test/manager/other/file.go:1.1,1.2 1 1'
        )
        Add-ThrowsCheck {
            & $reporter `
                -ProjectRoot $temporaryRoot `
                -AdmissionProfile $wrongModuleProfile `
                -AutoscalerProfile $autoscalerProfile `
                -OutputPath $reportPath
        } 'did not measure required module' (
            'The reporter accepted a profile for an unmeasured required module.')
    }

    $workflow = Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8
    Add-Check (
        $workflow -notmatch
            '(?m)^\s{6}COVERAGE_DIRECTORY:\s*\$\{\{\s*runner\.'
    ) 'CI uses the runner context in a job-level coverage environment value.'
    Add-Check (
        $workflow -match
            'go test -covermode=atomic -coverprofile=.*admission' -and
        $workflow -match
            'go test -covermode=atomic -coverprofile=.*autoscaler'
    ) 'CI does not produce both coverage profiles in the existing contracts job.'
    Add-Check (
        $workflow -match
            '(?m)^\s+run: \./tests/Test-CoverageReporting\.ps1\r?$'
    ) 'CI does not require the coverage reporter and workflow contract test.'
    Add-Check (
        $workflow -match
            '(?m)^\s+run: node --test \./tests/Test-CoverageComment\.mjs\r?$'
    ) 'CI does not execute the coverage comment publisher tests.'
    Add-Check (
        $workflow -match 'GITHUB_STEP_SUMMARY' -and
        $workflow -match 'report_b64'
    ) 'CI does not publish the Markdown summary and bounded base64 job output.'
    Add-Check (
        $workflow -match '(?m)^  coverage-comment:' -and
        $workflow -match '(?m)^    permissions:\r?\n      pull-requests: write' -and
        $workflow -match
            'github\.event\.pull_request\.head\.repo\.full_name == github\.repository'
    ) 'The comment job is not least-privilege and same-repository gated.'
    Add-Check (
        $workflow -notmatch 'actions/(upload|download)-artifact'
    ) 'The coverage workflow introduced a forbidden GitHub artifact action.'
    $commentJob = [regex]::Match(
        $workflow,
        '(?ms)^  coverage-comment:\r?\n(?<job>.*?)^  docker-integration:'
    ).Groups['job'].Value
    Add-Check (
        $commentJob -and
        $commentJob -match "needs\.validation-plan\.outputs\.scope == 'full'" -and
        $commentJob -match 'persist-credentials: false' -and
        $commentJob -match
            'sparse-checkout: scripts/coverage/Upsert-GoCoverageComment\.cjs' -and
        $commentJob -match
            "require\('\./scripts/coverage/Upsert-GoCoverageComment\.cjs'\)"
    ) 'The privileged comment job is not narrowly wired to the tested publisher.'
    Add-Check (
        $workflow -match '(?m)^        coverage-comment,\r?$' -and
        $workflow -match 'COMMENT_RESULT' -and
        $workflow -match 'Coverage comment publication'
    ) 'The stable CI check does not gate required same-repository comment publication.'
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "$($errors.Count) of $checks coverage reporting checks failed."
}

Write-Host "All $checks coverage reporting checks passed."
