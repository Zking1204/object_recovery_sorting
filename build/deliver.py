# -*- coding: utf-8 -*-
"""
deliver.py —— 交付步骤：给 .hwh 打 FCLK0 分频补丁，并把上板要用的两个文件整理到一起

为什么必须打这个补丁
--------------------
PS7 的 FCLK_CLK0 分频在 block design 里是**派生参数，改 BD 不生效**，导出 .hwh 时
永远是 4/4 ⇒ PL 实际只跑 **62.5 MHz**。现象是：**屏幕全黑，但 PS 侧的 SCCB、VDMA
状态、寄存器回读全部正常**，极难定位。

补丁值（4→10、4→1）是把"已交付且实测可行的 .hwh"与新生成的逐参数 diff 出来的，
不是猜的。

用法
----
    python deliver.py                                   # 自动在工程目录里找 hwh 与 bit
    python deliver.py --proj-dir D:\\objrs_build
    python deliver.py --hwh <design_1.hwh> --bit <design_1_wrapper.bit> --out <目录>

参数默认取环境变量：
    OBJRS_PROJ_DIR   工程目录（与 create_project.tcl / build_bitstream.tcl 一致）
    OBJRS_OUT        位流所在目录（默认 <工程目录>/_bit）

产物：<out>/design_1_wrapper.bit 与 <out>/design_1_wrapper.hwh（已打补丁），
      这两个文件再加上 src/ps/ 里的 .py 与 data/ 里的模型 bin，就是上板要上传的全部文件。
"""
import argparse
import glob
import hashlib
import os
import re
import shutil
import sys

PATCHES = [
    ("PCW_FCLK0_PERIPHERAL_DIVISOR0", "4", "10"),
    ("PCW_FCLK0_PERIPHERAL_DIVISOR1", "4", "1"),
]


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest().upper()


def find_file(root, name, prefer=None):
    """在 root 下递归找一个文件，优先返回 prefer 目录里的、其次取最新修改的。"""
    if not root or not os.path.isdir(root):
        return None
    cands = glob.glob(os.path.join(root, "**", name), recursive=True)
    if not cands:
        return None
    if prefer:
        pre = [c for c in cands if os.path.normcase(prefer) in os.path.normcase(c)]
        if pre:
            cands = pre
    cands.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return cands[0]


def main():
    pkg_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--proj-dir", default=os.environ.get("OBJRS_PROJ_DIR")
                    or os.path.join(pkg_root, "_build", "project"),
                    help="Vivado 工程目录（默认取 OBJRS_PROJ_DIR）")
    ap.add_argument("--out", default=os.environ.get("OBJRS_OUT") or None,
                    help="产物输出目录（默认 <工程目录>/_deliver）")
    ap.add_argument("--hwh", default=None, help="手工指定 design_1.hwh")
    ap.add_argument("--bit", default=None, help="手工指定 design_1_wrapper.bit")
    args = ap.parse_args()

    proj = os.path.abspath(args.proj_dir)
    out_dir = os.path.abspath(args.out) if args.out else os.path.join(proj, "_deliver")
    bit_dir = os.environ.get("OBJRS_OUT") or os.path.join(proj, "_bit")

    print("工程目录 : %s" % proj)
    print("输出目录 : %s" % out_dir)

    # --- 1. 找源文件 ------------------------------------------------------
    src_hwh = args.hwh or find_file(proj, "design_1.hwh")
    src_bit = args.bit or find_file(proj, "design_1_wrapper.bit", prefer=bit_dir)

    if not src_hwh:
        print("ABORT 在 %s 下找不到 design_1.hwh" % proj)
        print("      先跑 build_bitstream.tcl（它会生成 BD 输出产物，含 .hwh）")
        return 1
    if not src_bit:
        print("ABORT 在 %s 下找不到 design_1_wrapper.bit" % proj)
        print("      先跑 build_bitstream.tcl 出位流")
        return 1

    print("SRC hwh : %s  (%d B)" % (src_hwh, os.path.getsize(src_hwh)))
    print("SRC bit : %s  (%d B)" % (src_bit, os.path.getsize(src_bit)))

    # --- 2. 打补丁（latin-1 逐字节保真，不破坏原有编码）-------------------
    with open(src_hwh, "rb") as f:
        data = f.read().decode("latin-1")

    ok = True
    for name, old, new in PATCHES:
        pat = re.compile(r'(<PARAMETER\b[^>]*\bNAME="%s"[^>]*\bVALUE=")%s(")'
                         % (re.escape(name), re.escape(old)))
        data, hits = pat.subn(lambda m: m.group(1) + new + m.group(2), data)
        print("PATCH %-40s %s -> %-3s hits=%d" % (name, old, new, hits))
        if hits == 0:
            ok = False

    if not ok:
        print("")
        print("ABORT 有补丁没命中，.hwh 不写盘。常见原因：")
        print("  * 这份 .hwh 已经被打过补丁了（值已经是 10 / 1）——那就不用再打，直接拷贝即可")
        print("  * .hwh 版本与预期不符，先人工 grep 一下 PCW_FCLK0_PERIPHERAL_DIVISOR")
        return 1

    # --- 3. 复核补丁结果 --------------------------------------------------
    for name, old, new in PATCHES:
        if not re.search(r'NAME="%s"[^>]*VALUE="%s"' % (re.escape(name), re.escape(new)), data):
            print("ABORT 补丁后复核失败：%s 的值不是 %s" % (name, new))
            return 1
    print("CHECK 两个分频参数复核通过（10 / 1）")

    # --- 4. 落盘 ----------------------------------------------------------
    os.makedirs(out_dir, exist_ok=True)
    dst_hwh = os.path.join(out_dir, "design_1_wrapper.hwh")
    dst_bit = os.path.join(out_dir, "design_1_wrapper.bit")
    with open(dst_hwh, "wb") as f:
        f.write(data.encode("latin-1"))
    shutil.copy2(src_bit, dst_bit)

    print("")
    for p in (dst_bit, dst_hwh):
        print("OUT  %s\n     %d B  md5=%s" % (p, os.path.getsize(p), md5(p)))
    print("")
    print("DELIVER_OK —— 上板需要上传的文件：")
    print("   1) %s" % dst_bit)
    print("   2) %s" % dst_hwh)
    print("   3) src/ps/ 下 11 个 .py")
    print("   4) data/ 下 model_blob.bin / model_bias.bin / model_mmult.bin / model_mshift.bin / golden_in.bin")
    print("   5) data/model_int8_64.tflite（仅 PS 回退路径用）")
    print("   清单与目标目录见 board/upload_list.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
