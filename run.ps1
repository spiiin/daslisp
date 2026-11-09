param(
    [string]$Daslang = $env:DASLANG_EXE,
    [switch]$Test,
    [switch]$Bench,
    [int]$Repeat = 3,
    [int]$FixedIterations = 200,
    [string]$BenchmarkOutput,
    [string]$MalRoot,
    [string]$Eval,
    [string]$Script,
    [switch]$Batch,
    [switch]$Read,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$LispArgs = @()
)
$ErrorActionPreference = 'Stop'

if (-not $Daslang) {
    $installed = Get-Command daslang -ErrorAction SilentlyContinue
    if ($installed) { $Daslang = $installed.Source }
}
if (-not $Daslang) {
    $candidates = @(
        (Join-Path $PSScriptRoot '../daScript/bin/Release/daslang.exe'),
        (Join-Path $PSScriptRoot '../daslang-0.6.5-RC2/sdk/daslang_bundle/bin/daslang.exe')
    )
    $Daslang = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $Daslang) { throw 'Set DASLANG_EXE or pass -Daslang with the path to daslang.exe (0.6.5-RC2 or newer).' }
$Daslang = (Get-Command $Daslang -ErrorAction Stop).Source
$entry = Join-Path $PSScriptRoot 'main.das'

if ($Test) {
    $output = @(& $Daslang (Join-Path $PSScriptRoot 'tests/test_lisp.das') 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    if ($code -ne 0 -or ($output -join "`n") -notmatch 'PASS: \d+ checks') { throw 'Lisp regression tests failed.' }
    $tailOutput = @(& $Daslang (Join-Path $PSScriptRoot 'tests/test_tails.das') 2>&1 | ForEach-Object { "$_" })
    $tailCode = $LASTEXITCODE
    $tailOutput | ForEach-Object { Write-Host $_ }
    if ($tailCode -ne 0 -or ($tailOutput -join "`n") -notmatch 'PASS: \d+ tail checks') { throw 'List-tail regression tests failed.' }
    $bufferOutput = @(& $Daslang (Join-Path $PSScriptRoot 'tests/test_buffers.das') 2>&1 | ForEach-Object { "$_" })
    $bufferCode = $LASTEXITCODE
    $bufferOutput | ForEach-Object { Write-Host $_ }
    if ($bufferCode -ne 0 -or ($bufferOutput -join "`n") -notmatch 'PASS: \d+ buffer checks') { throw 'Buffer regression tests failed.' }
    $rootOutput = @(& $Daslang (Join-Path $PSScriptRoot 'tests/test_apply_roots.das') 2>&1 | ForEach-Object { "$_" })
    $rootCode = $LASTEXITCODE
    $rootOutput | ForEach-Object { Write-Host $_ }
    if ($rootCode -ne 0 -or ($rootOutput -join "`n") -notmatch 'PASS: \d+ apply-root checks') { throw 'Apply-root regression tests failed.' }
    & python (Join-Path $PSScriptRoot 'tools/test_cli.py') --daslang $Daslang
    if ($LASTEXITCODE -ne 0) { throw 'CLI tests failed.' }
    & python (Join-Path $PSScriptRoot 'tools/test_runner.py')
    if ($LASTEXITCODE -ne 0) { throw 'MAL runner regression tests failed.' }
    if ($MalRoot) {
        & python (Join-Path $PSScriptRoot 'tools/test_mal.py') --daslang $Daslang --mal $MalRoot --self-host
        if ($LASTEXITCODE -ne 0) { throw 'Upstream MAL tests failed.' }
    }
    if (-not $Bench) { return }
}

if ($Bench) {
    if (-not $MalRoot) { throw 'Benchmarking requires -MalRoot with a kanaka/mal checkout.' }
    if (-not $BenchmarkOutput) { $BenchmarkOutput = Join-Path $PSScriptRoot '.work/benchmarks.json' }
    & python (Join-Path $PSScriptRoot 'tools/bench_mal.py') --daslang $Daslang --mal $MalRoot --repeat $Repeat --fixed-iterations $FixedIterations --output $BenchmarkOutput
    if ($LASTEXITCODE -ne 0) { throw 'MAL benchmarks did not complete successfully; see the JSON report.' }
    return
}

$arguments = @($entry)
if ($PSBoundParameters.ContainsKey('Eval')) { $arguments += @('--', '--eval', $Eval) }
elseif ($Script) { $arguments += @('--', $Script) + $LispArgs }
elseif ($Read) { $arguments += @('--', '--read') }
elseif ($Batch) { $arguments += @('--', '--batch') }
& $Daslang @arguments
if ($LASTEXITCODE -ne 0) { throw "Lisp exited with code $LASTEXITCODE." }
