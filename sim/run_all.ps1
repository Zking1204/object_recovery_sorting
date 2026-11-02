#Requires -Version 5.1
<#
=============================================================================
 run_all.ps1 —— 批量跑本包全部 testbench，输出一张通过/失败汇总表

 用法（在 Windows PowerShell 里，不需要已打开 Vivado）：
     powershell -ExecutionPolicy Bypass -File .\sim\run_all.ps1
     powershell -ExecutionPolicy Bypass -File .\sim\run_all.ps1 -VivadoBin "D:\Xilinx\Vivado\2026.1\bin"

 判据说明（重要）：
   xsim 在 $finish 之后**恒返回 0**，超时退出也是 0，所以退出码不能用来判成败。
   本脚本改为读日志内容：
     失败特征： FAIL / [ERR] / HAS FAILURES / ERROR: / 超时 / Timeout
     通过特征： PASS / ALL PASS / 全部通过
   并且要求日志里出现"比对次数"（checks= / 比对 / 条检查 / 项全部通过），
   否则判为"空验证"（测试跑完但一条都没比对，等于没验）。
=============================================================================
#>
[CmdletBinding()]
param(
    [string]$VivadoBin = '',
    [string]$WorkDir   = '',
    [string]$Only      = ''      # 只跑名字里含该子串的 TB
)

$ErrorActionPreference = 'Stop'
$simDir = $PSScriptRoot
$pkg    = Split-Path $simDir -Parent
$rtlDir = Join-Path $pkg 'src\rtl'

if (-not $VivadoBin) {
    # 依次尝试：环境变量 XILINX_VIVADO → PATH 上的 xvlog.bat → 常见安装位置
    $cand = @()
    if ($env:XILINX_VIVADO) { $cand += (Join-Path $env:XILINX_VIVADO 'bin') }
    $xc = Get-Command xvlog.bat -ErrorAction SilentlyContinue
    if ($xc) { $cand += (Split-Path $xc.Source -Parent) }
    foreach ($v in @('2026.1','2025.2')) {
        $cand += "C:\Xilinx\Vivado\$v\bin"
        $cand += "D:\Xilinx\Vivado\$v\bin"
    }
    foreach ($c in $cand) { if ($c -and (Test-Path (Join-Path $c 'xvlog.bat'))) { $VivadoBin = $c; break } }
}
if (-not $WorkDir)   { $WorkDir   = Join-Path $pkg '_sim' }
if (-not (Test-Path (Join-Path $VivadoBin 'xvlog.bat'))) {
    throw "找不到 xvlog.bat：$VivadoBin。请用 -VivadoBin 指定 Vivado 的 bin 目录。"
}
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)

# TB -> 需要的 RTL 源文件（不含 .v 后缀），以及是否 SystemVerilog
$cases = @(
    @{ top='tb_dd_gray';           srcs=@('dd_gray');                              sv=$false },
    @{ top='tb_dd_pair_v4';        srcs=@('dd_pair');                              sv=$false },
    @{ top='tb_dd_pair_frames';    srcs=@('dd_pair');                              sv=$false },
    @{ top='tb_dd_pair_frames_big';srcs=@('dd_pair');                              sv=$false },
    @{ top='tb_dd_pair_long';      srcs=@('dd_pair');                              sv=$false },
    @{ top='tb_dd_pair_real';      srcs=@('dd_pair');                              sv=$false },
    @{ top='tb_dd_shadow';         srcs=@('dd_shadow');                            sv=$false },
    @{ top='tb_dd_win3x3';         srcs=@('dd_win3x3');                            sv=$false },
    @{ top='tb_dd_median3';        srcs=@('dd_median3');                           sv=$false },
    @{ top='tb_dd_thresh';         srcs=@('dd_thresh');                            sv=$false },
    @{ top='tb_dd_morph';          srcs=@('dd_morph');                             sv=$false },
    @{ top='tb_dd_sobel';          srcs=@('dd_sobel');                             sv=$false },
    @{ top='tb_dd_osd';            srcs=@('dd_font_rom','dd_osd');                 sv=$false },
    @{ top='tb_dd_osd_axis';       srcs=@('dd_font_rom','dd_osd','dd_osd_axis');   sv=$false },
    @{ top='tb_servo_pwm';         srcs=@('servo_ch','servo_pwm');                 sv=$true  }
)

