#!/bin/sh
# 从 CHANGELOG.md 里取出某个 tag 对应的那一节，拼成 GitHub Release 的正文。
#
#   sh .github/scripts/release_notes.sh v1.8.14  > /tmp/body.md
#
# 规则：
#   - 只认 `## <版本>` 开头的二级标题，且版本号后面**不能紧跟数字或点**
#     （否则 v1.8.1 会吃掉 1.8.14）。用 grep -E 做这件事，只涉及 ASCII 字符类，
#     不受 locale 影响；正文切段用行号 + awk 区间，不碰多字节字符
#     （macOS 的 awk 在 C locale 下对中文 substr 会直接报 towc 失败）。
#   - 取版本标题之后、到下一个同级 `## ` 标题之前的全部内容。
#   - 找不到就返回 1，调用方自己决定回退，不许静默发一个空正文。
set -eu
LC_ALL=C
export LC_ALL

TAG="${1:-}"
[ -n "$TAG" ] || { echo "用法: sh $0 <tag>" >&2; exit 2; }
VER="${TAG#v}"

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CL="$HERE/../../CHANGELOG.md"
[ -f "$CL" ] || { echo "找不到 CHANGELOG.md" >&2; exit 1; }

VER_RE=$(printf '%s' "$VER" | sed 's/[.]/\\./g')
START=$(grep -nE "^## ${VER_RE}([^0-9.]|$)" "$CL" | head -1 | cut -d: -f1 || true)
[ -n "$START" ] || { echo "CHANGELOG.md 里没有 $VER 这一节" >&2; exit 1; }

END=$(awk -v s="$START" 'NR > s && /^## / { print NR; exit }' "$CL")
[ -n "$END" ] || END=$(( $(wc -l < "$CL") + 1 ))

SEC=$(awk -v s="$START" -v e="$END" 'NR >= s && NR < e' "$CL" | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}')
[ -n "$SEC" ] || { echo "CHANGELOG.md 里 $VER 这一节是空的" >&2; exit 1; }

printf '%s\n' "$SEC"
printf '\n---\n\n'
cat <<EOF
## 下载

| 文件 | 用途 |
| --- | --- |
| \`luci-app-parentcontrol_${VER}-*_all.ipk\` | 常规安装，路由器上有 opkg 时用它 |
| \`luci-app-parentcontrol_${VER}-*.run\` | 自解压安装器，不依赖 opkg |
| \`SHA256SUMS\` | 上面两个文件的校验和 |

包内 \`Architecture: all\`（全是 Lua / shell / JSON / 配置），**一个包适用于所有 CPU 架构**，
不需要按架构编译。

\`\`\`sh
opkg install luci-app-parentcontrol_${VER}-*_all.ipk    # 方式一
sh luci-app-parentcontrol_${VER}-*.run                  # 方式二
sh luci-app-parentcontrol_${VER}-*.run uninstall        # 卸载（配置与用量数据保留）
sha256sum -c SHA256SUMS
\`\`\`

装完进 LuCI：**网络 → 家长控制**。
完整历史见 [CHANGELOG.md](https://github.com/neohob/luci-app-parentcontrol/blob/main/CHANGELOG.md)。
EOF
