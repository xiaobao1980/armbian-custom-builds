#!/bin/sh
# h96-m9-audio-fix.sh - H96 MAX M9 (RK3576) 3.5mm (HT5010) SAI routing fix.
#
# ROOT CAUSE: HT5010 codec I2S data pin is wired to SAI1 SDO2 ONLY (DTS
# pinctrl sai1m0_sdo2; SDO0/1/3 pins are NOT muxed). The RK SAI IP resets
# routing PATH0 (playback) -> SDO0. SDO0's pin is un-muxed on this board, so
# audio never reaches the codec -> 3.5mm silent.
# FIX: route PATH0 -> SDO2 via the per-lane mux ('Transmit SDO2 Source
# Select' = From PATH0). That is the ONLY control needed.
#
# !!! DO NOT touch 'Transmit SDOx Select' (set it to Auto) !!!
# That control is NOT "which SDO pin to enable" - it is the TX LANE COUNT
# (rockchip_sai_tx_lanes_put() writes the enum index straight into
# sai->tx_lanes). rockchip_sai_hw_params() then does
#     ch_per_lane = params_channels / lanes
#     bclk_rate   = fw_ratio * slot_width * ch_per_lane * rate
# so for a 2ch stream setting it to 'SDOx3' (=3 lanes) gives
# ch_per_lane = 2/3 = 0 -> bclk_rate = 0 -> DIV_ROUND_CLOSEST(mclk, 0)
# returns 0 on arm64 (UDIV by zero does not trap) -> mclk_req_rate = 0 ->
#     "Mismatch mclk: 12288000, expected 0 (+/- 5Hz)"  -> -EINVAL
# and speaker-test dies with "Unable to set hw params: Invalid argument".
# Auto (0) lets rockchip_sai_lanes_auto() pick 1 lane for 2ch, which is
# correct; the SDO2 source mux still puts PATH0 on the SDO2 pin.
#
# The WirePlumber 2ch lua (50-h96-audio.lua) is the complementary userspace
# part (gives GNOME L/R test buttons); this script is the hardware routing part.
# The control name prefix is kernel/driver dependent (SAI1 / 2a610000.sai /
# rockchip-sai), so we match by SUFFIX.
set -u
ACTION="${1:-start}"
log() { logger -t h96-m9-audio "$*"; echo "h96-m9-audio: $*" >&2; }

# Locate the 3.5mm (HT5010) card (retry until registered).
# NOTE: the card's aplay -l name is RENAMED to "3.5mm Audio" by the udev
# naming rule (90-naming-audios.rules), so matching on "ht5010" FAILS.
# Match on the stable hardware DAI link name `2a610000.sai-dummy_codec`
# instead. This is the SAI1 (2a610000.sai) CPU DAI wired to the dummy-codec
# / HT5010 codec for the 3.5mm jack.
card=""
for i in $(seq 1 30); do
    card=$(aplay -l 2>/dev/null | awk '/2a610000.sai-dummy_codec/ {print $2}' | tr -d ':')
    [ -n "$card" ] && break
    sleep 1
done
[ -z "$card" ] && card=$(aplay -l 2>/dev/null | awk '/dummy_codec/ {print $2}' | tr -d ':' | head -n1)
if [ -z "$card" ]; then
    log "ht5010 sound card not found; action '$ACTION' skipped"
    exit 0
fi

case "$ACTION" in
    start)
        # 1) Route PATH0 -> SDO2 (From PATH0 = enum index 0). THE actual fix.
        #    Equivalent static form in DTS: rockchip,sai-tx-route = <0 1 0 3>
        #    (4 elements = SDO0..SDO3 source PATH; a shorter list makes SAI
        #     probe fail with -EINVAL and the card never registers).
        SDO2=$(amixer -c "$card" controls 2>/dev/null \
             | sed -n "s/.*name='\([^']*Transmit SDO2 Source Select\)'/\1/p" | head -n1)
        if [ -n "$SDO2" ]; then
            if amixer -c "$card" cset "name=$SDO2" 0 >/dev/null 2>&1; then
                log "SAI '$SDO2' = 0 (PATH0 -> SDO2)"
            else
                log "FAILED to set '$SDO2' on card $card (non-fatal)"
            fi
        else
            log "control 'Transmit SDO2 Source Select' NOT FOUND on card $card"
        fi

        # 2) Force TX lane count back to Auto (0). This is a REPAIR step:
        #    a stale alsactl state (or an older buggy revision of this very
        #    script) may have left it at 'SDOx3' (=3 lanes), which breaks
        #    hw_params for 2ch playback (see the long comment on top).
        SDOG=$(amixer -c "$card" controls 2>/dev/null \
             | sed -n "s/.*name='\([^']*Transmit SDOx Select\)'/\1/p" | head -n1)
        if [ -n "$SDOG" ]; then
            if amixer -c "$card" cset "name=$SDOG" 0 >/dev/null 2>&1; then
                log "SAI '$SDOG' = 0 (Auto lane count - required for 2ch)"
            else
                log "FAILED to set '$SDOG'=0 on card $card (non-fatal)"
            fi
        else
            log "control 'Transmit SDOx Select' NOT FOUND on card $card"
        fi
        ;;
    stop)
        :   # No hardware mute exists for the dummy-codec/HT5010; nothing to do.
        ;;
    *)
        log "unknown action '$ACTION'"
        exit 1
        ;;
esac
exit 0
