-- H96 MAX M9 (RK3576) — WirePlumber 0.4 友好名配置（noble / bookworm 用）
-- 仅重命名（GNOME 设置 → 声音 里的显示名），纯装饰性规则。
-- 严禁加 audio.channels / audio.position / api.alsa.* 等属性（会引入 64ch mclk 爆炸）。
-- 注意：WP 0.5（trixie）已不再读 main.lua.d/*.lua，trixie 请改
-- wireplumber.conf.d/50-h96-audio-names.conf（SPA-JSON 格式）。

-- ---- 设备级（设备选择器显示名）----
table.insert(alsa_monitor.rules, {
  matches = {
    { { "device.name", "equals", "alsa_card.platform-ht5010-sound" } },
  },
  apply_properties = {
    ["device.description"] = "3.5mm 耳机输出",
    ["device.nick"] = "3.5mm 耳机",
  },
})

table.insert(alsa_monitor.rules, {
  matches = {
    { { "device.name", "equals", "alsa_card.platform-spdif-tx0-sound" } },
  },
  apply_properties = {
    ["device.description"] = "SPDIF 数字输出",
    ["device.nick"] = "SPDIF",
  },
})

table.insert(alsa_monitor.rules, {
  matches = {
    { { "device.name", "equals", "alsa_card.platform-hdmi-sound" } },
  },
  apply_properties = {
    ["device.description"] = "HDMI 显示器音频",
    ["device.nick"] = "HDMI",
  },
})

-- ---- 节点级（输出设备下拉列表显示名）----
table.insert(alsa_monitor.rules, {
  matches = {
    { { "node.name", "matches", "alsa_output.platform-ht5010-sound.*" } },
  },
  apply_properties = {
    ["node.description"] = "3.5mm 耳机输出",
    ["node.nick"] = "3.5mm 耳机",
  },
})

table.insert(alsa_monitor.rules, {
  matches = {
    { { "node.name", "matches", "alsa_output.platform-spdif-tx0-sound.*" } },
  },
  apply_properties = {
    ["node.description"] = "SPDIF 数字输出",
    ["node.nick"] = "SPDIF",
  },
})

table.insert(alsa_monitor.rules, {
  matches = {
    { { "node.name", "matches", "alsa_output.platform-hdmi-sound.*" } },
  },
  apply_properties = {
    ["node.description"] = "HDMI 显示器音频",
    ["node.nick"] = "HDMI",
  },
})