$failPat = 'FAIL|\[ERR\]|HAS FAILURES|ERROR:|超时|Timeout'
$passPat = 'PASS|ALL PASS|全部通过'
$chkPat  = 'checks\s*=|比对|条检查|项全部通过|mismatch'

$results = @()

foreach ($c in $cases) {
    if ($Only -and ($c.top -notlike "*$Only*")) { continue }

    $tbFile = $null
    foreach ($ext in @('.v', '.sv')) {
        $p = Join-Path $simDir ($c.top + $ext)
        if (Test-Path $p) { $tbFile = $p; break }
    }
    if (-not $tbFile) { $results += [pscustomobject]@{ TB=$c.top; Result='MISSING'; Detail='找不到 TB 文件' }; continue }

    $srcFiles = @()
    $missing  = @()
    foreach ($s in $c.srcs) {
        $p = Join-Path $rtlDir ($s + '.v')
        if (Test-Path $p) { $srcFiles += $p } else { $missing += $s }
    }
    if ($missing.Count -gt 0) {
        $results += [pscustomobject]@{ TB=$c.top; Result='MISSING'; Detail=('缺 RTL: ' + ($missing -join ',')) }
        continue
    }

    $log = Join-Path $WorkDir ($c.top + '.log')
    if (Test-Path $log) { Remove-Item $log -Force }
    Push-Location $WorkDir
    try {
        # 1) 编译
        $xargs = @()
        if ($c.sv) { $xargs += '-sv' }
        $xargs += $srcFiles
        $xargs += $tbFile
        & (Join-Path $VivadoBin 'xvlog.bat') @xargs *> ($log + '.xvlog.txt')
        if ($LASTEXITCODE -ne 0) {
            $results += [pscustomobject]@{ TB=$c.top; Result='COMPILE_FAIL'; Detail='见 ' + (Split-Path ($log+'.xvlog.txt') -Leaf) }
            continue
        }

        # 2) 精化
        $snap = 'sim_' + $c.top
        $eargs = @($c.top, '-s', $snap)
        if ($c.sv) { $eargs = @($c.top, '-debug', 'typical', '-s', $snap) }
        & (Join-Path $VivadoBin 'xelab.bat') @eargs *> ($log + '.xelab.txt')
        if ($LASTEXITCODE -ne 0) {
            $results += [pscustomobject]@{ TB=$c.top; Result='ELAB_FAIL'; Detail='见 ' + (Split-Path ($log+'.xelab.txt') -Leaf) }
            continue
        }

        # 3) 仿真
        & (Join-Path $VivadoBin 'xsim.bat') $snap -R -log $log *> ($log + '.xsim.txt')

        if (-not (Test-Path $log)) {
            $results += [pscustomobject]@{ TB=$c.top; Result='NO_LOG'; Detail='xsim 没产生日志' }
            continue
        }
        $txt = [IO.File]::ReadAllText($log, $utf8)

        $hasFail = [regex]::IsMatch($txt, $failPat)
        $hasPass = [regex]::IsMatch($txt, $passPat)
        $hasChk  = [regex]::IsMatch($txt, $chkPat)

        if ($hasFail)      { $res = 'FAIL' }
        elseif ($hasPass -and $hasChk) { $res = 'PASS' }
        elseif ($hasPass)  { $res = 'PASS?' }        # 有通过标记但没有比对计数，需人工看
        else               { $res = 'NO_VERDICT' }   # 既没 PASS 也没 FAIL

        $results += [pscustomobject]@{ TB=$c.top; Result=$res; Detail=$log }
    }
    finally { Pop-Location }
}

Write-Host ''
Write-Host '================ 仿真汇总 ================'
$results | Format-Table -AutoSize TB, Result, Detail
$bad = $results | Where-Object { $_.Result -ne 'PASS' }
Write-Host ''
if ($bad.Count -eq 0) {
    Write-Host '全部 PASS。' -ForegroundColor Green
} else {
    Write-Host ("需要人工确认的有 " + $bad.Count + " 项：") -ForegroundColor Yellow
    foreach ($b in $bad) { Write-Host ("  - " + $b.TB + " : " + $b.Result) }
}
