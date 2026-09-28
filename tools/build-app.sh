#!/usr/bin/env bash
# Copyright QuietStart contributors. SPDX-License-Identifier: MIT
#
# 商店 App 构建脚本 —— 封装鸿蒙 Flutter 构建所需的全部环境配置。
#
# ── 为什么需要这个脚本 ────────────────────────────────────────────────
# 构建 HAP 需要同时满足四个环境条件，任何一个不对都会得到看不出原因的报错：
#
#   1) 鸿蒙 Flutter 分支（不是官方 Flutter）—— 提供 `flutter build hap`
#   2) DEVECO_SDK_HOME 指向 DevEco 的 SDK
#   3) JAVA_HOME 指向 DevEco 自带的 JBR（hvigor 需要 Java 运行打包工具）
#   4) PATH 里要有 hvigorw / ohpm / node（都在 DevEco tools 下）
#
# 还有一个**极易踩的坑**：`compatibleSdkVersion` 的格式随 API 版本变化：
#   · API 10~25  → '5.0.0(12)'  形式
#   · API 26+    → '26.0.0'     形式
# 写错会报 `00306042 Specification Limit Violation`，而错误信息只在
# .hvigor/outputs/build-logs/build.log 里，命令行看不到。
#
# 用法：
#   ./tools/build-app.sh            # debug 构建
#   ./tools/build-app.sh release    # release 构建
#
# 可选（启用 HTTPS 元数据 + 证书 pinning，见 tools/deploy-tls.sh）：
#   ./tools/build-app.sh release --base https://store.example.com --pin <sha256>
#   也可用环境变量 HAPSTORE_API_BASE / HAPSTORE_API_PIN

set -euo pipefail

MODE="${1:-debug}"
shift || true

BASE="${HAPSTORE_API_BASE:-https://store.example.com}"
PIN="${HAPSTORE_API_PIN:-9a75775bef85e2ddca908529a708b426a0aa174525f9c133fd55ea615adb9b4f}"
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 || shift;;
    --pin)  PIN="${2:-}";  shift 2 || shift;;
    *) shift;;
  esac
done

DEFINES=()
[ -n "$BASE" ] && DEFINES+=(--dart-define=HAPSTORE_API_BASE="$BASE")
[ -n "$PIN" ] && DEFINES+=(--dart-define=HAPSTORE_API_PIN="$PIN")

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/app"

FLUTTER_OHOS="${FLUTTER_OHOS:-$HOME/Documents/harness_workspace/orbit-admin/.toolchains/flutter-ohos-3.7.12-retry}"
DEVECO="${DEVECO:-/Applications/DevEco-Studio.app/Contents}"

echo "=== 环境检查 ==="
[ -x "$FLUTTER_OHOS/bin/flutter" ] || { echo "  ✗ 鸿蒙 Flutter 未找到: $FLUTTER_OHOS"; exit 1; }
[ -d "$DEVECO/sdk" ] || { echo "  ✗ DevEco SDK 未找到: $DEVECO/sdk"; exit 1; }
[ -x "$DEVECO/jbr/Contents/Home/bin/java" ] || { echo "  ✗ DevEco JBR 未找到"; exit 1; }
echo "  ✓ 鸿蒙 Flutter: $("$FLUTTER_OHOS/bin/flutter" --version 2>/dev/null | head -1)"
echo "  ✓ DevEco SDK:   $DEVECO/sdk"

export PATH="$FLUTTER_OHOS/bin:$DEVECO/tools/hvigor/bin:$DEVECO/tools/ohpm/bin:$DEVECO/tools/node/bin:$DEVECO/jbr/Contents/Home/bin:$PATH"
export DEVECO_SDK_HOME="$DEVECO/sdk"
export JAVA_HOME="$DEVECO/jbr/Contents/Home"
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"

