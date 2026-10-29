-- Neardi LZ200 (RK3576) 音频设备友好名称 + 声道映射
-- 适用: Armbian noble (Ubuntu 24.04) + WirePlumber 0.4.17 + PipeWire 1.0.5
-- 安装位置: /etc/wireplumber/main.lua.d/51-lz200-audio-names.lua
--
-- 注意:
--   1) WirePlumber 0.4.x 走 main.lua.d/*.lua（0.5.x 才走 wireplumber.conf.d/*.conf）
--   2) Device 与 Node 是两套独立规则，只写 node.* 时 Devices 列不会改名
--   3) "matches" 是 glob 通配，不是正则（写正则会静默不匹配）
--   4) 声道映射修正：RK 的 platform-*-sound (es8388/dp0/hdmi) ALSA 设备上报的
--      声道数异常（audio.channels=64、Channel Map=aux0,aux1），GNOME 声音面板
--      因此无法显示左右声道（缺 L/R 测试、平衡滑块）。这些设备实为标准 2ch
--      立体声，故在 node 规则里强制 audio.channels=2 / audio.position=FL,FR。
--      （ES8323 / HDMI / DP 物理均为 L=ch0、R=ch1，声明 FL,FR 不会破坏音频。）

alsa_monitor.rules = {
    ------------------------------------------------------------------
    -- 1) ES8323 板载 Codec：3.5mm 耳机输出 / 麦克风输入
    ------------------------------------------------------------------
    {
        matches = {
            {
                { "device.name", "matches", "alsa_card.platform-es8388-sound" },
            },
        },
        apply_properties = {
            ["device.description"] = "3.5mm 耳机 (ES8323)",
            ["device.nick"]        = "3.5mm 耳机",
        },
    },
    {
        matches = {
            {
                { "node.name", "matches", "alsa_output.platform-es8388-sound*" },
            },
        },
        apply_properties = {
            ["node.description"] = "3.5mm 耳机 (ES8323)",
            ["node.nick"]        = "3.5mm 耳机",
            -- 提升优先级，确保 3.5mm 被选为默认输出而不是 HDMI/DP
            ["priority.driver"]  = 2000,
            ["priority.session"] = 2000,
            -- 修正声道映射：aux0,aux1 -> 标准立体声
            ["audio.channels"]   = 2,
            ["audio.position"]   = "FL,FR",
        },
    },
    {
        matches = {
            {
                { "node.name", "matches", "alsa_input.platform-es8388-sound*" },
            },
        },
        apply_properties = {
            ["node.description"] = "板载麦克风 (ES8323)",
            ["node.nick"]        = "板载麦克风",
            ["priority.driver"]  = 2000,
            ["priority.session"] = 2000,
        },
    },

    ------------------------------------------------------------------
    -- 2) HDMI 音频输出
    ------------------------------------------------------------------
    {
        matches = {
            {
                { "device.name", "matches", "alsa_card.platform-hdmi-sound" },
            },
        },
        apply_properties = {
            ["device.description"] = "HDMI 音频输出",
            ["device.nick"]        = "HDMI",
        },
    },
    {
        matches = {
            {
                { "node.name", "matches", "alsa_output.platform-hdmi-sound*" },
            },
        },
        apply_properties = {
            ["node.description"] = "HDMI 音频输出",
            ["device.nick"]      = "HDMI",
            -- 修正声道映射
            ["audio.channels"]   = 2,
            ["audio.position"]   = "FL,FR",
        },
    },

    ------------------------------------------------------------------
    -- 3) DP0 (USB-C) 音频输出
    ------------------------------------------------------------------
    {
        matches = {
            {
                { "device.name", "matches", "alsa_card.platform-dp0-sound" },
            },
        },
        apply_properties = {
            ["device.description"] = "DP (USB-C) 音频输出",
            ["device.nick"]        = "DP",
        },
    },
    {
        matches = {
            {
                { "node.name", "matches", "alsa_output.platform-dp0-sound*" },
            },
        },
        apply_properties = {
            ["node.description"] = "DP (USB-C) 音频输出",
            ["device.nick"]      = "DP",
            -- 修正声道映射
            ["audio.channels"]   = 2,
            ["audio.position"]   = "FL,FR",
        },
    },
    ------------------------------------------------------------------
    -- 4) USB 声卡（Type-C 扩展坞内置等）：不改名，保持系统默认识别名
    --
    --    4a) 所有 USB 输出统一提优先级：插入时自动接管默认输出，
    --        拔出后回落 3.5mm。此条不改声道、不改名。
    ------------------------------------------------------------------
    {
        matches = {
            {
                { "node.name", "matches", "alsa_output.usb-*" },
            },
        },
        apply_properties = {
            ["priority.driver"]  = 2200,
            ["priority.session"] = 2200,
        },
    },
    ------------------------------------------------------------------
    --    4b) 【条件式】仅当 USB 声卡把声道数误报为 64 时才纠偏。
    --
    --    背景（2026-10-29）：USB 声卡会出现 Channel Map 已是 FL,FR 但
    --    audio.channels 仍为 64（= SPA_AUDIO_MAX_CHANNELS，即"未知"回退值）
    --    的自相矛盾状态。读 audio.channels 的消费者（GNOME 声音面板）会把
    --    它当多声道设备，于是不显示左右声道测试/平衡滑块。
    --
    --    为什么不无条件强制 2ch：那会把真正的 5.1/7.1 USB 声卡降级成立体声。
    --    加 audio.channels == 64 条件后，只有"误报"的设备被修，正常上报多声道
    --    的设备保持原样 —— 换任何型号的扩展坞都通用，且不会误伤。
    --
    --    已实测（WP 0.4.17）：条件被真正求值（负向对照用 equals "1" 时规则不生效，
    --    声道数回到 64），故本写法可用。
    ------------------------------------------------------------------
    {
        matches = {
            {
                { "node.name", "matches", "alsa_output.usb-*" },
                { "audio.channels", "equals", "64" },
            },
        },
        apply_properties = {
            ["priority.driver"]  = 2200,
            ["priority.session"] = 2200,
            ["audio.channels"]   = 2,
            ["audio.position"]   = "FL,FR",
        },
    },
    {
        matches = {
            {
                { "node.name", "matches", "alsa_input.usb-*" },
            },
        },
        apply_properties = {
            ["priority.driver"]  = 2200,
            ["priority.session"] = 2200,
        },
    },
}
