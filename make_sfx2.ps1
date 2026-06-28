$ErrorActionPreference = 'Stop'

$exportDir = "$PSScriptRoot\export"
$desktop = [Environment]::GetFolderPath("Desktop")
$configFile = "$desktop\ow_conf.txt"
$dataFile = "$desktop\ow_data.7z"
$outputExe = "$desktop\OceanWaves.exe"
$sfxModule = "$desktop\7zSD.sfx"
$sevenZip = "C:\Program Files\7-Zip\7z.exe"

# Create config
@"
;!@Install@!UTF-8!
Title="OceanWaves"
BeginPrompt=""
RunProgram="OceanWaves.exe"
;!@InstallEnd@!
"@ | Out-File -FilePath $configFile -Encoding ASCII

# Create 7z archive
& $sevenZip a -t7z -mx=5 $dataFile "$exportDir\*" 2>&1 | Out-Null

# Combine: SFX + config + archive
[System.IO.File]::WriteAllBytes($outputExe, [System.IO.File]::ReadAllBytes($sfxModule))
[System.IO.File]::AppendAllText($outputExe, [System.IO.File]::ReadAllText($configFile))
$dataBytes = [System.IO.File]::ReadAllBytes($dataFile)
$fs = [System.IO.File]::OpenWrite($outputExe)
$fs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
$fs.Write($dataBytes, 0, $dataBytes.Length)
$fs.Close()

Remove-Item $configFile, $dataFile
Write-Host "Done: $outputExe ($([math]::Round((Get-Item $outputExe).Length/1MB, 1)) MB)"
