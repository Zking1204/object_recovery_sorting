###########################################################################
# 物品回收智能分拣系统 · 板端 PS 侧脚本（提交包副本，逻辑与板端运行版本一致，仅加本注释块）
# 文件   ：servo.py
# 角色   ：舵机 PWM 的 AXI-Lite 驱动 ServoKick（三路独立参数下发与 KICK 触发）
# 依赖   ：无
# 启动   ：按钮②末步、按钮④（勾选启用分拣时）
###########################################################################
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
servo.py —— PS 侧舵机驱动（2026-10-26 新增）

【它做什么】把"踢一脚"这件事传给 PL：
    写一次 KICK 寄存器 → 硬件自己走完
        延时 T_DLY  →  转到 ACT 脉宽(60°)  →  保持 T_ACT  →  线性斜坡 T_RET 回中位
    PS 完全不用管时间，哪怕 PS 卡顿/被打断，硬件也会自己把舵机送回中位。

【为什么时间逻辑在 PL 而不在这】PS 侧计时会被主循环周期（≈60 ms）量化，而且一旦
    循环里出现异常（Jupyter 中断、CNN 卡住），导流板会永远歪着。放硬件里没这个问题。

【接口】与 track.py 解耦：本类只提供 kick(ch)，track.py 通过构造函数注入它，
        所以 track.py 依然不依赖任何硬件，可以脱板做单元测试。

【用法】必须先把新位流加载好（cam_full.py），然后：
    %run servo.py
    sv = ServoKick()          # 打开 0x43C40000，写入生产参数，最后使能
    sv.status()               # 打印当前状态（ID / 各路实际脉宽 / 忙标志）
    sv.kick(0)                # 踢通道 0 一次（can 用）

