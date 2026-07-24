#!/bin/bash
# HeyGem 对口型合成封装(EXPERIMENTAL):synthesize.sh <video> <audio> <out.mp4>
# 与 musetalk-synthesize.sh 同接口,供 koubo 后端按 engine=heygem 调用。
set -uo pipefail
V=${1:?video}; A=${2:?audio}; OUT=${3:?out}
WORK=/content/hg
REPO=$WORK/HeyGem-Linux-Python-Hack
PY=$WORK/env/bin/python
export LD_LIBRARY_PATH="/usr/lib64-nvidia:$WORK/env/lib:${LD_LIBRARY_PATH:-}"
export MPLBACKEND=Agg

cd $REPO
mkdir -p example_in
# run.py 只认相对路径
cp -f "$V" example_in/in.mp4
ffmpeg -v error -y -i "$A" -ar 16000 -ac 1 example_in/in.wav

T0=$(date +%s)
$PY run.py --audio_path example_in/in.wav --video_path example_in/in.mp4 || { echo "!!! heygem run.py failed"; exit 1; }

# 输出位置随版本变化:取项目内最近 2 分钟新产出的 mp4(排除输入)
O=$(find . -name "*.mp4" -newermt "-2 minutes" ! -path "./example_in/*" -type f 2>/dev/null | head -1)
[ -n "$O" ] || O=$(ls -t result/*.mp4 outputs/*.mp4 output/*.mp4 2>/dev/null | head -1)
[ -n "$O" ] || { echo "!!! no output mp4 found"; exit 1; }
cp -f "$O" "$OUT"
D=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT" 2>/dev/null || echo 0)
echo "OK out=$OUT audio_dur=${D}s wall=$(( $(date +%s) - T0 ))s engine=heygem"
