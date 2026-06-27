param(
    [ValidateSet("auto", "xsim", "verilator")]
    [string]$Sim = "auto",

    [ValidateSet("core", "wrapper")]
    [string]$Tb = "core",

    [switch]$Clean,
    [switch]$NoRun,
    [switch]$Trace
)

$ErrorActionPreference = "Stop"

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$Top = if ($Tb -eq "core") { "rms_norm_tb" } else { "rms_norm_wrapper_tb" }
$TbRel = if ($Tb -eq "core") { "sim\rms_norm_tb.sv" } else { "sim\rms_norm_wrapper_tb.sv" }
$TbFile = Join-Path $Root $TbRel
$Manifest = Join-Path $Root "sim\sources.f"

function Test-Tool {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Add-Vivado-To-Path {
    $VivadoRoot = "C:\Xilinx\Vivado"
    if ((Test-Tool "xvlog") -or !(Test-Path -LiteralPath $VivadoRoot)) {
        return
    }

    $VivadoBin = Get-ChildItem -LiteralPath $VivadoRoot -Directory |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName "bin" } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_ "xvlog.bat") } |
        Select-Object -First 1

    if ($VivadoBin) {
        $env:PATH = "$VivadoBin;$env:PATH"
    }
}

Add-Vivado-To-Path

if ($Sim -eq "auto") {
    if ((Test-Tool "xvlog") -and (Test-Tool "xelab") -and (Test-Tool "xsim")) {
        $Sim = "xsim"
    } elseif (Test-Tool "verilator") {
        $Sim = "verilator"
    } else {
        throw "Neither XSIM (xvlog/xelab/xsim) nor Verilator is available on PATH."
    }
}

$Build = Join-Path $Root "build\sim\$Sim\$Top"
if ($Clean -and (Test-Path -LiteralPath $Build)) {
    Remove-Item -LiteralPath $Build -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $Build | Out-Null

$GoldenMem = Join-Path $Root "scripts\golden_mem"
if (Test-Path -LiteralPath $GoldenMem) {
    Copy-Item -Path (Join-Path $GoldenMem "*.mem") -Destination $Build -Force
} else {
    Write-Warning "No scripts\golden_mem directory found. File-based tests may fail until vectors are generated."
}

$Sources = Get-Content -LiteralPath $Manifest |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") } |
    ForEach-Object { Join-Path $Root ($_ -replace "/", [IO.Path]::DirectorySeparatorChar) }

$IncludeDirs = @(
    $Root,
    (Join-Path $Root "precision_lib\floating_point"),
    (Join-Path $Root "precision_lib\bfloat16")
)

Push-Location $Build
try {
    if ($Sim -eq "xsim") {
        $IncArgs = @()
        foreach ($Dir in $IncludeDirs) {
            $IncArgs += @("-i", $Dir)
        }

        Write-Host "[run_tb] Compiling $Top with XSIM..."
        & xvlog -sv --work work @IncArgs @Sources $TbFile -log (Join-Path $Build "xvlog.log")
        if ($LASTEXITCODE -ne 0) { throw "xvlog failed. See $Build\xvlog.log" }

        $Snapshot = "${Top}_snapshot"
        & xelab -debug typical "work.$Top" -s $Snapshot -log (Join-Path $Build "xelab.log")
        if ($LASTEXITCODE -ne 0) { throw "xelab failed. See $Build\xelab.log" }

        if (!$NoRun) {
            Write-Host "[run_tb] Running $Top with XSIM..."
            & xsim $Snapshot -R -log (Join-Path $Build "xsim.log")
            if ($LASTEXITCODE -ne 0) { throw "xsim failed. See $Build\xsim.log" }
        }
    } else {
        $IncArgs = @()
        foreach ($Dir in $IncludeDirs) {
            $IncArgs += "-I$Dir"
        }

        $ObjDir = Join-Path $Build "obj_dir"
        $TraceArgs = if ($Trace) { @("--trace") } else { @() }

        Write-Host "[run_tb] Building $Top with Verilator..."
        & verilator --binary --timing --top-module $Top --Mdir $ObjDir -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE @TraceArgs @IncArgs @Sources $TbFile
        if ($LASTEXITCODE -ne 0) { throw "verilator build failed." }

        if (!$NoRun) {
            $Exe = Join-Path $ObjDir "V$Top"
            if (Test-Path -LiteralPath "$Exe.exe") { $Exe = "$Exe.exe" }
            if (!(Test-Path -LiteralPath $Exe)) { throw "Built Verilator executable not found: $Exe" }
            Write-Host "[run_tb] Running $Top with Verilator..."
            & $Exe
            if ($LASTEXITCODE -ne 0) { throw "Verilator simulation failed." }
        }
    }
} finally {
    Pop-Location
}

Write-Host "[run_tb] Done. Run directory: $Build"
