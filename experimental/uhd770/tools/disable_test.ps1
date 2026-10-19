<#
.SYNOPSIS
Disable an experimental NullMoth GPU attempt in one explicit OpenCore config.
.DESCRIPTION
Backs up the supplied config, removes this test's opt-in/delay arguments, adds
-nvoff and ensures OpenCore refreshes boot-args. Does not reset firmware NVRAM,
delete drivers, format disks or modify another EFI. Boot through this exact EFI
after running the command. The existing attach guard is never cleared.
.PARAMETER ConfigPath
Literal path to the config.plist of the USB/EFI that will boot macOS.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$testConfig = (Resolve-Path -LiteralPath $ConfigPath).Path
if ([IO.Path]::GetFileName($testConfig) -ne "config.plist") {
    throw "Expected an explicit OpenCore config.plist path."
}
$testDocument = New-Object System.Xml.XmlDocument
$testDocument.PreserveWhitespace = $true
$testDocument.XmlResolver = $null
$testDocument.Load($testConfig)
$testGuid = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
$testPrefix = "/plist/dict/key[.='NVRAM']/following-sibling::*[1][self::dict]"
$testArgsPath = "$testPrefix/key[.='Add']/following-sibling::*[1][self::dict]/key[.='$testGuid']/following-sibling::*[1][self::dict]/key[.='boot-args']/following-sibling::*[1][self::string]"
$testDeletePath = "$testPrefix/key[.='Delete']/following-sibling::*[1][self::dict]/key[.='$testGuid']/following-sibling::*[1][self::array]"
$testArgsNode = $testDocument.SelectSingleNode($testArgsPath)
$testDeleteNode = $testDocument.SelectSingleNode($testDeletePath)
if ($null -eq $testArgsNode -or $null -eq $testDeleteNode) {
    throw "The expected OpenCore NVRAM Add/Delete structure is missing; nothing was written."
}
$testOldArgs = $testArgsNode.InnerText
$testWords = @($testOldArgs -split '\s+' | Where-Object {
    $_ -and $_ -notmatch '^(nmxintel|nmxdiagdelay)=' -and $_ -ne '-nvoff'
})
$testNewArgs = (($testWords + '-nvoff') -join ' ')
$testArgsNode.InnerText = $testNewArgs
if ($null -eq $testDeleteNode.SelectSingleNode("string[.='boot-args']")) {
    $testRefresh = $testDocument.CreateElement("string")
    $testRefresh.InnerText = "boot-args"
    [void]$testDeleteNode.AppendChild($testRefresh)
}
$testStamp = (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
$testBackup = "$testConfig.uhd770-$testStamp.bak"
$testTemporary = "$testConfig.uhd770-$testStamp.tmp"
Copy-Item -LiteralPath $testConfig -Destination $testBackup
$testSettings = New-Object System.Xml.XmlWriterSettings
$testSettings.Encoding = New-Object System.Text.UTF8Encoding($false)
$testSettings.NewLineChars = "`n"
$testWriter = [Xml.XmlWriter]::Create($testTemporary, $testSettings)
try { $testDocument.Save($testWriter) } finally { $testWriter.Dispose() }
$testVerify = New-Object System.Xml.XmlDocument
$testVerify.XmlResolver = $null
$testVerify.Load($testTemporary)
if ($testVerify.SelectSingleNode($testArgsPath).InnerText -ne $testNewArgs -or
    $null -eq $testVerify.SelectSingleNode("$testDeletePath/string[.='boot-args']")) {
    throw "Temporary config validation failed. Original preserved at $testBackup"
}
# Move only this validated file over the explicitly resolved target, never a tree.
Move-Item -LiteralPath $testTemporary -Destination $testConfig -Force
Write-Output "GPU test disabled in: $testConfig"
Write-Output "Backup: $testBackup"
Write-Output "Boot arguments: $testNewArgs"
Write-Output "Boot through this EFI, then choose the installed macOS entry. No NVRAM reset is needed."
