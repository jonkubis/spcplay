param(
    [ValidateSet("x86", "x64")]
    [string]$Arch = "x64",

    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$OutDir
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot "tools"
$sourceRootResolved = (Resolve-Path $SourceRoot).Path

if (-not (Test-Path (Join-Path $sourceRootResolved "snesapu.dll"))) {
    throw "Source root must contain snesapu.dll: $sourceRootResolved"
}

$vsDevCmd = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat"
$nasm = "C:\Program Files\NASM\nasm.exe"

if (-not (Test-Path $vsDevCmd)) {
    throw "VsDevCmd.bat not found: $vsDevCmd"
}
if (-not (Test-Path $nasm)) {
    throw "nasm.exe not found: $nasm"
}

$asmDir = Join-Path $sourceRootResolved "snesapu.dll"
$outDirResolved = [System.IO.Path]::GetFullPath($OutDir)
$objDir = Join-Path $outDirResolved "obj"

New-Item -ItemType Directory -Force -Path $outDirResolved | Out-Null
New-Item -ItemType Directory -Force -Path $objDir | Out-Null

function Invoke-CmdChecked {
    param(
        [string]$Command,
        [string]$WorkingDirectory
    )

    $cmdFile = Join-Path $env:TEMP ("codex-build-" + [guid]::NewGuid().ToString() + ".cmd")
    $stdout = Join-Path $env:TEMP ("codex-build-" + [guid]::NewGuid().ToString() + ".out.txt")
    $stderr = Join-Path $env:TEMP ("codex-build-" + [guid]::NewGuid().ToString() + ".err.txt")
    try {
        Set-Content -LiteralPath $cmdFile -Value "@echo off`r`n$Command`r`n" -Encoding ASCII
        $proc = Start-Process -FilePath "cmd.exe" `
            -ArgumentList "/d", "/c", "`"$cmdFile`"" `
            -WorkingDirectory $WorkingDirectory `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $stdout `
            -RedirectStandardError $stderr

        if (Test-Path $stdout) {
            Get-Content $stdout
        }
        if (Test-Path $stderr) {
            Get-Content $stderr
        }

        if ($proc.ExitCode -ne 0) {
            throw "Command failed with exit code $($proc.ExitCode): $Command"
        }
    } finally {
        Remove-Item $cmdFile, $stdout, $stderr -ErrorAction SilentlyContinue
    }
}

$nasmFormat = if ($Arch -eq "x64") { "win64" } else { "win32" }
$vsArch = $Arch
$toolCxxFlags = "/nologo /std:c++20 /EHsc /MT /O2 /W3 /Gz /D _CRT_SECURE_NO_WARNINGS /I `"$asmDir`""

$asmDefines = @("-DWIN32")
if ($Arch -eq "x86") {
    $asmDefines += "-DSTDCALL"
}

$asmSources = @("APU.asm", "DSP.asm", "SPC700.asm")
foreach ($asm in $asmSources) {
    $obj = Join-Path $objDir (($asm -replace "\.asm$", ".obj"))
    $defineArgs = ($asmDefines -join " ")
    Invoke-CmdChecked -WorkingDirectory $asmDir -Command "`"$nasm`" -f $nasmFormat $defineArgs -o `"$obj`" `"$asm`""
}

$toolThunkObj = $null
if ($Arch -eq "x64") {
    $toolThunkObj = Join-Path $objDir "snesapu_win64_thunks.obj"
    Invoke-CmdChecked -WorkingDirectory $toolsRoot -Command "`"$nasm`" -f win64 -o `"$toolThunkObj`" `"$toolsRoot\snesapu_win64_thunks.asm`""
} elseif ($Arch -eq "x86") {
    $toolThunkObj = Join-Path $objDir "snesapu_win32_thunks.obj"
    Invoke-CmdChecked -WorkingDirectory $toolsRoot -Command "`"$nasm`" -f win32 -o `"$toolThunkObj`" `"$toolsRoot\snesapu_win32_thunks.asm`""
}

$spc2wavObj = Join-Path $objDir "spc2wav.obj"
$spcstateObj = Join-Path $objDir "spcstate.obj"

$commonBuildPrefix = "call `"$vsDevCmd`" -host_arch=arm64 -arch=$vsArch >nul &&"

Invoke-CmdChecked -WorkingDirectory $toolsRoot -Command "$commonBuildPrefix cl $toolCxxFlags /c `"$toolsRoot\spc2wav.cpp`" /Fo`"$spc2wavObj`""
Invoke-CmdChecked -WorkingDirectory $toolsRoot -Command "$commonBuildPrefix cl $toolCxxFlags /c `"$toolsRoot\spcstate.cpp`" /Fo`"$spcstateObj`""

$coreObjs = @(
    (Join-Path $objDir "APU.obj"),
    (Join-Path $objDir "DSP.obj"),
    (Join-Path $objDir "SPC700.obj")
)

$spc2wavExe = Join-Path $outDirResolved "spc2wav.exe"
$spcstateExe = Join-Path $outDirResolved "spcstate.exe"

$extraLinkObjs = @()
if ($toolThunkObj) {
    $extraLinkObjs += $toolThunkObj
}

$spc2wavLinkInputs = @($spc2wavObj) + $extraLinkObjs + $coreObjs
$spcstateLinkInputs = @($spcstateObj) + $extraLinkObjs + $coreObjs

Invoke-CmdChecked -WorkingDirectory $outDirResolved -Command ($commonBuildPrefix + " link /nologo /out:`"$spc2wavExe`" " + (($spc2wavLinkInputs | ForEach-Object { "`"$_`"" }) -join " "))
Invoke-CmdChecked -WorkingDirectory $outDirResolved -Command ($commonBuildPrefix + " link /nologo /out:`"$spcstateExe`" " + (($spcstateLinkInputs | ForEach-Object { "`"$_`"" }) -join " "))

Write-Host "Built:"
Write-Host "  $spc2wavExe"
Write-Host "  $spcstateExe"
