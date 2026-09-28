#!/usr/bin/env bash
# 清除设备上星仓的签名材料与登录态。
#
# 什么时候需要：
#   · 改了 bundleName（旧证书/Profile 绑的是旧包名，预检会正确地拦下）
#   · 想从头走一遍准备流程
#
# 只删材料文件，不动应用本身，也不动别的应用。
set -euo pipefail

HDC="${HDC:-$HOME/Library/Caches/hap_installer/hdc_tools/hdc}"
DEVICE="${1:-${DEVICE:-}}"

if [ -z "$DEVICE" ]; then
  mapfile -t TARGETS < <("$HDC" list targets 2>/dev/null | grep -vE '^\[Empty\]|^$')
  if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "没有连接的设备。用法: $0 <device-id>" >&2
    exit 1
  fi
  DEVICE="${TARGETS[0]}"
  echo "未指定设备，用第一个：$DEVICE"
fi

# 星仓可能用过的包名（bundleName 改过名，两个都要清）
BUNDLES=(
  "com.tonghongxiang.hapstore"
  "com.tonghongxiang.quietstart"
)

echo "设备: $DEVICE"
for b in "${BUNDLES[@]}"; do
  base="/data/app/el2/100/base/$b"
  echo "--- $b"
  for rel in \
    "haps/entry/files/sign_material.json" \
    "haps/entry/files/agc_auth.json" \
    "haps/entry/files/identity.cer" \
    "haps/entry/files/identity.p7b" \
    "haps/entry/temp/identity.pem" \
    "haps/entry/temp/identity.csr" \
    "haps/entry/temp/identity.jks" \
    "haps/entry/cache/agc_auth.json" ; do
    if "$HDC" -t "$DEVICE" shell "[ -f $base/$rel ] && echo yes" 2>/dev/null | grep -q yes; then
      "$HDC" -t "$DEVICE" shell "rm -f $base/$rel" 2>/dev/null || true
      echo "    已删 $rel"
    fi
  done
done

echo
echo "完成。打开星仓 → 点「登录」，会用当前包名重新申请证书与 Profile。"
