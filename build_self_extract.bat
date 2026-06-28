@echo off
setlocal enabledelayedexpansion
set "TARGET=%TEMP%\OceanWaves"
if exist "%TARGET%" rmdir /s /q "%TARGET%"
mkdir "%TARGET%"
powershell -Command "Add-Type -AssemblyName System.IO.Compression.FileSystem; $marker='--EOF-BINARY--'; $content=[System.IO.File]::ReadAllBytes('%~f0'); $markerBytes=[System.Text.Encoding]::ASCII.GetBytes($marker); for($i=0;$i -lt $content.Length - $markerBytes.Length;$i++){ $found=$true; for($j=0;$j -lt $markerBytes.Length;$j++){ if($content[$i+$j] -ne $markerBytes[$j]){ $found=$false; break } } if($found){ $zipStart=$i+$markerBytes.Length+2; $zipData=$content[$zipStart..($content.Length-1)]; $zipPath='%TARGET%\package.zip'; [System.IO.File]::WriteAllBytes($zipPath, $zipData); [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, '%TARGET%'); Remove-Item $zipPath; break } }"
start "" "%TARGET%\OceanWaves.exe"
exit
--EOF-BINARY--
