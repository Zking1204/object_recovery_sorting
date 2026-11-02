# 仿真验证

## 一、一句话跑法

```powershell
powershell -ExecutionPolicy Bypass -File .\sim\run_all.ps1
```

若 Vivado 不在默认路径，加 `-VivadoBin "D:\Xilinx\Vivado\2026.1\bin"`；
只想跑某一个，加 `-Only dd_pair`。日志落在 `_sim/` 下。

---

## 二、判据怎么读

**不能用退出码判成败**。`xsim` 在 `$finish` 之后**恒返回 0**，超时退出也是 0。

所以 `run_all.ps1` 改成读日志内容：

| 判据 | 匹配 |
|---|---|
| 失败 | `FAIL` / `[ERR]` / `HAS FAILURES` / `ERROR:` / `超时` / `Timeout` |
| 通过 | `PASS` / `ALL PASS` / **`全部通过`** |
| 比对计数 | `checks=` / `比对` / `条检查` / `项全部通过` / `mismatch` |

**为什么必须查比对计数**：只有"通过"标记、没有比对次数的日志，意味着测试跑完了但一条都没比过——等于没验。这种记作 `PASS?`，要人工看。

★ 注意：`tb_dd_shadow.v` 与 `tb_dd_pair_v4.v` 的成功标记是**纯中文 `*** 全部通过 ***`**，没有 ASCII `PASS`。只 grep 英文会误判成"无结论"。

---

## 三、逐条手工跑（不想用脚本时）

设 `V` = Vivado 的 `bin` 目录，`S` = `src/rtl`，`T` = `sim`，工作目录 `_sim`。

```bat
:: 普通 Verilog
%V%\xvlog.bat %S%\dd_sobel.v %T%\tb_dd_sobel.v
%V%\xelab.bat tb_dd_sobel -s sim_sobel
%V%\xsim.bat  sim_sobel -R -log sim_sobel.log

:: SystemVerilog（tb_servo_pwm.sv 用了 input string / task automatic / 层次引用）
%V%\xvlog.bat -sv %S%\servo_ch.v %S%\servo_pwm.v %T%\tb_servo_pwm.sv
%V%\xelab.bat tb_servo_pwm -debug typical -s sim_servo
%V%\xsim.bat  sim_servo -R -log sim_servo.log
```

- **顶层名 = 文件名去掉扩展名**。
- `xelab` 快照名每个 TB 必须不同，串行跑共用 `xsim.dir/` 不会冲突。
- 全部 TB 的 `timescale` 都是 `1ns/1ps`，模块名唯一，可以一次性 `xvlog` 全部源文件。

---

## 四、覆盖对照表（如实列，含空白）

| 被测模块 | testbench | 覆盖方式 |
|---|---|---|
| `dd_gray` | `tb_dd_gray.v` | **⚠️ 待同步**：该 TB 按旧版"灰度化"语义写，与现行"24 位逐位透传"不匹配，复现时**请跳过**（见第五节第 3 条） |
| `dd_pair` | `tb_dd_pair_v4.v`（主）、`tb_dd_pair_frames.v`、`_frames_big`、`_long`、`_real` | 直接，5 组不同规模 |
| `dd_shadow` | `tb_dd_shadow.v` | 直接（抗阴影三判据 + 旁路回归） |
| `dd_win3x3` | `tb_dd_win3x3.v` | 直接 |
| `dd_median3` | `tb_dd_median3.v` | 直接 |
| `dd_thresh` | `tb_dd_thresh.v` | 直接（含极性） |
| `dd_morph` | `tb_dd_morph.v` | 直接 |
| `dd_sobel` | `tb_dd_sobel.v` | 直接 |
| `dd_osd` | `tb_dd_osd.v` | 直接 |
| `dd_osd_axis` | `tb_dd_osd_axis.v` | 直接（AXI-Lite 读写 + AXIS 时序） |
| `servo_pwm`（含 `servo_ch`） | `tb_servo_pwm.sv` | 直接（三路时间参数 + 排队 + 周期边界锁存） |
| `dd_font_rom` | — | **间接**：经 `tb_dd_osd` / `tb_dd_osd_axis` 带到 |
| `servo_ch` | — | **间接**：经 `tb_servo_pwm` 带到 |
| `defect_detect` | **无专用 TB** | 通过 7 个 `dd_*` 单元 TB 分别验证各级 |
| `glass_defect_core_v2` | **无专用 TB** | BD 顶层，靠上板实测 + 寄存器回读验证 |
| `size_detect` | **无专用 TB** | 扩展模块，不在判决链上 |

**未覆盖的三个模块如实说明**：两个顶层（`defect_detect`、`glass_defect_core_v2`）的正确性由"各级单元 TB 全绿 + 上板实测数据"共同支撑，而不是由顶层 TB 支撑。

---

## 五、三个已知的测试台弱点（重建者需要知道）

1. **8 个 TB 没有超时保护**：`tb_dd_gray`、`tb_dd_thresh`、`tb_dd_osd`、`tb_dd_shadow`、`tb_dd_pair_v4`、`tb_dd_pair_frames`、`_frames_big`、`_long`、`_real`。若 DUT 卡死，仿真会一直跑下去。批量跑时请自行加超时上限。
2. **`tb_dd_osd_axis` 的用例 E 用用例 C 抓到的 DUT 输出当参考**（自引用，不是独立 oracle）。它能验证"第二次写与第一次行为一致"，但不能证明第一次就对——第一次的正确性由 `tb_dd_osd.v` 的独立黄金模型保证。
3. **`tb_dd_gray.v` 与现行实现不匹配**：该 TB 按 2026-10-21 之前的"2:4:1 灰度化"版本编写（输出声明为 8 位、黄金模型算灰度值），而现行 `dd_gray.v` 已改为 **24 位彩色逐位透传**，灰度与色度后移到 `dd_shadow` 现算。两者语义不同 ⇒ 批量跑会失败，**复现时请跳过该 TB**；这一级的正确性由下游各级 TB 与上板实测覆盖。

## 六、耗时提示

`tb_dd_pair_real`（约 2100 万拍）与 `tb_servo_pwm`（1 MHz 时基，单个 PWM 周期 20000 拍）明显比其它慢，批量跑请留足时间。