【寄存器表】见 servo_pwm.v 文件头，基址 0x43C40000。
"""

import time                                   # 只用 sleep 做演示等待
from pynq import MMIO                         # 访问 AXI-Lite 寄存器

# ============ 硬件地址 ============
SERVO_BASE  = 0x43C40000                      # BD 里给 servo_pwm_0 分配的地址
SERVO_RANGE = 0x1000                          # 4KB 窗口
ID_EXPECT   = 0x53525630                      # "SRV0"：读一次就能确认总线通、位流是新的

# ============ 寄存器偏移（与 servo_pwm.v 一一对应）============
R_ID      = 0x00                             # 只读固定值
R_CTRL    = 0x04                             # bit0 总使能 / bit1 测试模式
R_PW0A    = 0x08                             # 通道0 偏转脉宽 µs
R_PW1A    = 0x0C                             # 通道1 偏转脉宽 µs
R_PW2A    = 0x10                             # 通道2 偏转脉宽 µs
R_PW0I    = 0x14                             # 通道0 中位脉宽 µs
R_PW1I    = 0x18                             # 通道1 中位脉宽 µs
R_PW2I    = 0x1C                             # 通道2 中位脉宽 µs
R_TDLY    = 0x20                             # 偏转延时 ms
R_TACT    = 0x24                             # 偏转保持 ms
R_TRET    = 0x28                             # 恢复斜坡 ms
R_KICK    = 0x2C                             # 写 bit n=1 ⇒ 通道 n 动作一次
R_STATUS  = 0x30                             # bit[2:0] 忙 / bit[5:3] 延时段
R_PWMIN   = 0x34                             # 限幅下限 µs
R_PWMAX   = 0x38                             # 限幅上限 µs
R_CNT     = 0x3C                             # 周期计数器（调试）
R_PW0EFF  = 0x40                             # 通道0 实际输出脉宽 µs
R_PW1EFF  = 0x44                             # 通道1 实际输出脉宽 µs
R_PW2EFF  = 0x48                             # 通道2 实际输出脉宽 µs
# ★ 2026-10-29 新增：三路各自独立的时间参数（需要位流是带 per-time 的那一版）
#   写 0x20/0x24/0x28（全局）⇒ 三路一起变（老行为）；写下面 9 个 ⇒ 只改对应那一路
R_TDLY0 = 0x4C                               # 通道0 偏转延时 ms
R_TDLY1 = 0x50                               # 通道1 偏转延时 ms
R_TDLY2 = 0x54                               # 通道2 偏转延时 ms
R_TACT0 = 0x58                               # 通道0 偏转保持 ms
R_TACT1 = 0x5C                               # 通道1 偏转保持 ms
R_TACT2 = 0x60                               # 通道2 偏转保持 ms
R_TRET0 = 0x64                               # 通道0 恢复斜坡 ms
R_TRET1 = 0x68                               # 通道1 恢复斜坡 ms
R_TRET2 = 0x6C                               # 通道2 恢复斜坡 ms

# ============ 生产参数（本项目实测标定值）============
PW_IDLE = 1500                               # 中位脉宽 µs（舵机居中）
PW_ACT  = 2000                               # ★ 实测：2000 µs 对应约 60° 偏转
T_DLY   = 2000                               # 偏转延时 2000 ms（物体从触发线走到导流板）
T_ACT   = 3000                               # 偏转保持 3000 ms（物体通过，用户定的"等 3 秒"）
T_RET   = 500                                # 恢复斜坡 500 ms（平滑回中位，减小冲击）
PW_MIN  = 1000                               # 限幅下限 µs（别打满，SG90 会撞限位堵转）
PW_MAX  = 2000                               # 限幅上限 µs（= 已标定的 60° 位置）


class ServoKick:
    """三路舵机驱动：只负责"配置 + 踢一脚"，动作时序由 PL 硬件完成"""

    def __init__(self, base=SERVO_BASE, pw_act=PW_ACT, hold_ms=None):
        # ---- 1. 打开寄存器窗口（绝不重新 Overlay：那会把 PL 重新编程、相机链路当场失效）----
        self.ip = MMIO(base, SERVO_RANGE)                     # 只映射，不重新配置 PL
        stamp = self.ip.read(R_ID)                            # 读自检 ID
        if stamp != ID_EXPECT:                                # 不是 0x53525630 ⇒ 位流不对
            raise RuntimeError("servo_pwm ID 不符: 0x%08X（期望 0x%08X）——"
                               "板上位流不是带舵机的那一版" % (stamp, ID_EXPECT))
        # ---- 2. 写入生产参数 ----
        self.ip.write(R_PWMIN, PW_MIN)                        # 先写限幅（后面的脉宽都按它夹）
        self.ip.write(R_PWMAX, PW_MAX)                        # 上限 = 标定好的 60°
        for base_off in (R_PW0I, R_PW1I, R_PW2I):             # 三路中位
            self.ip.write(base_off, PW_IDLE)                  # 都是 1500
        for base_off in (R_PW0A, R_PW1A, R_PW2A):             # 三路偏位
            self.ip.write(base_off, pw_act)                   # 都是标定出来的 2000
        self.ip.write(R_TDLY, T_DLY)                          # 延时 2 s
        self.ip.write(R_TACT, T_ACT)                          # 保持 3 s
        self.ip.write(R_TRET, T_RET)                          # 斜坡 0.5 s
        if hold_ms is not None:                               # 允许临时改保持时间
            self.ip.write(R_TACT, int(hold_ms) & 0xFFFF)      #   只改保持
        # ---- 3. 最后才使能（复位默认是关的，舵机不受力，最安全）----
        self.ip.write(R_CTRL, 1)                              # CTRL=1：正常 PWM，三路都在中位
        self.n_kick = 0                                       # 统计：一共踢了几次
        time.sleep(0.2)                                       # 等一下让 PWM 稳定

    # ---------------------------------------------------------------- 动作
    def kick(self, ch):
        """踢一脚：让第 ch 路（0/1/2）走一次「延时→偏转→保持→斜坡回中位」"""
        if ch < 0 or ch > 2:                                  # 越界保护
            return False                                      # 不动作
        self.ip.write(R_KICK, 1 << ch)                        # 写对应 bit，硬件自清零
        self.n_kick += 1                                      # 计数
        return True                                           # 成功

    def kick_many(self, mask):
        """按位掩码一次踢多路（bit0=通道0 …）"""
        self.ip.write(R_KICK, mask & 0x7)                     # 只保留低 3 位
        self.n_kick += 1                                      # 计数

    # ---------------------------------------------------------------- 参数
    def set_times(self, dly_ms=None, act_ms=None, ret_ms=None):
        """运行时改三个时间（毫秒）；传 None 的项保持不变"""
        if dly_ms is not None:                                # 改延时
            T_DLY_local = int(dly_ms) & 0xFFFF                #   截成 16 位
            self.ip.write(R_TDLY, T_DLY_local)                #   写入
        if act_ms is not None:                                # 改保持
            self.ip.write(R_TACT, int(act_ms) & 0xFFFF)       #   写入
        if ret_ms is not None:                                # 改恢复斜坡
            self.ip.write(R_TRET, int(ret_ms) & 0xFFFF)       #   写入

    def set_angles(self, act_us=None, idle_us=None):
        """运行时改偏转/中位脉宽（µs）；传 None 的项保持不变
           ★ 注意：这个是**三路一起改**。要单独改某一路用 set_angles_ch(ch, ...)"""
        if act_us is not None:                                # 改偏位
            for base_off in (R_PW0A, R_PW1A, R_PW2A):        #   三路一起改
                self.ip.write(base_off, int(act_us) & 0xFFF)  #   12 位截取
        if idle_us is not None:                               # 改中位
            for base_off in (R_PW0I, R_PW1I, R_PW2I):        #   三路一起改
                self.ip.write(base_off, int(idle_us) & 0xFFF) #   12 位截取

    # ---------------------------------------------------------------- 单路参数
    _R_TDLY = (R_TDLY0, R_TDLY1, R_TDLY2)        # 三路"偏转延时"寄存器偏移
    _R_TACT = (R_TACT0, R_TACT1, R_TACT2)        # 三路"偏转保持"寄存器偏移
    _R_TRET = (R_TRET0, R_TRET1, R_TRET2)        # 三路"恢复斜坡"寄存器偏移
    _R_PWA  = (R_PW0A, R_PW1A, R_PW2A)           # 三路"偏转脉宽"寄存器偏移
    _R_PWI  = (R_PW0I, R_PW1I, R_PW2I)           # 三路"中位脉宽"寄存器偏移

    def set_times_ch(self, ch, dly_ms=None, act_ms=None, ret_ms=None):
        """★ 只改**第 ch 路**（0/1/2）的三个时间；传 None 的项保持不变
           为什么要有这个：三只舵机装的导流板位置、离分拣线的距离都不一样，
           需要的延时/保持/斜坡各不相同，全局一套必然对不上。"""
        ch = int(ch)                                          # 通道号
        if not (0 <= ch <= 2):                                # 越界直接报
            raise ValueError("通道号只能是 0/1/2，收到 %r" % (ch,))
        if dly_ms is not None:                                # 改这一路的延时
            self.ip.write(self._R_TDLY[ch], int(dly_ms) & 0xFFFF)
        if act_ms is not None:                                # 改这一路的保持
            self.ip.write(self._R_TACT[ch], int(act_ms) & 0xFFFF)
        if ret_ms is not None:                                # 改这一路的恢复斜坡
            self.ip.write(self._R_TRET[ch], int(ret_ms) & 0xFFFF)

    def set_angles_ch(self, ch, act_us=None, idle_us=None):
        """★ 只改**第 ch 路**的偏转/中位脉宽（µs）；传 None 的项保持不变"""
        ch = int(ch)                                          # 通道号
        if not (0 <= ch <= 2):                                # 越界直接报
            raise ValueError("通道号只能是 0/1/2，收到 %r" % (ch,))
        if act_us is not None:                                # 改这一路的偏位
            self.ip.write(self._R_PWA[ch], int(act_us) & 0xFFF)
        if idle_us is not None:                               # 改这一路的中位
            self.ip.write(self._R_PWI[ch], int(idle_us) & 0xFFF)

    def get_times_ch(self, ch):
        """★ 回读**第 ch 路**实际生效的三个时间 → (延时ms, 保持ms, 斜坡ms)
           用来上板核对"我写进去的值是不是真的落在这一路上"。"""
        ch = int(ch)                                          # 通道号
        if not (0 <= ch <= 2):                                # 越界直接报
            raise ValueError("通道号只能是 0/1/2，收到 %r" % (ch,))
        return (self.ip.read(self._R_TDLY[ch]),               # 偏转延时
                self.ip.read(self._R_TACT[ch]),               # 偏转保持
                self.ip.read(self._R_TRET[ch]))               # 恢复斜坡

    def times_table(self):
        """★ 打印三路时间的对照表（调试一眼看全）"""
        rows = [self.get_times_ch(c) for c in (0, 1, 2)]      # 三路各读一次
        print("  通道   延时ms   保持ms   斜坡ms", flush=True)  # 表头
        for c, (d, a, r) in enumerate(rows):                   # 逐路打印
            print("   ch%d %8d %8d %8d" % (c, d, a, r), flush=True)
        return rows                                            # 顺手返回原始值

    # ---------------------------------------------------------------- 状态
    def pw_eff(self):
        """返回三路**实际输出**的脉宽（已限幅），用来核对"""
        return (self.ip.read(R_PW0EFF), self.ip.read(R_PW1EFF), self.ip.read(R_PW2EFF))

    def status(self):
        """打印当前状态"""
        st = self.ip.read(R_STATUS)                           # 状态字
        print("servo: ID=0x%08X  PW=(%d,%d,%d)  busy=0x%02X  累计踢 %d 次"
              % (self.ip.read(R_ID), self.ip.read(R_PW0EFF), self.ip.read(R_PW1EFF),
                 self.ip.read(R_PW2EFF), st, self.n_kick), flush=True)
        return st                                             # 返回状态字

    def demo(self, ch=0, gap=1.0):
        """演示：踢一路并打印全过程，用来肉眼确认动作时序"""
        self.kick(ch)                                         # 踢一脚
        t0 = time.time()                                      # 计时起点
        while time.time() - t0 < 8.0:                         # 最多看 8 秒
            time.sleep(gap)                                   # 隔一段看一次
            print('  %4.1fs  PW=(%d,%d,%d)  STATUS=0x%02X'
                  % (time.time() - t0, self.ip.read(R_PW0EFF), self.ip.read(R_PW1EFF),
                     self.ip.read(R_PW2EFF), self.ip.read(R_STATUS)), flush=True)
            if (self.ip.read(R_STATUS) & 0x07) == 0 and time.time() - t0 > 1.0:
                print('  (动作结束，已回中位)', flush=True)
                break                                     # 忙位清零 ⇒ 结束


# ---- 自动建一个实例（%run 后直接用 sv，和 cnn_pl_infer.py 的 clf_pl 一个风格）----
#   ★ 为什么要自动建：少了这一步，osd.py 里 `servo=globals().get('sv')` 会拿到 None，
#     分拣整段代码静默不执行，而且**不报任何错** —— 非常难查。
try:
    sv = ServoKick()                                      # 打开 0x43C40000 + 写生产参数 + 使能
    print("舵机就绪：中位 %d µs / 偏转 %d µs(约 60°) / 延时 %d ms / 保持 %d ms / 斜坡 %d ms"
          % (PW_IDLE, PW_ACT, T_DLY, T_ACT, T_RET), flush=True)
    print("           三路实际脉宽 = %s   busy=0x%02X"
          % (str(sv.pw_eff()), sv.ip.read(R_STATUS)), flush=True)
except Exception as _e:                                   # 位流不对 / 没加载
    sv = None                                             # 置空 ⇒ osd_live 退化成"不分拣"
    print("!! 舵机初始化失败：%s —— 确认位流是带 servo_pwm 的那版（0x43C40000）" % _e, flush=True)
