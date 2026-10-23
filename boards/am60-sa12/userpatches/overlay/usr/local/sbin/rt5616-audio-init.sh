#!/bin/bash
# RT5616（3.5mm 耳机口）通路初始化
#
# 背景：CM3588-NAS 上 3.5mm 接的是 RT5616 codec（I2S fe470000）。
#       ALSA 只做最小初始化，不会打开 codec 内部的耳机混音通路，
#       结果就是声卡注册正常、播放无报错，但 3.5mm 完全无声。
#
# 关键通路： DAC1 -> HPO MIX(DAC1) -> HPVOL -> HP(耳机输出)
#
# 注意：按「声卡名 realtekrt5616co」动态解析卡号，而不是写死 -c 1，
#       因为 HDMI/DP 声卡的注册顺序变化会让 card 编号漂移。

set -u

CARD_NAME="realtekrt5616co"

# 1) 等声卡出现（最多 15 秒）
for _ in $(seq 1 30); do
    if [ -r /proc/asound/cards ] && grep -q "$CARD_NAME" /proc/asound/cards 2>/dev/null; then
        break
    fi
    sleep 0.5
done

# 2) 由声卡名解析 ALSA 卡号（抗卡序漂移）
CARD_ID=""
if [ -r /proc/asound/cards ]; then
    CARD_ID=$(awk -v n="$CARD_NAME" 'index($0, n) { gsub(/[ \[\]:]/, "", $1); print $1; exit }' /proc/asound/cards)
fi

if [ -z "$CARD_ID" ]; then
    echo "rt5616-audio-init: 未找到声卡 $CARD_NAME，跳过" >&2
    exit 0
fi

echo "rt5616-audio-init: 使用 card$CARD_ID ($CARD_NAME)"

# 3) DAC 输入源 = I2S（INF1），音量拉到 0dB
amixer -c "$CARD_ID" cset name='DAC MIXL INF1 Switch' on           >/dev/null 2>&1
amixer -c "$CARD_ID" cset name='DAC MIXR INF1 Switch' on           >/dev/null 2>&1
amixer -c "$CARD_ID" cset name='Stereo DAC MIXL DAC L1 Switch' on  >/dev/null 2>&1
amixer -c "$CARD_ID" cset name='Stereo DAC MIXR DAC R1 Switch' on  >/dev/null 2>&1
amixer -c "$CARD_ID" cset name='DAC1 Playback Volume' 175,175      >/dev/null 2>&1

# 4) 耳机通路（核心：HPO MIX DAC1 默认 off，这条不开就一定没声）
amixer -c "$CARD_ID" cset name='HPO MIX DAC1 Switch' on            >/dev/null 2>&1
amixer -c "$CARD_ID" cset name='HPO MIX HPVOL Switch' on           >/dev/null 2>&1
amixer -c "$CARD_ID" cset name='HPVOL Playback Switch' on,on       >/dev/null 2>&1
amixer -c "$CARD_ID" cset name='HP Playback Switch' on,on          >/dev/null 2>&1
amixer -c "$CARD_ID" cset name='HP Playback Volume' 31,31          >/dev/null 2>&1

# 5) 备用：线路输出通路（OUT / LOUT），部分底板接的是这个而不是 HP
amixer -c "$CARD_ID" cset name='OUT MIXL DAC L1 Switch' on         >/dev/null 2>&1
amixer -c "$CARD_ID" cset name='OUT MIXR DAC R1 Switch' on         >/dev/null 2>&1
amixer -c "$CARD_ID" cset name='LOUT MIX DAC L1 Switch' on         >/dev/null 2>&1
amixer -c "$CARD_ID" cset name='LOUT MIX DAC R1 Switch' on         >/dev/null 2>&1
amixer -c "$CARD_ID" cset name='OUT Playback Switch' on,on         >/dev/null 2>&1
amixer -c "$CARD_ID" cset name='OUT Playback Volume' 31,31         >/dev/null 2>&1

echo "rt5616-audio-init: 耳机通路已开启"
exit 0
