#!/bin/zsh
# 在电脑浏览器里测试模块界面：用手机上真实的 status 数据，模拟 KernelSU 的 ksu.exec（status 延迟 N 秒，和真机一样慢）。
# 用法：ADB=adb路径 ANDROID_SERIAL=序列号 zsh tests/ui-harness.sh [延迟秒数，默认 5] [端口，默认 8765]
#   然后打开 http://127.0.0.1:端口/index.html
#   · 会改东西的命令（set / backup / restore …）不会发到手机，只返回成功，界面上可以随便点
#   · 页面里 window.__execLog 记录了界面发出的全部命令，window.__status 是返回的数据（可以改了再点刷新）
# 不连手机时：直接在浏览器打开 ksu-tt-keepalive/webroot/index.html，用界面自带的演示数据。
set -eu
ROOT=${0:A:h:h}
DELAY=${1:-5}; PORT=${2:-8765}
# adb：ADB 变量 → 往上几层找 tavern/tools/platform-tools/adb（主目录和临时工作区都能找到）→ PATH
if [[ -z ${ADB:-} ]]; then
    d=$ROOT; while [[ $d != / && ! -x $d/tools/platform-tools/adb ]]; do d=${d:h}; done
    [[ -x $d/tools/platform-tools/adb ]] && ADB=$d/tools/platform-tools/adb || ADB=$(command -v adb)
fi
W=$(mktemp -d "${TMPDIR:-/tmp}/tt-ui-harness.XXXXXX")
SER=(); [[ -n ${ANDROID_SERIAL:-} ]] && SER=(-s "$ANDROID_SERIAL")
"$ADB" "${SER[@]}" shell "su -c 'sh /data/adb/modules/claudemax_tt_keepalive/ui.sh status'" | tr -d '\r' > "$W/status.json"
python3 - "$ROOT/ksu-tt-keepalive/webroot/index.html" "$W" "$DELAY" <<'PY'
import sys, json
src, w, delay = open(sys.argv[1]).read(), sys.argv[2], int(sys.argv[3]) * 1000
st = open(w + '/status.json').read().strip()
json.loads(st)   # 手机上的输出必须是合法 JSON
inj = '''<script>
window.__status = %s; window.__execLog = [];
window.ksu = { exec(cmd, opt, cb) { window.__execLog.push(cmd); const slow = cmd.includes(' status');
  setTimeout(() => { const out = slow ? JSON.stringify(Object.assign({}, window.__status, { now: Math.floor(Date.now() / 1000) }))
    : / set /.test(cmd) ? '{"ok":true}' : '{}'; window[cb](0, out, ''); }, slow ? %d : 300); } };
</script>''' % (st, delay)
i = src.find('<head>') + len('<head>')
open(w + '/index.html', 'w').write(src[:i] + inj + src[i:])
PY
print "打开 http://127.0.0.1:$PORT/index.html （Ctrl+C 结束）"
cd "$W" && exec python3 -m http.server "$PORT" --bind 127.0.0.1
