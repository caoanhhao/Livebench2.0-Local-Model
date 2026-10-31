#!/bin/bash
# Script đơn giản: chỉ nhập tên model trong ollama -> chạy LiveBench test
#
# Cách dùng:
#   bash test_model.sh <model_name> [bench_name] [question_end]
#
# Ví dụ:
#   bash test_model.sh saluki100k:latest
#   bash test_model.sh Nemotron-3.5-Bolt-E4B-4GB:Q4_K_M live_bench/reasoning 5
#   bash test_model.sh Qwen3.5-9B-DeepSeek-V4-Flash-GGUF:latest live_bench/math
#
#   bench_name    mặc định: live_bench (toàn bộ). Có thể là live_bench/coding, live_bench/reasoning, ...
#   question_end  tuỳ chọn: chỉ chạy N câu đầu mỗi task (để test nhanh)
#
# Kết quả lưu:
#   results/<display_name>/run_<date>_<time>.log
#
# Yêu cầu đã cài đặt:
#   pip install -e .
#   source .venv/bin/activate
#   Dữ liệu live_bench (đã tải: livebench/download_questions.py)

MODEL="${1:-}"
BENCH="${2:-live_bench}"
QUESTION_END="${3:-}"
if [ -z "$MODEL" ]; then
    echo "==> Sử dụng: bash test_model.sh <model_name> [bench_name] [question_end]"
    echo "    Ví dụ: bash test_model.sh saluki100k:latest live_bench/reasoning 5"
    echo "    Endpoint ollama: http://localhost:11434/v1"
    exit 1
fi

# Chuyển đổi model_name -> display_name (cắt :latest / :e4b)
DISPLAY="${MODEL%:latest}"
DISPLAY="${DISPLAY%:e4b}"
DISPLAY="${DISPLAY%:chinchilla}"
if [ -z "$DISPLAY" ]; then DISPLAY="$MODEL"; fi

# Địa điểm làm việc và log (đường dẫn tuyệt đối vì sẽ cd vào livebench/)
WORKDIR="$(cd "$(dirname "$0")" && pwd)"
VENV="$WORKDIR/.venv"
API_BASE="http://localhost:11434/v1"
OUTDIR="$WORKDIR/results/$DISPLAY"
LOG="$OUTDIR/run_$(date +%Y-%m-%d_%H%M%S).log"

mkdir -p "$OUTDIR"

# max-tokens = num_ctx khai báo trong Modelfile của ollama (mặc định 4096 nếu không có)
MAX_TOKENS="$(ollama show "$MODEL" --modelfile 2>/dev/null | awk '$1=="PARAMETER" && $2=="num_ctx"{print $3; exit}')"
MAX_TOKENS="${MAX_TOKENS:-4096}"

echo "==> Chạy LiveBench model: $MODEL (display: $DISPLAY, bench: $BENCH, max-tokens: $MAX_TOKENS)"
echo "==> Log: $LOG"

source "$VENV/bin/activate"

EXTRA_ARGS=()
if [ -n "$QUESTION_END" ]; then EXTRA_ARGS+=(--question-end "$QUESTION_END"); fi

# run_livebench.py gọi gen_api_answer.py / gen_ground_truth_judgment.py theo đường dẫn
# tương đối, nên phải chạy từ trong thư mục livebench/
cd "$WORKDIR/livebench" || exit 1
python run_livebench.py \
    --model "$MODEL" \
    --bench-name "$BENCH" \
    --api-base "$API_BASE" \
    --model-display-name "$DISPLAY" \
    --livebench-release-option 2024-11-25 \
    --mode single \
    --parallel-requests 2 \
    --max-tokens "$MAX_TOKENS" \
    "${EXTRA_ARGS[@]}" \
    >> "$LOG" 2>&1
STATUS=$?

if [ $STATUS -eq 0 ]; then
    echo "==> Hoàn tất. Log: $LOG"
else
    echo "==> LỖI (exit $STATUS). Xem log: $LOG"
fi
echo "Kết quả: livebench/data/$BENCH/.../model_judgment/ground_truth_judgment.jsonl"
exit $STATUS
