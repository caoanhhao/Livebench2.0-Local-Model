#!/bin/bash
# Script đơn giản: chỉ nhập tên model trong ollama -> chạy LiveBench test
#
# Cách dùng:
#   bash test_model.sh <model_name>
#
# Ví dụ:
#   bash test_model.sh saluki100k:latest
#   bash test_model.sh nemotron-3.5-bolt:e4b
#   bash test_model.sh Qwen3.5-9B-DeepSeek-V4-Flash-GGUF:latest
#
# Kết quả lưu:
#   results/<display_name>/run_<date>.log
#
# Yêu cầu đã cài đặt:
#   pip install -e .
#   source .venv/bin/activate
#   Dữ liệu live_bench (đã tải: livebench/download_questions.py)

MODEL="${1:-}"
if [ -z "$MODEL" ]; then
    echo "==> Sử dụng: bash test_model.sh <model_name>"
    echo "    Ví dụ: bash test_model.sh saluki100k:latest"
    echo "    Endpoint ollama: http://localhost:11434/v1"
    exit 1
fi

# Chuyển đổi model_name -> display_name (cắt :latest / :e4b)
DISPLAY="${MODEL%:latest}"
DISPLAY="${DISPLAY%:e4b}"
DISPLAY="${DISPLAY%:chinchilla}"
if [ -z "$DISPLAY" ]; then DISPLAY="$MODEL"; fi

# Địa điểm làm việc và log
WORKDIR="$(cd "$(dirname "$0")" && pwd)"
VENV="$WORKDIR/.venv"
API_BASE="http://localhost:11434/v1"
OUTDIR="results/$DISPLAY"
DATE="$(date +%Y-%m-%d)"
LOG="$OUTDIR/run_$DATE.log"

mkdir -p "$OUTDIR"

echo "==> Chạy LiveBench model: $MODEL (display: $DISPLAY)"
echo "==> Log: $LOG"

source "$VENV/bin/activate"

python livebench/run_livebench.py \
    --model "$MODEL" \
    --bench-name live_bench \
    --api-base "$API_BASE" \
    --model-display-name "$DISPLAY" \
    --livebench-release-option 2024-11-25 \
    --mode single \
    --parallel-requests 2 \
    --max-tokens 4096 \
    >> "$LOG" 2>&1

echo "==> Hoàn tất kết quả tại: $LOG"
echo "Nếu cần nhiều dataset hơn, thay '--bench-name' bằng full path (ví dụ: live_bench/coding)"
