$exportDir = "$PSScriptRoot\export"
$outputFile = [Environment]::GetFolderPath("Desktop") + "\OceanWaves_Setup.bat"

$zipPath = "$env:TEMP\ow_pkg.zip"
Compress-Archive -Path "$exportDir\*" -DestinationPath $zipPath -Force
$zipBytes = [System.IO.File]::ReadAllBytes($zipPath)
$b64 = [Convert]::ToBase64String($zipBytes)
Remove-Item $zipPath

$batchHead = @'
@echo off
setlocal
set "OUT=%TEMP%\OceanWaves"
if exist "%OUT%" rmdir /s /q "%OUT%"
mkdir "%OUT%"
set "ME=%~f0"
powershell -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$b=[System.IO.File]::ReadAllText('%ME%');$m=$b.IndexOf('__PAYLOAD__');$d=$b.Substring($m+11).Trim();$z='%OUT%\pkg.zip';[System.IO.File]::WriteAllBytes($z,[Convert]::FromBase64String($d));Add-Type -A System.IO.Compression.FileSystem;[System.IO.Compression.ZipFile]::ExtractToDirectory($z,'%OUT%');Remove-Item $z"
start "" "%OUT%\OceanWaves.exe"
exit
__PAYLOAD__
'@

$finalContent = $batchHead + $b64
[System.IO.File]::WriteAllText($outputFile, $finalContent, [System.Text.Encoding]::ASCII)
Write-Host "Done: $outputFile ($([math]::Round($finalContent.Length/1MB, 1)) MB)"
