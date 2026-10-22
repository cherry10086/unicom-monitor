$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'monitor.ps1'
$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
# Load function definitions only: no API calls, mutexes, scheduled tasks, or output writes.
foreach ($functionAst in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    Invoke-Expression $functionAst.Extent.Text
}
$script:Batch = 80
$script:BatchLimit = 100
$script:DelayMs = 0
$script:Response = $null
function Invoke-Api { return $script:Response }
function Assert-Throws([scriptblock]$Action) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw 'Expected failure, but the function reported success.' }
}
function Assert-Equal($Expected, $Actual) {
    if ($Expected -ne $Actual) { throw "Expected $Expected, got $Actual" }
}
$cases = [ordered]@{
    'Missing option lists are errors, not empty categories' = {
        $script:Response = [pscustomobject]@{ data = [pscustomobject]@{} }
        Assert-Throws { Get-ThirdLevelOptions 1 'first' 'second' }
    }
    'A real empty option list is valid' = {
        $script:Response = [pscustomobject]@{ data = [pscustomobject]@{ dataList = @() } }
        Assert-Equal 0 @(Get-ThirdLevelOptions 1 'first' 'second').Count
    }
    'Missing detail lists cannot silently drop all requested plans' = {
        $script:Response = [pscustomobject]@{ data = [pscustomobject]@{} }
        Assert-Throws { Get-PlanDetails -Ids @('a', 'b') }
    }
    'Incomplete batches must fail to protect the previous baseline' = {
        $script:Response = [pscustomobject]@{ data = [pscustomobject]@{ detailList = @([pscustomobject]@{ reportNo = 'a' }) } }
        Assert-Throws { Get-PlanDetails -Ids @('a', 'b') }
    }
    'Complete batches still return all plans' = {
        $script:Response = [pscustomobject]@{ data = [pscustomobject]@{ detailList = @(
            [pscustomobject]@{ reportNo = 'a' }, [pscustomobject]@{ reportNo = 'b' }
        ) } }
        Assert-Equal 2 @(Get-PlanDetails -Ids @('a', 'b')).Count
    }
    'Empty configured scan scopes are rejected' = {
        if (-not (Get-Command Get-ScanTariffAttributes -ErrorAction SilentlyContinue)) { throw 'Scan scope validation is missing.' }
        Assert-Throws { Get-ScanTariffAttributes @() }
        Assert-Throws { Get-ScanTariffAttributes $null }
        Assert-Throws { Get-ScanTariffAttributes @(3) }
        Assert-Throws { Get-ScanTariffAttributes @(1.5) }
        Assert-Equal 2 @(Get-ScanTariffAttributes @(2, 1)).Count
    }
}
$failed = 0
foreach ($case in $cases.GetEnumerator()) {
    try { & $case.Value; Write-Output ('PASS ' + $case.Key) }
    catch { $failed++; Write-Output ('FAIL ' + $case.Key + ': ' + $_.Exception.Message) }
}
Write-Output ('Tests: ' + $cases.Count + ', failures: ' + $failed)
if ($failed) { exit 1 }
