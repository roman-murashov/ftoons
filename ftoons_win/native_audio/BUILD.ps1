<#
.SYNOPSIS
    Build the bundled Windows x64 decoder with Zig 0.15.2.
.EXAMPLE
    .\BUILD.ps1 -Zig 'C:\tools\zig\zig.exe' -RebuildChip
#>
[CmdletBinding()]
param([string]$Zig = 'zig', [switch]$RebuildChip)
$ErrorActionPreference = 'Stop'
$compiler = (Get-Command -Name $Zig -CommandType Application -ErrorAction Stop).Source
$flags = @('-target', 'x86_64-windows-gnu', '-O2', '-std=c++17', '-s', '-fno-sanitize=undefined')
Push-Location -LiteralPath $PSScriptRoot
try {
    if ($RebuildChip) {
        & $compiler c++ @flags -shared 'dbopl-source/dbopl.cpp' 'dbopl-source/chip_bridge.cpp' -o 'toons_dbopl.dll'
        if ($LASTEXITCODE -ne 0) { throw "DBOPL build exited with $LASTEXITCODE" }
    }
    & $compiler c++ @flags -municode main.cpp -lws2_32 -lbcrypt -o 'ftoons_audio.exe'
    if ($LASTEXITCODE -ne 0) { throw "Audio helper build exited with $LASTEXITCODE" }
} finally {
    Pop-Location
}
