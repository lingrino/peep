# Remove log files older than N days.
param(
    [string]$Path = "./logs",
    [int]$Days = 14
)

$cutoff = (Get-Date).AddDays(-$Days)
$old = Get-ChildItem -Path $Path -Filter *.log | Where-Object { $_.LastWriteTime -lt $cutoff }

foreach ($file in $old) {
    Write-Host "Removing $($file.Name)"
    Remove-Item $file.FullName -WhatIf:$false
}
Write-Output "Removed $($old.Count) file(s)"