echo
echo "=== 校验 compatibleSdkVersion 格式 ==="
BP="$APP/ohos/build-profile.json5"
V=$(python3 -c "
import re
s=open('$BP').read()
m=re.search(r'\"compatibleSdkVersion\"\s*:\s*\"([^\"]+)\"', s)
print(m.group(1) if m else '')
")
echo "  当前值: ${V:-（未设置）}"
python3 - "$V" <<'PY'
import re, sys
v = sys.argv[1] if len(sys.argv) > 1 else ''
if not v:
    print("  ✗ 未找到 compatibleSdkVersion"); sys.exit(1)
m = re.match(r'^(\d+)\.(\d+)\.(\d+)\((\d+)\)$', v)
if m:
    api = int(m.group(4)); print(f"  → 旧格式，API {api}")
    if api >= 26:
        print("  ✗ API>=26 必须用 'N.0.0' 格式，否则报 00306042"); sys.exit(1)
    sys.exit(0)
m = re.match(r'^(\d+)\.(\d+)\.(\d+)$', v)
if m:
    print(f"  → 新格式，API {int(m.group(1))}")
    sys.exit(0)
print(f"  ✗ 格式无法识别: {v}"); sys.exit(1)
PY

cd "$APP"
echo
echo "=== pub get ==="
flutter pub get 2>&1 | tail -3

echo
echo "=== 静态分析 ==="
flutter analyze lib/ 2>&1 | tail -3

echo
echo "=== 元数据 API 配置 ==="
echo "  base = $BASE"
echo "  pin  = $PIN"

echo
echo "=== 构建 HAP ($MODE) ==="
BUILD_MARKER="$(mktemp)"
trap 'rm -f "$BUILD_MARKER"' EXIT
if ! flutter build hap "--$MODE" --target-platform ohos-arm64 ${DEFINES[@]+"${DEFINES[@]}"} 2>&1 | tail -8; then
  # 未配置 Hvigor 签名时 Flutter 会报告找不到 signed.hap；项目随后由
  # sign_cli.dart 签名。只接受本轮新生成的 unsigned.hap。
  if ! find "$APP/ohos/entry/build" -name '*unsigned.hap' -newer "$BUILD_MARKER" -print -quit | grep -q .; then
    echo "  ✗ 构建失败，且没有本轮生成的未签名 HAP"
    exit 1
  fi
  echo "  ✓ 已生成未签名 HAP，交由 sign_cli.dart 签名"
fi

echo
echo "=== 产物 ==="
HAP=$(find "$APP/ohos/entry/build" -name '*unsigned.hap' -newer "$BUILD_MARKER" 2>/dev/null | head -1)
if [ -n "$HAP" ]; then
  HAP_BYTES=$(stat -f '%z' "$HAP")
  printf '  %.1f MB  %s\n' "$(awk "BEGIN {print $HAP_BYTES/1048576}")" "$HAP"
  echo
  echo "  下一步：签名后安装"
  echo "    cd \"$ROOT/core/logic\" && dart run tool/sign_cli.dart \\"
  echo "      --input   '$HAP' \\"
  echo "      --output  /tmp/hapstore-signed.hap \\"
  echo "      --cert    ~/Documents/hap_installer/store/hapstore-debug.cer \\"
  echo "      --profile ~/Documents/hap_installer/store/com_tonghongxiang_hapstore.p7b \\"
  echo "      --key     ~/Documents/hap_installer/store/key.pem \\"
  echo "      --signer  ~/Library/Caches/hap_installer/hdc_tools/signer \\"
  echo "      --udid    4D32998F6E8174CAABD6EF5B2527D35F1D983EC7067970B52E8F865E0D8B92FC \\"
  echo "      --install"
  echo
  echo "  ⚠️ Profile 的 bundleName 必须等于 com.tonghongxiang.hapstore"
  echo "  ⚠️ 证书/Profile 由 tools/make_hapstore_profile.dart 生成（与 key.pem 配对）"
else
  echo "  ✗ 未找到新生成的 HAP"
  echo "  排查：tail -60 \"$APP/ohos/.hvigor/outputs/build-logs/build.log\""
  exit 1
fi
