#!/bin/bash
# --------------------------------------------------------------------------
# restore_rgb.sh —— 开机/登录后恢复上次保存的键盘灯效
#
# 由 launchd (com.macconsole.rgbrestore) 在登录时调用。
# USB 设备在开机初期可能尚未枚举完成，因此这里做有限次重试。
# 日志: /tmp/macconsole-rgb.log
#
# 2026-10-20 v2.5.0：去 Python 化，改调随包 mcutil（Contents/MacOS/mcutil）。
# 旧版调用：/usr/bin/python3 rgbkb.py profile / apply
# --------------------------------------------------------------------------
PROJ="$(cd "$(dirname "$0")" && pwd)"          # .../Contents/Resources/native
MCUTIL="$PROJ/../../MacOS/mcutil"
[ -x "$MCUTIL" ] || MCUTIL="/Applications/Mac控制台.app/Contents/MacOS/mcutil"
if [ ! -x "$MCUTIL" ]; then
    echo "[$(date '+%F %T')] 找不到 mcutil（试过 $PROJ/../../MacOS/mcutil 与 /Applications）"
    exit 1
fi

# 没有配置就不用折腾（mcutil rgb profile 无配置时打印 (无配置)）
if "$MCUTIL" rgb profile 2>/dev/null | grep -q "^(无配置)"; then
    echo "[$(date '+%F %T')] 无配置，跳过"
    exit 0
fi

for i in $(seq 1 30); do
    out="$("$MCUTIL" rgb apply 2>&1)"
    if echo "$out" | grep -q '"ok": true'; then
        echo "[$(date '+%F %T')] 第 ${i} 次尝试恢复成功: $out"
        exit 0
    fi
    sleep 2
done

echo "[$(date '+%F %T')] 重试 30 次仍未恢复，最后输出: $out"
exit 1
