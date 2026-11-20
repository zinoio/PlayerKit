#!/bin/bash
# p7_rpu_diff.sh — Task 2b 第一步:真实 P7 RPU vs dovi_tool 转换态 的逐字节分析
#
# 用法: ./Scripts/p7_rpu_diff.sh /path/to/full-sample.mkv [outdir=./p7-rpu-out]
#
# 产出(本地,不入仓):
#   p7.bin      原始 P7 RPU(dovi_tool extract-rpu)
#   p81.bin     dovi_tool convert --profile 8.1 输出
#   report.txt  长度/头部字节/差异统计
#
# 依赖:dovi_tool(仅本地)。
set -euo pipefail
SRC="${1:-}"; OUT="${2:-./p7-rpu-out}"
[ -n "$SRC" ] || { echo "用法: $0 <full-sample.mkv> [outdir]" >&2; exit 2; }
command -v dovi_tool >/dev/null || { echo "缺少 dovi_tool" >&2; exit 2; }
mkdir -p "$OUT"

echo "== extract-rpu"
dovi_tool extract-rpu -i "$SRC" -o "$OUT/p7.bin"

echo "== convert --profile 8.1"
dovi_tool -m 2 convert --profile 8.1 -i "$OUT/p7.bin" -o "$OUT/p81.bin" || \
  dovi_tool convert --profile 8.1 -i "$OUT/p7.bin" -o "$OUT/p81.bin"

{
  echo "# P7 RPU vs P8.1 RPU"
  echo "sample: $SRC"
  ls -l "$OUT/p7.bin" "$OUT/p81.bin"
  echo
  echo "## P7 head (64B)"
  xxd -l 64 "$OUT/p7.bin"
  echo
  echo "## P8.1 head (64B)"
  xxd -l 64 "$OUT/p81.bin"
  echo
  echo "## P7 tail (32B)"
  tail -c 32 "$OUT/p7.bin" | xxd
  echo
  echo "## P8.1 tail (32B)"
  tail -c 32 "$OUT/p81.bin" | xxd
  echo
  echo "## byte diff summary"
  cmp -l "$OUT/p7.bin" "$OUT/p81.bin" 2>/dev/null | wc -l | awk '{print "differing bytes:",$1}'
  cmp -l "$OUT/p7.bin" "$OUT/p81.bin" 2>/dev/null | head -40 || true
} > "$OUT/report.txt"

echo "结果: $OUT/report.txt"
