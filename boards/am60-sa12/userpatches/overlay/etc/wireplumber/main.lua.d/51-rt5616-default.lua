-- CM3588-NAS：让 3.5mm 耳机（RT5616）成为默认输出设备
-- WirePlumber 0.4.x 的 Lua 配置语法（0.5 才改成 SPA/JSON 的 .conf）
--
-- 背景：板上有 4 个输出声卡（hdmi0 / hdmi1 / dp0 / rt5616），
--       PipeWire 默认挑了 HDMI0，所以桌面声音全走 HDMI，3.5mm 无声。

-- 1) 设备改名，避免 GNOME 设置里四个都叫 "Built-in Audio"
table.insert(alsa_monitor.rules, {
  matches = {
    { { "device.name", "matches", "alsa_card.platform-rt5616-sound" } },
  },
  apply_properties = {
    ["device.description"] = "3.5mm 耳机 (RT5616)",
  },
})

table.insert(alsa_monitor.rules, {
  matches = {
    { { "device.name", "matches", "alsa_card.platform-hdmi0-sound" } },
  },
  apply_properties = { ["device.description"] = "HDMI 0 数字输出" },
})

table.insert(alsa_monitor.rules, {
  matches = {
    { { "device.name", "matches", "alsa_card.platform-hdmi1-sound" } },
  },
  apply_properties = { ["device.description"] = "HDMI 1 数字输出" },
})

table.insert(alsa_monitor.rules, {
  matches = {
    { { "device.name", "matches", "alsa_card.platform-dp0-sound" } },
  },
  apply_properties = { ["device.description"] = "DP 0 数字输出" },
})

-- 2) 提升 3.5mm sink 的优先级（priority.session 决定谁当默认），压过 HDMI/DP
table.insert(alsa_monitor.rules, {
  matches = {
    { { "node.name", "matches", "alsa_output.platform-rt5616-sound*" } },
  },
  apply_properties = {
    ["node.description"] = "3.5mm 耳机 (RT5616)",
    ["priority.driver"] = 2000,
    ["priority.session"] = 2000,
  },
})

-- 3) 同时压低 HDMI/DP 的优先级（matches 里多个条件组之间是 OR 关系）
table.insert(alsa_monitor.rules, {
  matches = {
    { { "node.name", "matches", "alsa_output.platform-hdmi*-sound*" } },
    { { "node.name", "matches", "alsa_output.platform-dp*-sound*" } },
  },
  apply_properties = {
    ["priority.session"] = 900,
  },
})
