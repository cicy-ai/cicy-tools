#!/bin/bash
# MuseTalk 1.5 synthesis wrapper (lives on the Colab runtime at /content/mt/synthesize.sh).
#   bash synthesize.sh <base_video> <audio> <out.mp4> [bbox_shift]
#   bash synthesize.sh            # 无参数 = 官方样例冒烟测试
# 输出: 对完口型的 mp4(带音轨)拷贝到 <out.mp4>,stdout 最后一行 "OK out=... wall=...s"
set -euo pipefail

# Colab 容器的 NVIDIA 驱动库不在默认搜索路径;SSH 会话没有 notebook 的 env,必须显式补上
export LD_LIBRARY_PATH="/usr/lib64-nvidia:${LD_LIBRARY_PATH:-}"
# 强制无头 matplotlib 后端,避免继承 Jupyter 的 inline 后端导致 mmpose 崩
export MPLBACKEND=Agg

WORK=/content/mt
ENV=$WORK/env
REPO=$WORK/MuseTalk
PY=$ENV/bin/python

VIDEO=${1:-$REPO/data/video/yongen.mp4}
AUDIO=${2:-$REPO/data/audio/yongen.wav}
OUT=${3:-$WORK/smoke_test_out.mp4}
BBOX=${4:-0}

[ -f "$VIDEO" ] || { echo "video not found: $VIDEO"; exit 1; }
[ -f "$AUDIO" ] || { echo "audio not found: $AUDIO"; exit 1; }

JOB=$REPO/configs/inference/job.yaml
cat > $JOB <<EOF
task_0:
 video_path: "$VIDEO"
 audio_path: "$AUDIO"
 bbox_shift: $BBOX
EOF

RESULT_DIR=$REPO/results/job
rm -rf $RESULT_DIR
cd $REPO
START=$(date +%s)
$PY -m scripts.inference \
  --inference_config $JOB \
  --result_dir $RESULT_DIR \
  --unet_model_path $REPO/models/musetalkV15/unet.pth \
  --unet_config $REPO/models/musetalkV15/musetalk.json \
  --version v15
ELAPSED=$(( $(date +%s) - START ))

RESULT=$(find $RESULT_DIR -name '*.mp4' | head -1)
[ -n "$RESULT" ] || { echo "no output mp4 produced"; exit 1; }
cp "$RESULT" "$OUT"
DUR=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$OUT" 2>/dev/null || echo "?")
echo "OK out=$OUT audio_dur=${DUR}s wall=${ELAPSED}s"
