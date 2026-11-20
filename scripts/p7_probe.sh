#!/bin/bash
# p7_probe.sh — 原盘 P7 Task 0 实测脚本(V1/V1b/V3)
#
# 用途:对本地 P7 样本(ISO / M2TS / REMUX MKV)统计:
#   - 流级 DOVI 身份(profile / compat / 是否存在 EL)
#   - 前 N 帧中 ffmpeg 实际产出的每帧 DOVI side data(含 NLQ)覆盖率
#   - dovi_tool 能否抽出 RPU(金标准对拍用)
#
# 样本不入仓。用法:
#   ./Scripts/p7_probe.sh /path/to/sample.iso [frames=300] [outdir=./p7-probe-out]
#
# 依赖:ffprobe、dovi_tool(仅本地;不进运行时/CI)。
set -euo pipefail

SRC="${1:-}"
FRAMES="${2:-300}"
OUT="${3:-./p7-probe-out}"

[ -n "$SRC" ] || { echo "用法: $0 <file-or-dir> [frames] [outdir]" >&2; exit 2; }
command -v ffprobe >/dev/null || { echo "缺少 ffprobe" >&2; exit 2; }

mkdir -p "$OUT"

probe_one() {
  local f="$1"
  local base
  base="$(basename "$f")"
  local dir="$OUT/${base%.*}"
  mkdir -p "$dir"
  echo "== $base"

  # 1) 流级身份
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,profile,width,height,color_transfer,color_primaries,side_data_list \
    -of json "$f" > "$dir/stream.json" 2>/dev/null || true

  # 2) 每帧 DOVI side data 覆盖率(前 FRAMES 帧)
  ffprobe -v error -select_streams v:0 -read_intervals "%+#${FRAMES}" \
    -show_frames -show_entries frame=side_data_list -of json "$f" > "$dir/frames.json" 2>/dev/null || true

  python3 - "$dir" <<'PY'
import json, sys, os
d = sys.argv[1]
def load(name):
    try:
        with open(os.path.join(d, name)) as f: return json.load(f)
    except Exception: return {}
st = load("stream.json")
sd = (st.get("streams") or [{}])[0].get("side_data_list") or []
kinds = sorted({x.get("side_data_type","?") for x in sd})
fr = load("frames.json")
frames = fr.get("frames") or []
with_dovi = sum(1 for f in frames
                for x in (f.get("side_data_list") or [])
                if "DOVI" in (x.get("side_data_type","") or "").upper()
                or "Dolby Vision" in (x.get("side_data_type","") or ""))
print(f"  stream side_data: {kinds}")
print(f"  frames probed: {len(frames)}, with DOVI: {with_dovi}")
if frames:
    sample = next((f for f in frames if f.get("side_data_list")), None)
    if sample:
        for x in sample["side_data_list"]:
            t = x.get("side_data_type","")
            if "DOVI" in t.upper() or "Dolby" in t:
                print(f"  first DOVI keys: {sorted(x.keys())}")
                for k in ("dv_profile","dv_bl_signal_compatibility_id","dv_level","rpu_present","el_present","bl_present"):
                    if k in x: print(f"    {k}={x[k]}")
PY

  # 3) dovi_tool 金标准(V1 只记录成功/失败)
  if command -v dovi_tool >/dev/null; then
    if dovi_tool extract-rpu -i "$f" -o "$dir/rpu.bin" >"$dir/dovi_tool.log" 2>&1; then
      echo "  dovi_tool extract-rpu: OK ($(wc -c < "$dir/rpu.bin") bytes)"
    else
      echo "  dovi_tool extract-rpu: FAIL(见 $dir/dovi_tool.log;ISO 可能需要先取 m2ts)"
    fi
  fi
}

if [ -d "$SRC" ]; then
  find "$SRC" -maxdepth 2 -type f \( -iname '*.iso' -o -iname '*.m2ts' -o -iname '*.mkv' -o -iname '*.ts' \) -print0 |
    while IFS= read -r -d '' f; do probe_one "$f"; done
else
  probe_one "$SRC"
fi

echo
echo "结果目录: $OUT"
