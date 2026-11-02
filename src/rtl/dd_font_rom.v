// ===========================================================================
// 物品回收智能分拣系统 · PL 侧源码（提交包副本）
// 本文件逻辑与工程内原件完全一致，仅在文件头追加本注释块，未改动任何一行代码。
// 文件   ：dd_font_rom.v
// 层级   ：OSD 子模块
// 作用   ：8x16 ASCII 点阵字模 ROM
// 例化者 ：dd_osd.v
// 备注   ：含 initial 块做 ROM 初始化，综合为分布式 RAM/ROM
// ===========================================================================
`timescale 1ns / 1ps
//=============================================================================
// dd_font_rom.v —— 8×16 ASCII 点阵字模（0x20~0x7E），供 dd_osd 画文字用
//
// ★ 本文件由 _osd/gen_font.py 自动生成，**不要手改**；要换字体/字号就重跑脚本。
// 寻址：{ch[6:0], row[3:0]}，输出 8 位 = 该行的 8 个点（MSB = 最左像素）
//   ⇒ dd_osd 里取第 cc 列就是 bits[7-cc]。
// 异步读 ⇒ 综合成分布式 RAM（约 256 个 LUT），**不需要打拍**，与像素同拍。
//=============================================================================
module dd_font_rom (
    input  wire [6:0] ch,                                   // 字符码（7 位 ASCII，只用 0x20~0x7E）
    input  wire [3:0] row,                                  // 字符内行号 0..15
    output wire [7:0] bits                                  // 该行的 8 个点，bits[7] 是最左
);

    reg [7:0] font [0:2047];                                // 128 字符 × 16 行 = 2048 字节
    integer i;                                              // 初始化循环变量

    initial begin
        for (i = 0; i < 2048; i = i + 1)                    // 先把整张表清 0
            font[i] = 8'h00;
        // ----  0x20 ----
        font[11'h200] = 8'h00; font[11'h201] = 8'h00; font[11'h202] = 8'h00; font[11'h203] = 8'h00; font[11'h204] = 8'h00; font[11'h205] = 8'h00; font[11'h206] = 8'h00; font[11'h207] = 8'h00; font[11'h208] = 8'h00; font[11'h209] = 8'h00; font[11'h20A] = 8'h00; font[11'h20B] = 8'h00; font[11'h20C] = 8'h00; font[11'h20D] = 8'h00; font[11'h20E] = 8'h00; font[11'h20F] = 8'h00;
        // ---- !0x21 ----
        font[11'h210] = 8'h10; font[11'h211] = 8'h10; font[11'h212] = 8'h10; font[11'h213] = 8'h10; font[11'h214] = 8'h10; font[11'h215] = 8'h10; font[11'h216] = 8'h10; font[11'h217] = 8'h00; font[11'h218] = 8'h18; font[11'h219] = 8'h18; font[11'h21A] = 8'h00; font[11'h21B] = 8'h00; font[11'h21C] = 8'h00; font[11'h21D] = 8'h00; font[11'h21E] = 8'h00; font[11'h21F] = 8'h00;
        // ---- "0x22 ----
        font[11'h220] = 8'h6C; font[11'h221] = 8'h6C; font[11'h222] = 8'h6C; font[11'h223] = 8'h00; font[11'h224] = 8'h00; font[11'h225] = 8'h00; font[11'h226] = 8'h00; font[11'h227] = 8'h00; font[11'h228] = 8'h00; font[11'h229] = 8'h00; font[11'h22A] = 8'h00; font[11'h22B] = 8'h00; font[11'h22C] = 8'h00; font[11'h22D] = 8'h00; font[11'h22E] = 8'h00; font[11'h22F] = 8'h00;
        // ---- #0x23 ----
        font[11'h230] = 8'h00; font[11'h231] = 8'h24; font[11'h232] = 8'h24; font[11'h233] = 8'hFE; font[11'h234] = 8'h24; font[11'h235] = 8'h48; font[11'h236] = 8'hFE; font[11'h237] = 8'h48; font[11'h238] = 8'h48; font[11'h239] = 8'h48; font[11'h23A] = 8'h00; font[11'h23B] = 8'h00; font[11'h23C] = 8'h00; font[11'h23D] = 8'h00; font[11'h23E] = 8'h00; font[11'h23F] = 8'h00;
        // ---- $0x24 ----
        font[11'h240] = 8'h08; font[11'h241] = 8'h3C; font[11'h242] = 8'h48; font[11'h243] = 8'h50; font[11'h244] = 8'h70; font[11'h245] = 8'h1C; font[11'h246] = 8'h16; font[11'h247] = 8'h12; font[11'h248] = 8'h12; font[11'h249] = 8'h7C; font[11'h24A] = 8'h10; font[11'h24B] = 8'h10; font[11'h24C] = 8'h00; font[11'h24D] = 8'h00; font[11'h24E] = 8'h00; font[11'h24F] = 8'h00;
        // ---- %0x25 ----
        font[11'h250] = 8'h62; font[11'h251] = 8'h94; font[11'h252] = 8'h9C; font[11'h253] = 8'h68; font[11'h254] = 8'h10; font[11'h255] = 8'h10; font[11'h256] = 8'h26; font[11'h257] = 8'h69; font[11'h258] = 8'h49; font[11'h259] = 8'h86; font[11'h25A] = 8'h00; font[11'h25B] = 8'h00; font[11'h25C] = 8'h00; font[11'h25D] = 8'h00; font[11'h25E] = 8'h00; font[11'h25F] = 8'h00;
        // ---- &0x26 ----
        font[11'h260] = 8'h30; font[11'h261] = 8'h48; font[11'h262] = 8'h48; font[11'h263] = 8'h78; font[11'h264] = 8'h30; font[11'h265] = 8'h74; font[11'h266] = 8'h94; font[11'h267] = 8'h8C; font[11'h268] = 8'h8C; font[11'h269] = 8'h76; font[11'h26A] = 8'h00; font[11'h26B] = 8'h00; font[11'h26C] = 8'h00; font[11'h26D] = 8'h00; font[11'h26E] = 8'h00; font[11'h26F] = 8'h00;
        // ---- '0x27 ----
        font[11'h270] = 8'h18; font[11'h271] = 8'h18; font[11'h272] = 8'h18; font[11'h273] = 8'h00; font[11'h274] = 8'h00; font[11'h275] = 8'h00; font[11'h276] = 8'h00; font[11'h277] = 8'h00; font[11'h278] = 8'h00; font[11'h279] = 8'h00; font[11'h27A] = 8'h00; font[11'h27B] = 8'h00; font[11'h27C] = 8'h00; font[11'h27D] = 8'h00; font[11'h27E] = 8'h00; font[11'h27F] = 8'h00;
        // ---- (0x28 ----
        font[11'h280] = 8'h04; font[11'h281] = 8'h08; font[11'h282] = 8'h10; font[11'h283] = 8'h10; font[11'h284] = 8'h20; font[11'h285] = 8'h20; font[11'h286] = 8'h20; font[11'h287] = 8'h20; font[11'h288] = 8'h20; font[11'h289] = 8'h10; font[11'h28A] = 8'h10; font[11'h28B] = 8'h08; font[11'h28C] = 8'h04; font[11'h28D] = 8'h00; font[11'h28E] = 8'h00; font[11'h28F] = 8'h00;
        // ---- )0x29 ----
        font[11'h290] = 8'h40; font[11'h291] = 8'h20; font[11'h292] = 8'h10; font[11'h293] = 8'h10; font[11'h294] = 8'h08; font[11'h295] = 8'h08; font[11'h296] = 8'h08; font[11'h297] = 8'h08; font[11'h298] = 8'h08; font[11'h299] = 8'h10; font[11'h29A] = 8'h10; font[11'h29B] = 8'h20; font[11'h29C] = 8'h40; font[11'h29D] = 8'h00; font[11'h29E] = 8'h00; font[11'h29F] = 8'h00;
        // ---- *0x2A ----
        font[11'h2A0] = 8'h08; font[11'h2A1] = 8'h2A; font[11'h2A2] = 8'h1C; font[11'h2A3] = 8'h1C; font[11'h2A4] = 8'h2A; font[11'h2A5] = 8'h08; font[11'h2A6] = 8'h00; font[11'h2A7] = 8'h00; font[11'h2A8] = 8'h00; font[11'h2A9] = 8'h00; font[11'h2AA] = 8'h00; font[11'h2AB] = 8'h00; font[11'h2AC] = 8'h00; font[11'h2AD] = 8'h00; font[11'h2AE] = 8'h00; font[11'h2AF] = 8'h00;
        // ---- +0x2B ----
        font[11'h2B0] = 8'h00; font[11'h2B1] = 8'h00; font[11'h2B2] = 8'h00; font[11'h2B3] = 8'h10; font[11'h2B4] = 8'h10; font[11'h2B5] = 8'h10; font[11'h2B6] = 8'hFE; font[11'h2B7] = 8'h10; font[11'h2B8] = 8'h10; font[11'h2B9] = 8'h10; font[11'h2BA] = 8'h00; font[11'h2BB] = 8'h00; font[11'h2BC] = 8'h00; font[11'h2BD] = 8'h00; font[11'h2BE] = 8'h00; font[11'h2BF] = 8'h00;
        // ---- ,0x2C ----
        font[11'h2C0] = 8'h00; font[11'h2C1] = 8'h00; font[11'h2C2] = 8'h00; font[11'h2C3] = 8'h00; font[11'h2C4] = 8'h00; font[11'h2C5] = 8'h00; font[11'h2C6] = 8'h00; font[11'h2C7] = 8'h00; font[11'h2C8] = 8'h18; font[11'h2C9] = 8'h18; font[11'h2CA] = 8'h08; font[11'h2CB] = 8'h30; font[11'h2CC] = 8'h00; font[11'h2CD] = 8'h00; font[11'h2CE] = 8'h00; font[11'h2CF] = 8'h00;
        // ---- -0x2D ----
        font[11'h2D0] = 8'h00; font[11'h2D1] = 8'h00; font[11'h2D2] = 8'h00; font[11'h2D3] = 8'h00; font[11'h2D4] = 8'h00; font[11'h2D5] = 8'h00; font[11'h2D6] = 8'h3C; font[11'h2D7] = 8'h00; font[11'h2D8] = 8'h00; font[11'h2D9] = 8'h00; font[11'h2DA] = 8'h00; font[11'h2DB] = 8'h00; font[11'h2DC] = 8'h00; font[11'h2DD] = 8'h00; font[11'h2DE] = 8'h00; font[11'h2DF] = 8'h00;
        // ---- .0x2E ----
        font[11'h2E0] = 8'h00; font[11'h2E1] = 8'h00; font[11'h2E2] = 8'h00; font[11'h2E3] = 8'h00; font[11'h2E4] = 8'h00; font[11'h2E5] = 8'h00; font[11'h2E6] = 8'h00; font[11'h2E7] = 8'h00; font[11'h2E8] = 8'h18; font[11'h2E9] = 8'h18; font[11'h2EA] = 8'h00; font[11'h2EB] = 8'h00; font[11'h2EC] = 8'h00; font[11'h2ED] = 8'h00; font[11'h2EE] = 8'h00; font[11'h2EF] = 8'h00;
        // ---- /0x2F ----
        font[11'h2F0] = 8'h02; font[11'h2F1] = 8'h04; font[11'h2F2] = 8'h04; font[11'h2F3] = 8'h0C; font[11'h2F4] = 8'h08; font[11'h2F5] = 8'h18; font[11'h2F6] = 8'h10; font[11'h2F7] = 8'h10; font[11'h2F8] = 8'h20; font[11'h2F9] = 8'h20; font[11'h2FA] = 8'h40; font[11'h2FB] = 8'h00; font[11'h2FC] = 8'h00; font[11'h2FD] = 8'h00; font[11'h2FE] = 8'h00; font[11'h2FF] = 8'h00;
        // ---- 00x30 ----
        font[11'h300] = 8'h00; font[11'h301] = 8'h3C; font[11'h302] = 8'h24; font[11'h303] = 8'h42; font[11'h304] = 8'h46; font[11'h305] = 8'h5A; font[11'h306] = 8'h62; font[11'h307] = 8'h42; font[11'h308] = 8'h24; font[11'h309] = 8'h3C; font[11'h30A] = 8'h00; font[11'h30B] = 8'h00; font[11'h30C] = 8'h00; font[11'h30D] = 8'h00; font[11'h30E] = 8'h00; font[11'h30F] = 8'h00;
        // ---- 10x31 ----
        font[11'h310] = 8'h00; font[11'h311] = 8'h08; font[11'h312] = 8'h18; font[11'h313] = 8'h28; font[11'h314] = 8'h08; font[11'h315] = 8'h08; font[11'h316] = 8'h08; font[11'h317] = 8'h08; font[11'h318] = 8'h08; font[11'h319] = 8'h3E; font[11'h31A] = 8'h00; font[11'h31B] = 8'h00; font[11'h31C] = 8'h00; font[11'h31D] = 8'h00; font[11'h31E] = 8'h00; font[11'h31F] = 8'h00;
        // ---- 20x32 ----
        font[11'h320] = 8'h00; font[11'h321] = 8'h3C; font[11'h322] = 8'h42; font[11'h323] = 8'h02; font[11'h324] = 8'h02; font[11'h325] = 8'h04; font[11'h326] = 8'h0C; font[11'h327] = 8'h18; font[11'h328] = 8'h30; font[11'h329] = 8'h7E; font[11'h32A] = 8'h00; font[11'h32B] = 8'h00; font[11'h32C] = 8'h00; font[11'h32D] = 8'h00; font[11'h32E] = 8'h00; font[11'h32F] = 8'h00;
        // ---- 30x33 ----
        font[11'h330] = 8'h00; font[11'h331] = 8'h78; font[11'h332] = 8'h04; font[11'h333] = 8'h04; font[11'h334] = 8'h04; font[11'h335] = 8'h38; font[11'h336] = 8'h04; font[11'h337] = 8'h04; font[11'h338] = 8'h04; font[11'h339] = 8'h78; font[11'h33A] = 8'h00; font[11'h33B] = 8'h00; font[11'h33C] = 8'h00; font[11'h33D] = 8'h00; font[11'h33E] = 8'h00; font[11'h33F] = 8'h00;
        // ---- 40x34 ----
        font[11'h340] = 8'h00; font[11'h341] = 8'h18; font[11'h342] = 8'h18; font[11'h343] = 8'h28; font[11'h344] = 8'h68; font[11'h345] = 8'h48; font[11'h346] = 8'h88; font[11'h347] = 8'hFE; font[11'h348] = 8'h08; font[11'h349] = 8'h08; font[11'h34A] = 8'h00; font[11'h34B] = 8'h00; font[11'h34C] = 8'h00; font[11'h34D] = 8'h00; font[11'h34E] = 8'h00; font[11'h34F] = 8'h00;
        // ---- 50x35 ----
        font[11'h350] = 8'h00; font[11'h351] = 8'h7C; font[11'h352] = 8'h40; font[11'h353] = 8'h40; font[11'h354] = 8'h40; font[11'h355] = 8'h78; font[11'h356] = 8'h04; font[11'h357] = 8'h04; font[11'h358] = 8'h0C; font[11'h359] = 8'h78; font[11'h35A] = 8'h00; font[11'h35B] = 8'h00; font[11'h35C] = 8'h00; font[11'h35D] = 8'h00; font[11'h35E] = 8'h00; font[11'h35F] = 8'h00;
        // ---- 60x36 ----
        font[11'h360] = 8'h00; font[11'h361] = 8'h1C; font[11'h362] = 8'h20; font[11'h363] = 8'h40; font[11'h364] = 8'h5C; font[11'h365] = 8'h62; font[11'h366] = 8'h42; font[11'h367] = 8'h42; font[11'h368] = 8'h66; font[11'h369] = 8'h3C; font[11'h36A] = 8'h00; font[11'h36B] = 8'h00; font[11'h36C] = 8'h00; font[11'h36D] = 8'h00; font[11'h36E] = 8'h00; font[11'h36F] = 8'h00;
        // ---- 70x37 ----
        font[11'h370] = 8'h00; font[11'h371] = 8'h7E; font[11'h372] = 8'h02; font[11'h373] = 8'h04; font[11'h374] = 8'h04; font[11'h375] = 8'h08; font[11'h376] = 8'h08; font[11'h377] = 8'h10; font[11'h378] = 8'h10; font[11'h379] = 8'h30; font[11'h37A] = 8'h00; font[11'h37B] = 8'h00; font[11'h37C] = 8'h00; font[11'h37D] = 8'h00; font[11'h37E] = 8'h00; font[11'h37F] = 8'h00;
        // ---- 80x38 ----
        font[11'h380] = 8'h00; font[11'h381] = 8'h3C; font[11'h382] = 8'h42; font[11'h383] = 8'h42; font[11'h384] = 8'h66; font[11'h385] = 8'h18; font[11'h386] = 8'h66; font[11'h387] = 8'h42; font[11'h388] = 8'h42; font[11'h389] = 8'h3C; font[11'h38A] = 8'h00; font[11'h38B] = 8'h00; font[11'h38C] = 8'h00; font[11'h38D] = 8'h00; font[11'h38E] = 8'h00; font[11'h38F] = 8'h00;
        // ---- 90x39 ----
        font[11'h390] = 8'h00; font[11'h391] = 8'h3C; font[11'h392] = 8'h66; font[11'h393] = 8'h42; font[11'h394] = 8'h42; font[11'h395] = 8'h46; font[11'h396] = 8'h3A; font[11'h397] = 8'h02; font[11'h398] = 8'h04; font[11'h399] = 8'h38; font[11'h39A] = 8'h00; font[11'h39B] = 8'h00; font[11'h39C] = 8'h00; font[11'h39D] = 8'h00; font[11'h39E] = 8'h00; font[11'h39F] = 8'h00;
        // ---- :0x3A ----
        font[11'h3A0] = 8'h00; font[11'h3A1] = 8'h00; font[11'h3A2] = 8'h00; font[11'h3A3] = 8'h18; font[11'h3A4] = 8'h18; font[11'h3A5] = 8'h00; font[11'h3A6] = 8'h00; font[11'h3A7] = 8'h00; font[11'h3A8] = 8'h18; font[11'h3A9] = 8'h18; font[11'h3AA] = 8'h00; font[11'h3AB] = 8'h00; font[11'h3AC] = 8'h00; font[11'h3AD] = 8'h00; font[11'h3AE] = 8'h00; font[11'h3AF] = 8'h00;
        // ---- ;0x3B ----
        font[11'h3B0] = 8'h00; font[11'h3B1] = 8'h00; font[11'h3B2] = 8'h00; font[11'h3B3] = 8'h18; font[11'h3B4] = 8'h18; font[11'h3B5] = 8'h00; font[11'h3B6] = 8'h00; font[11'h3B7] = 8'h00; font[11'h3B8] = 8'h18; font[11'h3B9] = 8'h18; font[11'h3BA] = 8'h08; font[11'h3BB] = 8'h30; font[11'h3BC] = 8'h00; font[11'h3BD] = 8'h00; font[11'h3BE] = 8'h00; font[11'h3BF] = 8'h00;
        // ---- <0x3C ----
        font[11'h3C0] = 8'h00; font[11'h3C1] = 8'h00; font[11'h3C2] = 8'h04; font[11'h3C3] = 8'h08; font[11'h3C4] = 8'h10; font[11'h3C5] = 8'h20; font[11'h3C6] = 8'h60; font[11'h3C7] = 8'h10; font[11'h3C8] = 8'h08; font[11'h3C9] = 8'h04; font[11'h3CA] = 8'h00; font[11'h3CB] = 8'h00; font[11'h3CC] = 8'h00; font[11'h3CD] = 8'h00; font[11'h3CE] = 8'h00; font[11'h3CF] = 8'h00;
        // ---- =0x3D ----
        font[11'h3D0] = 8'h00; font[11'h3D1] = 8'h00; font[11'h3D2] = 8'h00; font[11'h3D3] = 8'h00; font[11'h3D4] = 8'h00; font[11'h3D5] = 8'h7E; font[11'h3D6] = 8'h00; font[11'h3D7] = 8'h7E; font[11'h3D8] = 8'h00; font[11'h3D9] = 8'h00; font[11'h3DA] = 8'h00; font[11'h3DB] = 8'h00; font[11'h3DC] = 8'h00; font[11'h3DD] = 8'h00; font[11'h3DE] = 8'h00; font[11'h3DF] = 8'h00;
        // ---- >0x3E ----
        font[11'h3E0] = 8'h00; font[11'h3E1] = 8'h00; font[11'h3E2] = 8'h40; font[11'h3E3] = 8'h20; font[11'h3E4] = 8'h10; font[11'h3E5] = 8'h08; font[11'h3E6] = 8'h0C; font[11'h3E7] = 8'h10; font[11'h3E8] = 8'h20; font[11'h3E9] = 8'h40; font[11'h3EA] = 8'h00; font[11'h3EB] = 8'h00; font[11'h3EC] = 8'h00; font[11'h3ED] = 8'h00; font[11'h3EE] = 8'h00; font[11'h3EF] = 8'h00;
        // ---- ?0x3F ----
        font[11'h3F0] = 8'h30; font[11'h3F1] = 8'h08; font[11'h3F2] = 8'h04; font[11'h3F3] = 8'h04; font[11'h3F4] = 8'h04; font[11'h3F5] = 8'h38; font[11'h3F6] = 8'h20; font[11'h3F7] = 8'h00; font[11'h3F8] = 8'h30; font[11'h3F9] = 8'h30; font[11'h3FA] = 8'h00; font[11'h3FB] = 8'h00; font[11'h3FC] = 8'h00; font[11'h3FD] = 8'h00; font[11'h3FE] = 8'h00; font[11'h3FF] = 8'h00;
        // ---- @0x40 ----
        font[11'h400] = 8'h1C; font[11'h401] = 8'h22; font[11'h402] = 8'h41; font[11'h403] = 8'h41; font[11'h404] = 8'h9D; font[11'h405] = 8'hB5; font[11'h406] = 8'hA5; font[11'h407] = 8'hA5; font[11'h408] = 8'hA5; font[11'h409] = 8'hBE; font[11'h40A] = 8'h80; font[11'h40B] = 8'h44; font[11'h40C] = 8'h38; font[11'h40D] = 8'h00; font[11'h40E] = 8'h00; font[11'h40F] = 8'h00;
        // ---- A0x41 ----
        font[11'h410] = 8'h00; font[11'h411] = 8'h18; font[11'h412] = 8'h28; font[11'h413] = 8'h28; font[11'h414] = 8'h6C; font[11'h415] = 8'h44; font[11'h416] = 8'h44; font[11'h417] = 8'hFE; font[11'h418] = 8'h82; font[11'h419] = 8'h82; font[11'h41A] = 8'h00; font[11'h41B] = 8'h00; font[11'h41C] = 8'h00; font[11'h41D] = 8'h00; font[11'h41E] = 8'h00; font[11'h41F] = 8'h00;
        // ---- B0x42 ----
        font[11'h420] = 8'h00; font[11'h421] = 8'h7C; font[11'h422] = 8'h42; font[11'h423] = 8'h42; font[11'h424] = 8'h46; font[11'h425] = 8'h7C; font[11'h426] = 8'h42; font[11'h427] = 8'h42; font[11'h428] = 8'h42; font[11'h429] = 8'h7C; font[11'h42A] = 8'h00; font[11'h42B] = 8'h00; font[11'h42C] = 8'h00; font[11'h42D] = 8'h00; font[11'h42E] = 8'h00; font[11'h42F] = 8'h00;
        // ---- C0x43 ----
        font[11'h430] = 8'h00; font[11'h431] = 8'h1C; font[11'h432] = 8'h22; font[11'h433] = 8'h40; font[11'h434] = 8'h40; font[11'h435] = 8'h40; font[11'h436] = 8'h40; font[11'h437] = 8'h40; font[11'h438] = 8'h22; font[11'h439] = 8'h1C; font[11'h43A] = 8'h00; font[11'h43B] = 8'h00; font[11'h43C] = 8'h00; font[11'h43D] = 8'h00; font[11'h43E] = 8'h00; font[11'h43F] = 8'h00;
        // ---- D0x44 ----
        font[11'h440] = 8'h00; font[11'h441] = 8'h78; font[11'h442] = 8'h44; font[11'h443] = 8'h42; font[11'h444] = 8'h42; font[11'h445] = 8'h42; font[11'h446] = 8'h42; font[11'h447] = 8'h42; font[11'h448] = 8'h44; font[11'h449] = 8'h78; font[11'h44A] = 8'h00; font[11'h44B] = 8'h00; font[11'h44C] = 8'h00; font[11'h44D] = 8'h00; font[11'h44E] = 8'h00; font[11'h44F] = 8'h00;
        // ---- E0x45 ----
        font[11'h450] = 8'h00; font[11'h451] = 8'h7C; font[11'h452] = 8'h40; font[11'h453] = 8'h40; font[11'h454] = 8'h40; font[11'h455] = 8'h7C; font[11'h456] = 8'h40; font[11'h457] = 8'h40; font[11'h458] = 8'h40; font[11'h459] = 8'h7C; font[11'h45A] = 8'h00; font[11'h45B] = 8'h00; font[11'h45C] = 8'h00; font[11'h45D] = 8'h00; font[11'h45E] = 8'h00; font[11'h45F] = 8'h00;
        // ---- F0x46 ----
        font[11'h460] = 8'h00; font[11'h461] = 8'h7C; font[11'h462] = 8'h40; font[11'h463] = 8'h40; font[11'h464] = 8'h40; font[11'h465] = 8'h7C; font[11'h466] = 8'h40; font[11'h467] = 8'h40; font[11'h468] = 8'h40; font[11'h469] = 8'h40; font[11'h46A] = 8'h00; font[11'h46B] = 8'h00; font[11'h46C] = 8'h00; font[11'h46D] = 8'h00; font[11'h46E] = 8'h00; font[11'h46F] = 8'h00;
        // ---- G0x47 ----
        font[11'h470] = 8'h00; font[11'h471] = 8'h38; font[11'h472] = 8'h44; font[11'h473] = 8'h80; font[11'h474] = 8'h80; font[11'h475] = 8'h9C; font[11'h476] = 8'h84; font[11'h477] = 8'h84; font[11'h478] = 8'h44; font[11'h479] = 8'h3C; font[11'h47A] = 8'h00; font[11'h47B] = 8'h00; font[11'h47C] = 8'h00; font[11'h47D] = 8'h00; font[11'h47E] = 8'h00; font[11'h47F] = 8'h00;
        // ---- H0x48 ----
        font[11'h480] = 8'h00; font[11'h481] = 8'h42; font[11'h482] = 8'h42; font[11'h483] = 8'h42; font[11'h484] = 8'h42; font[11'h485] = 8'h7E; font[11'h486] = 8'h42; font[11'h487] = 8'h42; font[11'h488] = 8'h42; font[11'h489] = 8'h42; font[11'h48A] = 8'h00; font[11'h48B] = 8'h00; font[11'h48C] = 8'h00; font[11'h48D] = 8'h00; font[11'h48E] = 8'h00; font[11'h48F] = 8'h00;
        // ---- I0x49 ----
        font[11'h490] = 8'h00; font[11'h491] = 8'h7C; font[11'h492] = 8'h10; font[11'h493] = 8'h10; font[11'h494] = 8'h10; font[11'h495] = 8'h10; font[11'h496] = 8'h10; font[11'h497] = 8'h10; font[11'h498] = 8'h10; font[11'h499] = 8'h7C; font[11'h49A] = 8'h00; font[11'h49B] = 8'h00; font[11'h49C] = 8'h00; font[11'h49D] = 8'h00; font[11'h49E] = 8'h00; font[11'h49F] = 8'h00;
        // ---- J0x4A ----
        font[11'h4A0] = 8'h00; font[11'h4A1] = 8'h7C; font[11'h4A2] = 8'h04; font[11'h4A3] = 8'h04; font[11'h4A4] = 8'h04; font[11'h4A5] = 8'h04; font[11'h4A6] = 8'h04; font[11'h4A7] = 8'h04; font[11'h4A8] = 8'h44; font[11'h4A9] = 8'h38; font[11'h4AA] = 8'h00; font[11'h4AB] = 8'h00; font[11'h4AC] = 8'h00; font[11'h4AD] = 8'h00; font[11'h4AE] = 8'h00; font[11'h4AF] = 8'h00;
        // ---- K0x4B ----
        font[11'h4B0] = 8'h00; font[11'h4B1] = 8'h42; font[11'h4B2] = 8'h44; font[11'h4B3] = 8'h48; font[11'h4B4] = 8'h50; font[11'h4B5] = 8'h60; font[11'h4B6] = 8'h50; font[11'h4B7] = 8'h48; font[11'h4B8] = 8'h44; font[11'h4B9] = 8'h42; font[11'h4BA] = 8'h00; font[11'h4BB] = 8'h00; font[11'h4BC] = 8'h00; font[11'h4BD] = 8'h00; font[11'h4BE] = 8'h00; font[11'h4BF] = 8'h00;
        // ---- L0x4C ----
        font[11'h4C0] = 8'h00; font[11'h4C1] = 8'h20; font[11'h4C2] = 8'h20; font[11'h4C3] = 8'h20; font[11'h4C4] = 8'h20; font[11'h4C5] = 8'h20; font[11'h4C6] = 8'h20; font[11'h4C7] = 8'h20; font[11'h4C8] = 8'h20; font[11'h4C9] = 8'h3E; font[11'h4CA] = 8'h00; font[11'h4CB] = 8'h00; font[11'h4CC] = 8'h00; font[11'h4CD] = 8'h00; font[11'h4CE] = 8'h00; font[11'h4CF] = 8'h00;
        // ---- M0x4D ----
        font[11'h4D0] = 8'h00; font[11'h4D1] = 8'h26; font[11'h4D2] = 8'h66; font[11'h4D3] = 8'h5A; font[11'h4D4] = 8'h5A; font[11'h4D5] = 8'h5A; font[11'h4D6] = 8'h52; font[11'h4D7] = 8'h42; font[11'h4D8] = 8'h42; font[11'h4D9] = 8'h42; font[11'h4DA] = 8'h00; font[11'h4DB] = 8'h00; font[11'h4DC] = 8'h00; font[11'h4DD] = 8'h00; font[11'h4DE] = 8'h00; font[11'h4DF] = 8'h00;
        // ---- N0x4E ----
        font[11'h4E0] = 8'h00; font[11'h4E1] = 8'h62; font[11'h4E2] = 8'h62; font[11'h4E3] = 8'h52; font[11'h4E4] = 8'h52; font[11'h4E5] = 8'h52; font[11'h4E6] = 8'h4A; font[11'h4E7] = 8'h4A; font[11'h4E8] = 8'h46; font[11'h4E9] = 8'h46; font[11'h4EA] = 8'h00; font[11'h4EB] = 8'h00; font[11'h4EC] = 8'h00; font[11'h4ED] = 8'h00; font[11'h4EE] = 8'h00; font[11'h4EF] = 8'h00;
        // ---- O0x4F ----
        font[11'h4F0] = 8'h00; font[11'h4F1] = 8'h38; font[11'h4F2] = 8'h44; font[11'h4F3] = 8'h82; font[11'h4F4] = 8'h82; font[11'h4F5] = 8'h82; font[11'h4F6] = 8'h82; font[11'h4F7] = 8'h82; font[11'h4F8] = 8'h44; font[11'h4F9] = 8'h38; font[11'h4FA] = 8'h00; font[11'h4FB] = 8'h00; font[11'h4FC] = 8'h00; font[11'h4FD] = 8'h00; font[11'h4FE] = 8'h00; font[11'h4FF] = 8'h00;
        // ---- P0x50 ----
        font[11'h500] = 8'h00; font[11'h501] = 8'h7C; font[11'h502] = 8'h46; font[11'h503] = 8'h42; font[11'h504] = 8'h42; font[11'h505] = 8'h46; font[11'h506] = 8'h78; font[11'h507] = 8'h40; font[11'h508] = 8'h40; font[11'h509] = 8'h40; font[11'h50A] = 8'h00; font[11'h50B] = 8'h00; font[11'h50C] = 8'h00; font[11'h50D] = 8'h00; font[11'h50E] = 8'h00; font[11'h50F] = 8'h00;
        // ---- Q0x51 ----
        font[11'h510] = 8'h00; font[11'h511] = 8'h38; font[11'h512] = 8'h44; font[11'h513] = 8'h82; font[11'h514] = 8'h82; font[11'h515] = 8'h82; font[11'h516] = 8'h82; font[11'h517] = 8'h82; font[11'h518] = 8'h44; font[11'h519] = 8'h78; font[11'h51A] = 8'h10; font[11'h51B] = 8'h0E; font[11'h51C] = 8'h00; font[11'h51D] = 8'h00; font[11'h51E] = 8'h00; font[11'h51F] = 8'h00;
        // ---- R0x52 ----
        font[11'h520] = 8'h00; font[11'h521] = 8'h78; font[11'h522] = 8'h44; font[11'h523] = 8'h44; font[11'h524] = 8'h44; font[11'h525] = 8'h78; font[11'h526] = 8'h48; font[11'h527] = 8'h4C; font[11'h528] = 8'h44; font[11'h529] = 8'h46; font[11'h52A] = 8'h00; font[11'h52B] = 8'h00; font[11'h52C] = 8'h00; font[11'h52D] = 8'h00; font[11'h52E] = 8'h00; font[11'h52F] = 8'h00;
        // ---- S0x53 ----
        font[11'h530] = 8'h00; font[11'h531] = 8'h3C; font[11'h532] = 8'h40; font[11'h533] = 8'h40; font[11'h534] = 8'h60; font[11'h535] = 8'h1C; font[11'h536] = 8'h06; font[11'h537] = 8'h02; font[11'h538] = 8'h02; font[11'h539] = 8'h7C; font[11'h53A] = 8'h00; font[11'h53B] = 8'h00; font[11'h53C] = 8'h00; font[11'h53D] = 8'h00; font[11'h53E] = 8'h00; font[11'h53F] = 8'h00;
        // ---- T0x54 ----
        font[11'h540] = 8'h00; font[11'h541] = 8'hFE; font[11'h542] = 8'h10; font[11'h543] = 8'h10; font[11'h544] = 8'h10; font[11'h545] = 8'h10; font[11'h546] = 8'h10; font[11'h547] = 8'h10; font[11'h548] = 8'h10; font[11'h549] = 8'h10; font[11'h54A] = 8'h00; font[11'h54B] = 8'h00; font[11'h54C] = 8'h00; font[11'h54D] = 8'h00; font[11'h54E] = 8'h00; font[11'h54F] = 8'h00;
        // ---- U0x55 ----
        font[11'h550] = 8'h00; font[11'h551] = 8'h42; font[11'h552] = 8'h42; font[11'h553] = 8'h42; font[11'h554] = 8'h42; font[11'h555] = 8'h42; font[11'h556] = 8'h42; font[11'h557] = 8'h42; font[11'h558] = 8'h46; font[11'h559] = 8'h3C; font[11'h55A] = 8'h00; font[11'h55B] = 8'h00; font[11'h55C] = 8'h00; font[11'h55D] = 8'h00; font[11'h55E] = 8'h00; font[11'h55F] = 8'h00;
        // ---- V0x56 ----
        font[11'h560] = 8'h00; font[11'h561] = 8'h41; font[11'h562] = 8'h41; font[11'h563] = 8'h63; font[11'h564] = 8'h22; font[11'h565] = 8'h22; font[11'h566] = 8'h36; font[11'h567] = 8'h14; font[11'h568] = 8'h14; font[11'h569] = 8'h18; font[11'h56A] = 8'h00; font[11'h56B] = 8'h00; font[11'h56C] = 8'h00; font[11'h56D] = 8'h00; font[11'h56E] = 8'h00; font[11'h56F] = 8'h00;
        // ---- W0x57 ----
        font[11'h570] = 8'h00; font[11'h571] = 8'h41; font[11'h572] = 8'h41; font[11'h573] = 8'h41; font[11'h574] = 8'h69; font[11'h575] = 8'h6B; font[11'h576] = 8'h2A; font[11'h577] = 8'h3A; font[11'h578] = 8'h36; font[11'h579] = 8'h36; font[11'h57A] = 8'h00; font[11'h57B] = 8'h00; font[11'h57C] = 8'h00; font[11'h57D] = 8'h00; font[11'h57E] = 8'h00; font[11'h57F] = 8'h00;
        // ---- X0x58 ----
        font[11'h580] = 8'h00; font[11'h581] = 8'hC6; font[11'h582] = 8'h64; font[11'h583] = 8'h28; font[11'h584] = 8'h18; font[11'h585] = 8'h18; font[11'h586] = 8'h38; font[11'h587] = 8'h24; font[11'h588] = 8'h46; font[11'h589] = 8'hC3; font[11'h58A] = 8'h00; font[11'h58B] = 8'h00; font[11'h58C] = 8'h00; font[11'h58D] = 8'h00; font[11'h58E] = 8'h00; font[11'h58F] = 8'h00;
        // ---- Y0x59 ----
        font[11'h590] = 8'h00; font[11'h591] = 8'h82; font[11'h592] = 8'h44; font[11'h593] = 8'h44; font[11'h594] = 8'h28; font[11'h595] = 8'h28; font[11'h596] = 8'h10; font[11'h597] = 8'h10; font[11'h598] = 8'h10; font[11'h599] = 8'h10; font[11'h59A] = 8'h00; font[11'h59B] = 8'h00; font[11'h59C] = 8'h00; font[11'h59D] = 8'h00; font[11'h59E] = 8'h00; font[11'h59F] = 8'h00;
        // ---- Z0x5A ----
        font[11'h5A0] = 8'h00; font[11'h5A1] = 8'h7E; font[11'h5A2] = 8'h04; font[11'h5A3] = 8'h04; font[11'h5A4] = 8'h08; font[11'h5A5] = 8'h18; font[11'h5A6] = 8'h10; font[11'h5A7] = 8'h20; font[11'h5A8] = 8'h20; font[11'h5A9] = 8'h7E; font[11'h5AA] = 8'h00; font[11'h5AB] = 8'h00; font[11'h5AC] = 8'h00; font[11'h5AD] = 8'h00; font[11'h5AE] = 8'h00; font[11'h5AF] = 8'h00;
        // ---- [0x5B ----
        font[11'h5B0] = 8'h1C; font[11'h5B1] = 8'h10; font[11'h5B2] = 8'h10; font[11'h5B3] = 8'h10; font[11'h5B4] = 8'h10; font[11'h5B5] = 8'h10; font[11'h5B6] = 8'h10; font[11'h5B7] = 8'h10; font[11'h5B8] = 8'h10; font[11'h5B9] = 8'h10; font[11'h5BA] = 8'h10; font[11'h5BB] = 8'h10; font[11'h5BC] = 8'h1C; font[11'h5BD] = 8'h00; font[11'h5BE] = 8'h00; font[11'h5BF] = 8'h00;
        // ---- \0x5C ----
        font[11'h5C0] = 8'h40; font[11'h5C1] = 8'h20; font[11'h5C2] = 8'h20; font[11'h5C3] = 8'h10; font[11'h5C4] = 8'h10; font[11'h5C5] = 8'h18; font[11'h5C6] = 8'h08; font[11'h5C7] = 8'h0C; font[11'h5C8] = 8'h04; font[11'h5C9] = 8'h04; font[11'h5CA] = 8'h02; font[11'h5CB] = 8'h00; font[11'h5CC] = 8'h00; font[11'h5CD] = 8'h00; font[11'h5CE] = 8'h00; font[11'h5CF] = 8'h00;
        // ---- ]0x5D ----
        font[11'h5D0] = 8'h38; font[11'h5D1] = 8'h08; font[11'h5D2] = 8'h08; font[11'h5D3] = 8'h08; font[11'h5D4] = 8'h08; font[11'h5D5] = 8'h08; font[11'h5D6] = 8'h08; font[11'h5D7] = 8'h08; font[11'h5D8] = 8'h08; font[11'h5D9] = 8'h08; font[11'h5DA] = 8'h08; font[11'h5DB] = 8'h08; font[11'h5DC] = 8'h38; font[11'h5DD] = 8'h00; font[11'h5DE] = 8'h00; font[11'h5DF] = 8'h00;
        // ---- ^0x5E ----
        font[11'h5E0] = 8'h00; font[11'h5E1] = 8'h10; font[11'h5E2] = 8'h28; font[11'h5E3] = 8'h44; font[11'h5E4] = 8'h44; font[11'h5E5] = 8'h00; font[11'h5E6] = 8'h00; font[11'h5E7] = 8'h00; font[11'h5E8] = 8'h00; font[11'h5E9] = 8'h00; font[11'h5EA] = 8'h00; font[11'h5EB] = 8'h00; font[11'h5EC] = 8'h00; font[11'h5ED] = 8'h00; font[11'h5EE] = 8'h00; font[11'h5EF] = 8'h00;
        // ---- _0x5F ----
        font[11'h5F0] = 8'h00; font[11'h5F1] = 8'h00; font[11'h5F2] = 8'h00; font[11'h5F3] = 8'h00; font[11'h5F4] = 8'h00; font[11'h5F5] = 8'h00; font[11'h5F6] = 8'h00; font[11'h5F7] = 8'h00; font[11'h5F8] = 8'h00; font[11'h5F9] = 8'h00; font[11'h5FA] = 8'h00; font[11'h5FB] = 8'h00; font[11'h5FC] = 8'hFF; font[11'h5FD] = 8'h00; font[11'h5FE] = 8'h00; font[11'h5FF] = 8'h00;
        // ---- `0x60 ----
        font[11'h600] = 8'h60; font[11'h601] = 8'h30; font[11'h602] = 8'h00; font[11'h603] = 8'h00; font[11'h604] = 8'h00; font[11'h605] = 8'h00; font[11'h606] = 8'h00; font[11'h607] = 8'h00; font[11'h608] = 8'h00; font[11'h609] = 8'h00; font[11'h60A] = 8'h00; font[11'h60B] = 8'h00; font[11'h60C] = 8'h00; font[11'h60D] = 8'h00; font[11'h60E] = 8'h00; font[11'h60F] = 8'h00;
        // ---- a0x61 ----
        font[11'h610] = 8'h00; font[11'h611] = 8'h00; font[11'h612] = 8'h00; font[11'h613] = 8'h18; font[11'h614] = 8'h24; font[11'h615] = 8'h04; font[11'h616] = 8'h3C; font[11'h617] = 8'h44; font[11'h618] = 8'h4C; font[11'h619] = 8'h3C; font[11'h61A] = 8'h00; font[11'h61B] = 8'h00; font[11'h61C] = 8'h00; font[11'h61D] = 8'h00; font[11'h61E] = 8'h00; font[11'h61F] = 8'h00;
        // ---- b0x62 ----
        font[11'h620] = 8'h40; font[11'h621] = 8'h40; font[11'h622] = 8'h40; font[11'h623] = 8'h5C; font[11'h624] = 8'h66; font[11'h625] = 8'h42; font[11'h626] = 8'h42; font[11'h627] = 8'h42; font[11'h628] = 8'h44; font[11'h629] = 8'h78; font[11'h62A] = 8'h00; font[11'h62B] = 8'h00; font[11'h62C] = 8'h00; font[11'h62D] = 8'h00; font[11'h62E] = 8'h00; font[11'h62F] = 8'h00;
        // ---- c0x63 ----
        font[11'h630] = 8'h00; font[11'h631] = 8'h00; font[11'h632] = 8'h00; font[11'h633] = 8'h3C; font[11'h634] = 8'h20; font[11'h635] = 8'h40; font[11'h636] = 8'h40; font[11'h637] = 8'h40; font[11'h638] = 8'h60; font[11'h639] = 8'h3C; font[11'h63A] = 8'h00; font[11'h63B] = 8'h00; font[11'h63C] = 8'h00; font[11'h63D] = 8'h00; font[11'h63E] = 8'h00; font[11'h63F] = 8'h00;
        // ---- d0x64 ----
        font[11'h640] = 8'h02; font[11'h641] = 8'h02; font[11'h642] = 8'h02; font[11'h643] = 8'h1E; font[11'h644] = 8'h22; font[11'h645] = 8'h42; font[11'h646] = 8'h42; font[11'h647] = 8'h42; font[11'h648] = 8'h66; font[11'h649] = 8'h3A; font[11'h64A] = 8'h00; font[11'h64B] = 8'h00; font[11'h64C] = 8'h00; font[11'h64D] = 8'h00; font[11'h64E] = 8'h00; font[11'h64F] = 8'h00;
        // ---- e0x65 ----
        font[11'h650] = 8'h00; font[11'h651] = 8'h00; font[11'h652] = 8'h00; font[11'h653] = 8'h3C; font[11'h654] = 8'h66; font[11'h655] = 8'h42; font[11'h656] = 8'h7E; font[11'h657] = 8'h40; font[11'h658] = 8'h60; font[11'h659] = 8'h3E; font[11'h65A] = 8'h00; font[11'h65B] = 8'h00; font[11'h65C] = 8'h00; font[11'h65D] = 8'h00; font[11'h65E] = 8'h00; font[11'h65F] = 8'h00;
        // ---- f0x66 ----
        font[11'h660] = 8'h0E; font[11'h661] = 8'h10; font[11'h662] = 8'h10; font[11'h663] = 8'h10; font[11'h664] = 8'h7C; font[11'h665] = 8'h10; font[11'h666] = 8'h10; font[11'h667] = 8'h10; font[11'h668] = 8'h10; font[11'h669] = 8'h10; font[11'h66A] = 8'h00; font[11'h66B] = 8'h00; font[11'h66C] = 8'h00; font[11'h66D] = 8'h00; font[11'h66E] = 8'h00; font[11'h66F] = 8'h00;
        // ---- g0x67 ----
        font[11'h670] = 8'h00; font[11'h671] = 8'h00; font[11'h672] = 8'h00; font[11'h673] = 8'h3E; font[11'h674] = 8'h44; font[11'h675] = 8'h44; font[11'h676] = 8'h44; font[11'h677] = 8'h78; font[11'h678] = 8'h40; font[11'h679] = 8'h7C; font[11'h67A] = 8'h42; font[11'h67B] = 8'h42; font[11'h67C] = 8'h3C; font[11'h67D] = 8'h00; font[11'h67E] = 8'h00; font[11'h67F] = 8'h00;
        // ---- h0x68 ----
        font[11'h680] = 8'h40; font[11'h681] = 8'h40; font[11'h682] = 8'h40; font[11'h683] = 8'h58; font[11'h684] = 8'h64; font[11'h685] = 8'h44; font[11'h686] = 8'h44; font[11'h687] = 8'h44; font[11'h688] = 8'h44; font[11'h689] = 8'h44; font[11'h68A] = 8'h00; font[11'h68B] = 8'h00; font[11'h68C] = 8'h00; font[11'h68D] = 8'h00; font[11'h68E] = 8'h00; font[11'h68F] = 8'h00;
        // ---- i0x69 ----
        font[11'h690] = 8'h30; font[11'h691] = 8'h30; font[11'h692] = 8'h00; font[11'h693] = 8'h70; font[11'h694] = 8'h10; font[11'h695] = 8'h10; font[11'h696] = 8'h10; font[11'h697] = 8'h10; font[11'h698] = 8'h10; font[11'h699] = 8'h7E; font[11'h69A] = 8'h00; font[11'h69B] = 8'h00; font[11'h69C] = 8'h00; font[11'h69D] = 8'h00; font[11'h69E] = 8'h00; font[11'h69F] = 8'h00;
        // ---- j0x6A ----
        font[11'h6A0] = 8'h0C; font[11'h6A1] = 8'h0C; font[11'h6A2] = 8'h00; font[11'h6A3] = 8'h7C; font[11'h6A4] = 8'h04; font[11'h6A5] = 8'h04; font[11'h6A6] = 8'h04; font[11'h6A7] = 8'h04; font[11'h6A8] = 8'h04; font[11'h6A9] = 8'h04; font[11'h6AA] = 8'h04; font[11'h6AB] = 8'h0C; font[11'h6AC] = 8'h78; font[11'h6AD] = 8'h00; font[11'h6AE] = 8'h00; font[11'h6AF] = 8'h00;
        // ---- k0x6B ----
        font[11'h6B0] = 8'h40; font[11'h6B1] = 8'h40; font[11'h6B2] = 8'h40; font[11'h6B3] = 8'h44; font[11'h6B4] = 8'h48; font[11'h6B5] = 8'h50; font[11'h6B6] = 8'h60; font[11'h6B7] = 8'h50; font[11'h6B8] = 8'h48; font[11'h6B9] = 8'h44; font[11'h6BA] = 8'h00; font[11'h6BB] = 8'h00; font[11'h6BC] = 8'h00; font[11'h6BD] = 8'h00; font[11'h6BE] = 8'h00; font[11'h6BF] = 8'h00;
        // ---- l0x6C ----
        font[11'h6C0] = 8'h70; font[11'h6C1] = 8'h10; font[11'h6C2] = 8'h10; font[11'h6C3] = 8'h10; font[11'h6C4] = 8'h10; font[11'h6C5] = 8'h10; font[11'h6C6] = 8'h10; font[11'h6C7] = 8'h10; font[11'h6C8] = 8'h10; font[11'h6C9] = 8'h7E; font[11'h6CA] = 8'h00; font[11'h6CB] = 8'h00; font[11'h6CC] = 8'h00; font[11'h6CD] = 8'h00; font[11'h6CE] = 8'h00; font[11'h6CF] = 8'h00;
        // ---- m0x6D ----
        font[11'h6D0] = 8'h00; font[11'h6D1] = 8'h00; font[11'h6D2] = 8'h00; font[11'h6D3] = 8'hFE; font[11'h6D4] = 8'hDA; font[11'h6D5] = 8'h92; font[11'h6D6] = 8'h92; font[11'h6D7] = 8'h92; font[11'h6D8] = 8'h92; font[11'h6D9] = 8'h92; font[11'h6DA] = 8'h00; font[11'h6DB] = 8'h00; font[11'h6DC] = 8'h00; font[11'h6DD] = 8'h00; font[11'h6DE] = 8'h00; font[11'h6DF] = 8'h00;
        // ---- n0x6E ----
        font[11'h6E0] = 8'h00; font[11'h6E1] = 8'h00; font[11'h6E2] = 8'h00; font[11'h6E3] = 8'h58; font[11'h6E4] = 8'h64; font[11'h6E5] = 8'h44; font[11'h6E6] = 8'h44; font[11'h6E7] = 8'h44; font[11'h6E8] = 8'h44; font[11'h6E9] = 8'h44; font[11'h6EA] = 8'h00; font[11'h6EB] = 8'h00; font[11'h6EC] = 8'h00; font[11'h6ED] = 8'h00; font[11'h6EE] = 8'h00; font[11'h6EF] = 8'h00;
        // ---- o0x6F ----
        font[11'h6F0] = 8'h00; font[11'h6F1] = 8'h00; font[11'h6F2] = 8'h00; font[11'h6F3] = 8'h3C; font[11'h6F4] = 8'h66; font[11'h6F5] = 8'h42; font[11'h6F6] = 8'h42; font[11'h6F7] = 8'h42; font[11'h6F8] = 8'h66; font[11'h6F9] = 8'h3C; font[11'h6FA] = 8'h00; font[11'h6FB] = 8'h00; font[11'h6FC] = 8'h00; font[11'h6FD] = 8'h00; font[11'h6FE] = 8'h00; font[11'h6FF] = 8'h00;
        // ---- p0x70 ----
        font[11'h700] = 8'h00; font[11'h701] = 8'h00; font[11'h702] = 8'h00; font[11'h703] = 8'h5C; font[11'h704] = 8'h66; font[11'h705] = 8'h42; font[11'h706] = 8'h42; font[11'h707] = 8'h42; font[11'h708] = 8'h44; font[11'h709] = 8'h78; font[11'h70A] = 8'h40; font[11'h70B] = 8'h40; font[11'h70C] = 8'h40; font[11'h70D] = 8'h00; font[11'h70E] = 8'h00; font[11'h70F] = 8'h00;
        // ---- q0x71 ----
        font[11'h710] = 8'h00; font[11'h711] = 8'h00; font[11'h712] = 8'h00; font[11'h713] = 8'h1E; font[11'h714] = 8'h22; font[11'h715] = 8'h42; font[11'h716] = 8'h42; font[11'h717] = 8'h42; font[11'h718] = 8'h66; font[11'h719] = 8'h3A; font[11'h71A] = 8'h02; font[11'h71B] = 8'h02; font[11'h71C] = 8'h02; font[11'h71D] = 8'h00; font[11'h71E] = 8'h00; font[11'h71F] = 8'h00;
        // ---- r0x72 ----
        font[11'h720] = 8'h00; font[11'h721] = 8'h00; font[11'h722] = 8'h00; font[11'h723] = 8'h58; font[11'h724] = 8'h64; font[11'h725] = 8'h44; font[11'h726] = 8'h40; font[11'h727] = 8'h40; font[11'h728] = 8'h40; font[11'h729] = 8'h40; font[11'h72A] = 8'h00; font[11'h72B] = 8'h00; font[11'h72C] = 8'h00; font[11'h72D] = 8'h00; font[11'h72E] = 8'h00; font[11'h72F] = 8'h00;
        // ---- s0x73 ----
        font[11'h730] = 8'h00; font[11'h731] = 8'h00; font[11'h732] = 8'h00; font[11'h733] = 8'h3C; font[11'h734] = 8'h40; font[11'h735] = 8'h40; font[11'h736] = 8'h38; font[11'h737] = 8'h04; font[11'h738] = 8'h04; font[11'h739] = 8'h78; font[11'h73A] = 8'h00; font[11'h73B] = 8'h00; font[11'h73C] = 8'h00; font[11'h73D] = 8'h00; font[11'h73E] = 8'h00; font[11'h73F] = 8'h00;
        // ---- t0x74 ----
        font[11'h740] = 8'h00; font[11'h741] = 8'h20; font[11'h742] = 8'h20; font[11'h743] = 8'hFC; font[11'h744] = 8'h20; font[11'h745] = 8'h20; font[11'h746] = 8'h20; font[11'h747] = 8'h20; font[11'h748] = 8'h20; font[11'h749] = 8'h1C; font[11'h74A] = 8'h00; font[11'h74B] = 8'h00; font[11'h74C] = 8'h00; font[11'h74D] = 8'h00; font[11'h74E] = 8'h00; font[11'h74F] = 8'h00;
        // ---- u0x75 ----
        font[11'h750] = 8'h00; font[11'h751] = 8'h00; font[11'h752] = 8'h00; font[11'h753] = 8'h44; font[11'h754] = 8'h44; font[11'h755] = 8'h44; font[11'h756] = 8'h44; font[11'h757] = 8'h44; font[11'h758] = 8'h4C; font[11'h759] = 8'h34; font[11'h75A] = 8'h00; font[11'h75B] = 8'h00; font[11'h75C] = 8'h00; font[11'h75D] = 8'h00; font[11'h75E] = 8'h00; font[11'h75F] = 8'h00;
        // ---- v0x76 ----
        font[11'h760] = 8'h00; font[11'h761] = 8'h00; font[11'h762] = 8'h00; font[11'h763] = 8'h22; font[11'h764] = 8'h22; font[11'h765] = 8'h32; font[11'h766] = 8'h14; font[11'h767] = 8'h14; font[11'h768] = 8'h14; font[11'h769] = 8'h08; font[11'h76A] = 8'h00; font[11'h76B] = 8'h00; font[11'h76C] = 8'h00; font[11'h76D] = 8'h00; font[11'h76E] = 8'h00; font[11'h76F] = 8'h00;
        // ---- w0x77 ----
        font[11'h770] = 8'h00; font[11'h771] = 8'h00; font[11'h772] = 8'h00; font[11'h773] = 8'h82; font[11'h774] = 8'h82; font[11'h775] = 8'h92; font[11'h776] = 8'hAA; font[11'h777] = 8'hAA; font[11'h778] = 8'hAA; font[11'h779] = 8'h44; font[11'h77A] = 8'h00; font[11'h77B] = 8'h00; font[11'h77C] = 8'h00; font[11'h77D] = 8'h00; font[11'h77E] = 8'h00; font[11'h77F] = 8'h00;
        // ---- x0x78 ----
        font[11'h780] = 8'h00; font[11'h781] = 8'h00; font[11'h782] = 8'h00; font[11'h783] = 8'h66; font[11'h784] = 8'h24; font[11'h785] = 8'h18; font[11'h786] = 8'h18; font[11'h787] = 8'h24; font[11'h788] = 8'h66; font[11'h789] = 8'hC3; font[11'h78A] = 8'h00; font[11'h78B] = 8'h00; font[11'h78C] = 8'h00; font[11'h78D] = 8'h00; font[11'h78E] = 8'h00; font[11'h78F] = 8'h00;
        // ---- y0x79 ----
        font[11'h790] = 8'h00; font[11'h791] = 8'h00; font[11'h792] = 8'h00; font[11'h793] = 8'h22; font[11'h794] = 8'h22; font[11'h795] = 8'h36; font[11'h796] = 8'h14; font[11'h797] = 8'h14; font[11'h798] = 8'h14; font[11'h799] = 8'h08; font[11'h79A] = 8'h08; font[11'h79B] = 8'h10; font[11'h79C] = 8'h70; font[11'h79D] = 8'h00; font[11'h79E] = 8'h00; font[11'h79F] = 8'h00;
        // ---- z0x7A ----
        font[11'h7A0] = 8'h00; font[11'h7A1] = 8'h00; font[11'h7A2] = 8'h00; font[11'h7A3] = 8'h7C; font[11'h7A4] = 8'h08; font[11'h7A5] = 8'h08; font[11'h7A6] = 8'h10; font[11'h7A7] = 8'h20; font[11'h7A8] = 8'h20; font[11'h7A9] = 8'h7C; font[11'h7AA] = 8'h00; font[11'h7AB] = 8'h00; font[11'h7AC] = 8'h00; font[11'h7AD] = 8'h00; font[11'h7AE] = 8'h00; font[11'h7AF] = 8'h00;
        // ---- {0x7B ----
        font[11'h7B0] = 8'h0C; font[11'h7B1] = 8'h10; font[11'h7B2] = 8'h10; font[11'h7B3] = 8'h10; font[11'h7B4] = 8'h10; font[11'h7B5] = 8'h10; font[11'h7B6] = 8'h60; font[11'h7B7] = 8'h10; font[11'h7B8] = 8'h10; font[11'h7B9] = 8'h10; font[11'h7BA] = 8'h10; font[11'h7BB] = 8'h10; font[11'h7BC] = 8'h0C; font[11'h7BD] = 8'h00; font[11'h7BE] = 8'h00; font[11'h7BF] = 8'h00;
        // ---- |0x7C ----
        font[11'h7C0] = 8'h10; font[11'h7C1] = 8'h10; font[11'h7C2] = 8'h10; font[11'h7C3] = 8'h10; font[11'h7C4] = 8'h10; font[11'h7C5] = 8'h10; font[11'h7C6] = 8'h10; font[11'h7C7] = 8'h10; font[11'h7C8] = 8'h10; font[11'h7C9] = 8'h10; font[11'h7CA] = 8'h10; font[11'h7CB] = 8'h10; font[11'h7CC] = 8'h10; font[11'h7CD] = 8'h00; font[11'h7CE] = 8'h00; font[11'h7CF] = 8'h00;
        // ---- }0x7D ----
        font[11'h7D0] = 8'h30; font[11'h7D1] = 8'h08; font[11'h7D2] = 8'h08; font[11'h7D3] = 8'h08; font[11'h7D4] = 8'h08; font[11'h7D5] = 8'h08; font[11'h7D6] = 8'h06; font[11'h7D7] = 8'h08; font[11'h7D8] = 8'h08; font[11'h7D9] = 8'h08; font[11'h7DA] = 8'h08; font[11'h7DB] = 8'h08; font[11'h7DC] = 8'h30; font[11'h7DD] = 8'h00; font[11'h7DE] = 8'h00; font[11'h7DF] = 8'h00;
        // ---- ~0x7E ----
        font[11'h7E0] = 8'h00; font[11'h7E1] = 8'h00; font[11'h7E2] = 8'h00; font[11'h7E3] = 8'h00; font[11'h7E4] = 8'h00; font[11'h7E5] = 8'hC4; font[11'h7E6] = 8'h24; font[11'h7E7] = 8'h18; font[11'h7E8] = 8'h00; font[11'h7E9] = 8'h00; font[11'h7EA] = 8'h00; font[11'h7EB] = 8'h00; font[11'h7EC] = 8'h00; font[11'h7ED] = 8'h00; font[11'h7EE] = 8'h00; font[11'h7EF] = 8'h00;
    end

    assign bits = font[{ch, row}];                          // 异步读（分布式 RAM）
endmodule
