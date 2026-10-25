$ErrorActionPreference = 'Stop'
$sourceDir = $PSScriptRoot
$outDir = Split-Path -Parent $sourceDir
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$wpf = Join-Path $framework 'WPF'
$references = @('System.dll','System.Core.dll','System.Xaml.dll') | ForEach-Object { '/r:' + (Join-Path $framework $_) }
$references += @('PresentationCore.dll','PresentationFramework.dll','WindowsBase.dll') | ForEach-Object { '/r:' + (Join-Path $wpf $_) }
$resources = @(('/resource:' + (Join-Path $sourceDir 'Theme.xaml') + ',Theme.xaml'), ('/resource:' + (Join-Path $sourceDir 'f75.ico') + ',f75.ico'))
$sources = @('Device.cs','Json.cs','Layout.cs','Model.cs','Native.cs','SelfTest.cs','App.cs') | ForEach-Object { Join-Path $sourceDir $_ }
& (Join-Path $framework 'csc.exe') /nologo /target:winexe /platform:x64 /optimize+ ('/win32icon:' + (Join-Path $sourceDir 'f75.ico')) ('/out:' + (Join-Path $outDir 'F75 Studio.exe')) @references @resources @sources
if ($LASTEXITCODE -ne 0) { throw 'Compilation failed' }
& (Join-Path $framework 'csc.exe') /nologo /target:exe /platform:x64 /optimize+ ('/win32icon:' + (Join-Path $sourceDir 'f75.ico')) ('/out:' + (Join-Path $outDir 'F75 Diagnostics.exe')) @references @resources @sources
if ($LASTEXITCODE -ne 0) { throw 'Diagnostics compilation failed' }
# Workstation GC without the background GC thread: less memory and no extra thread for this small app.
Copy-Item (Join-Path $sourceDir 'app.config') (Join-Path $outDir 'F75 Studio.exe.config') -Force
Write-Output 'Built F75 Studio.exe and F75 Diagnostics.exe'
