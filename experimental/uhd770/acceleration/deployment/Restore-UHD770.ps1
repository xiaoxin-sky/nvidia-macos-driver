<#
Restore only this kit's matched USB config to its saved -nvoff state. The hash
and FAT32/volume-label match exclude other disks and preserve independent edits.
This never deletes files, formats a disk, changes partitions or touches macOS.
#>
[CmdletBinding()]
param([switch]$CheckOnly)
$ErrorActionPreference = "Stop"
# Use the framework hash API so recovery also works when a parent PowerShell
# installation supplied a PSModulePath that hides the Get-FileHash module.
function Get-UHD770Sha256([string]$LiteralPath) {
    $taskStream = [IO.File]::OpenRead($LiteralPath)
    $taskSha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($taskSha.ComputeHash($taskStream))).Replace("-", "").ToLowerInvariant() }
    finally { $taskStream.Dispose(); $taskSha.Dispose() }
}
$taskKit = $PSScriptRoot
$taskPlan = Get-Content -LiteralPath (Join-Path $taskKit "session-target\identity.json") -Raw | ConvertFrom-Json
$taskSaved = Join-Path $taskKit "session-target\config.safe.plist"
if ((Get-UHD770Sha256 $taskSaved) -ne $taskPlan.safe_hash) {
    throw "Saved recovery config hash mismatch."
}
$taskMatches = @()
foreach ($taskDrive in [System.IO.DriveInfo]::GetDrives()) {
    if (-not $taskDrive.IsReady -or $taskDrive.DriveFormat -ne "FAT32" -or $taskDrive.VolumeLabel -ne $taskPlan.volume_label) { continue }
    $taskConfig = Join-Path $taskDrive.RootDirectory.FullName "EFI\OC\config.plist"
    if (-not (Test-Path -LiteralPath $taskConfig -PathType Leaf)) { continue }
    if ((Get-Item -LiteralPath $taskConfig).Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    $taskDigest = Get-UHD770Sha256 $taskConfig
    if ($taskDigest -eq $taskPlan.safe_hash -or $taskDigest -eq $taskPlan.test_hash) { $taskMatches += $taskConfig }
}
if ($taskMatches.Count -ne 1) { throw "Expected exactly one matching 1401 USB; no config was changed." }
$taskTarget = $taskMatches[0]
if ($CheckOnly) {
    Write-Output "Recovery target verified without writing: $taskTarget"
    return
}
if ((Get-UHD770Sha256 $taskTarget) -eq $taskPlan.safe_hash) {
    Write-Output "USB already contains the matched -nvoff config: $taskTarget"
    return
}
$taskBackup = "$taskTarget.uhd770-before-restore-$(Get-Date -Format yyyyMMdd-HHmmss)"
if (Test-Path -LiteralPath $taskBackup) { throw "Recovery backup already exists; preserved." }
Copy-Item -LiteralPath $taskTarget -Destination $taskBackup
$taskPending = "$taskTarget.uhd770-windows-pending"
if (Test-Path -LiteralPath $taskPending) { throw "An earlier pending file exists; preserved." }
Copy-Item -LiteralPath $taskSaved -Destination $taskPending
if ((Get-UHD770Sha256 $taskPending) -ne $taskPlan.safe_hash) { throw "Recovery copy verification failed." }
Move-Item -LiteralPath $taskPending -Destination $taskTarget -Force
if ((Get-UHD770Sha256 $taskTarget) -ne $taskPlan.safe_hash) { throw "Final recovery hash verification failed." }
Write-Output "USB opt-out restored. Boot through this 1401 USB and choose macOS 15: $taskTarget"
