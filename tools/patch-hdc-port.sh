#!/usr/bin/env bash
# Copyright QuietStart contributors. SPDX-License-Identifier: MIT
#
# 给内嵌 hdc（libhdc_z.so）换一个独占服务端口。
#
# ── 为什么需要这个补丁 ────────────────────────────────────────────────
# 随包分发的 libhdc_z.so（来自轻启的 ohos_adapter）把 hdc 服务端口
# **硬编码成 18710**，客户端与服务端各有一条字面量：
#
#   Hdc::cmd()      → RunClientMode("127.0.0.1:18710")        客户端连哪
#   napi server()   → RunServerMode("::ffff:127.0.0.1:18710") 服务端听哪
#
# 本机安装了 `com.tonghongxiang.xiaobaiquietstart`（小白轻启）时，它用的是
# **同一个 .so、同一个端口**，先启动的那个会占住 127.0.0.1:18710：
#
#   channelHost ::ffff:127.0.0.1, port: 18710
#   uv_listen -98 address already in use      ← 后来的应用绑不上
#   SetTCPListen failed
#   ...
#   Connect server failed                     ← 客户端也连不上
#
# 结果就是「点连接没反应、信任弹窗不出现」——hdc 命令根本没发出去。
#
# `OHOS_HDC_SERVER_PORT` 环境变量改不了这个：它只影响服务端监听，
# 客户端那条字面量不受影响（两端会不一致），而且 ArkTS 层也无法设置
# 进程环境变量。所以只能就地替换这两条字面量（字节数相同，不动结构）。
#
# ── 改的是哪些文件 ────────────────────────────────────────────────────
#   1) app/plugins/ohos_adapter/ohos/libs/arm64-v8a/libhdc_z.so
#      （插件工程里的原始 .so，将来重建 HAR 的源头）
#   2) app/ohos/har/ohos_adapter.har
#      （**构建真正使用的产物**：oh-package.json5 overrides 指向它）
#
# 用法：
#   ./tools/patch-hdc-port.sh            # 补丁到默认端口 28710
#   ./tools/patch-hdc-port.sh 28711      # 指定端口（必须 5 位数字）
#   ./tools/patch-hdc-port.sh --verify   # 只检查当前状态，不改文件

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_SO="$ROOT/app/plugins/ohos_adapter/ohos/libs/arm64-v8a/libhdc_z.so"
HAR="$ROOT/app/ohos/har/ohos_adapter.har"
HAR_MEMBER="package/libs/arm64-v8a/libhdc_z.so"

OLD="18710"
NEW="28710"
VERIFY_ONLY=0

case "${1:-}" in
  --verify) VERIFY_ONLY=1;;
  "")       ;;
  *)        NEW="$1";;
esac

if ! [[ "$NEW" =~ ^[0-9]{5}$ ]]; then
  echo "✗ 端口必须是 5 位数字（要与原值等长，避免改变文件结构）：$NEW" >&2
  exit 1
fi
if [ "$NEW" = "$OLD" ]; then
  echo "✗ 新端口不能等于原值 $OLD" >&2
  exit 1
fi

[ -f "$PLUGIN_SO" ] || { echo "✗ 未找到 $PLUGIN_SO" >&2; exit 1; }
[ -f "$HAR" ] || { echo "✗ 未找到 $HAR" >&2; exit 1; }

echo "=== 内嵌 hdc 端口补丁 ==="
echo "  原端口: $OLD"
echo "  新端口: $NEW"
echo

python3 - "$PLUGIN_SO" "$HAR" "$HAR_MEMBER" "$OLD" "$NEW" "$VERIFY_ONLY" <<'PY'
import io, os, shutil, sys, tarfile

plugin_so, har, member, old, new, verify_only = sys.argv[1:7]
old_b, new_b = old.encode(), new.encode()
verify_only = verify_only == '1'

def count(blob):
    return blob.count(old_b), blob.count(new_b)

def scan(blob, where):
    o, n = count(blob)
    if o == 0 and n == 0:
        print(f"  ✗ {where}: 既没有 {old} 也没有 {new}，不是预期的 libhdc_z.so")
        return False
    if o not in (0, 2):
        print(f"  ✗ {where}: 出现了 {o} 处 {old}（预期 2 处），拒绝改动")
        return False
    print(f"  · {where}: {old}×{o}  {new}×{n}")
    return True

def patch(blob):
    # 只有两处，且都是“地址字面量”里的端口，等长替换是安全的
    return blob.replace(old_b, new_b)

# ── 1) 插件工程里的原始 .so ──
plugin = open(plugin_so, 'rb').read()
if not scan(plugin, os.path.basename(plugin_so)):
    sys.exit(1)

# ── 2) HAR（构建真正使用的产物）──
with tarfile.open(har, 'r:gz') as tf:
    members = tf.getmembers()
    payload = {}
    for m in members:
        payload[m.name] = tf.extractfile(m).read() if m.isfile() else None

if member not in payload:
    print(f"  ✗ HAR 里没有 {member}")
    sys.exit(1)
inner = payload[member]
if not scan(inner, f"{os.path.basename(har)} :: {member}"):
    sys.exit(1)

if verify_only:
    ok = count(plugin)[0] == 0 and count(inner)[0] == 0
    print()
    print("  ✅ 已打补丁，端口 " + new if ok else "  ⚠️ 仍是原端口 " + old)
    sys.exit(0)

# 写入：先 .so，再重打 HAR（保留成员顺序/时间戳，只换这一个成员的内容）
changed = False
if count(plugin)[0]:
    shutil.copy2(plugin_so, plugin_so + '.orig')
    open(plugin_so, 'wb').write(patch(plugin))
    print(f"  ✓ 已改写 {plugin_so}（原件备份为 .orig）")
    changed = True

if count(inner)[0]:
    payload[member] = patch(inner)
    tmp = har + '.tmp'
    with tarfile.open(tmp, 'w:gz') as tf:
        for m in members:
            data = payload[m.name]
            if data is None:
                tf.addfile(m)
            else:
                m.size = len(data)
                tf.addfile(m, io.BytesIO(data))
    os.replace(tmp, har)
    print(f"  ✓ 已改写 {har}")
    changed = True

if not changed:
    print("  （无需改动）")
PY

echo
echo "=== 校验 ==="
python3 - "$HAR" "$HAR_MEMBER" "$NEW" "$OLD" <<'PY'
import sys, tarfile
har, member, new, old = sys.argv[1:5]
with tarfile.open(har, 'r:gz') as tf:
    blob = tf.extractfile(member).read()
print(f"  HAR 内 {member}: {old}×{blob.count(old.encode())}  {new}×{blob.count(new.encode())}")
sys.exit(0 if blob.count(old.encode()) == 0 else 1)
PY

echo
echo "下一步：清掉 ohpm 缓存里的旧副本，再重新构建"
echo "  rm -rf \"$ROOT/app/ohos/oh_modules/.ohpm/ohos_adapter@\"* \\"
echo "         \"$ROOT/app/ohos/oh_modules/ohos_adapter\""
echo "  ./tools/build-app.sh release --base <...> --pin <...>"
