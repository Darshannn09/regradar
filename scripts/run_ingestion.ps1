# RegRadar: run the ingestion pipeline in order, stopping at the first failure.
# Usage (from the repo root, venv active):   .\scripts\run_ingestion.ps1
# Skip manual or pending steps with -Skip, e.g.:  .\scripts\run_ingestion.ps1 -Skip 05,06,07

param([string[]]$Skip = @("07"))   # 07 (LegiScan) is skipped until the API key arrives

$steps = Get-ChildItem ingestion\[0-9][0-9]_*.py | Sort-Object Name
foreach ($step in $steps) {
    $number = $step.Name.Substring(0, 2)
    if ($Skip -contains $number) { Write-Host "-- skipping $($step.Name)" -ForegroundColor Yellow; continue }
    Write-Host "`n== $($step.Name) ==" -ForegroundColor Cyan
    python $step.FullName
    if ($LASTEXITCODE -ne 0) { Write-Host "Stopped: $($step.Name) failed." -ForegroundColor Red; exit 1 }
}
Write-Host "`nAll steps finished. Next: run sql/03, sql/05, then sql/06 in Snowsight." -ForegroundColor Green
