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
#   max-tokens    = num_ctx trong Modelfile ollama; MAX_TOKENS_CAP=N (env) để giới hạn thêm
#   env tuỳ chọn: PARALLEL (mặc định 1), LIVEBENCH_TIMEOUT (giây, mặc định max_tokens/30 + 600),
#                 TIME_LIMIT (giây, giới hạn tổng thời gian cho model này)
#                 LIVEBENCH_LOOP_DETECT (mặc định 1: dừng câu trả lời lặp vô hạn, tính 0 điểm)
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

# max-tokens = num_ctx khai báo trong Modelfile của ollama (mặc định 4096 nếu không có).
# Đặt MAX_TOKENS_CAP=N để giới hạn thêm (vd. test nhanh); mặc định không giới hạn.
NUM_CTX="$(ollama show "$MODEL" --modelfile 2>/dev/null | awk '$1=="PARAMETER" && $2=="num_ctx"{print $3; exit}')"
MAX_TOKENS="${NUM_CTX:-4096}"
if [ -n "${MAX_TOKENS_CAP:-}" ] && [ "$MAX_TOKENS_CAP" -lt "$MAX_TOKENS" ]; then MAX_TOKENS="$MAX_TOKENS_CAP"; fi

# Timeout mỗi request (giây): đủ để sinh hết MAX_TOKENS ở tốc độ thấp ~30 token/s, cộng 10 phút dư.
# Mặc định của LiveBench là 1800s -> câu suy luận dài bị cắt và tính 0 điểm.
export LIVEBENCH_TIMEOUT="${LIVEBENCH_TIMEOUT:-$(( MAX_TOKENS / 30 + 600 ))}"
# Dừng sớm câu trả lời bị lặp vô hạn (vẫn tính 0 điểm như khi hết token/timeout); LIVEBENCH_LOOP_DETECT=0 để tắt
export LIVEBENCH_LOOP_DETECT="${LIVEBENCH_LOOP_DETECT:-1}"
# Số câu gửi song song tới ollama; 1 = mỗi câu dùng trọn tốc độ GPU
PARALLEL="${PARALLEL:-1}"

echo "==> Chạy LiveBench model: $MODEL (display: $DISPLAY, bench: $BENCH, max-tokens: $MAX_TOKENS, timeout: ${LIVEBENCH_TIMEOUT}s, parallel: $PARALLEL, loop-detect: $LIVEBENCH_LOOP_DETECT)"
echo "==> Log: $LOG"

source "$VENV/bin/activate"

EXTRA_ARGS=()
if [ -n "$QUESTION_END" ]; then EXTRA_ARGS+=(--question-end "$QUESTION_END"); fi
# RESUME=1: bỏ qua các câu đã có câu trả lời (chạy tiếp lần trước bị dừng)
if [ "${RESUME:-}" = "1" ]; then EXTRA_ARGS+=(--resume); fi

# run_livebench.py gọi gen_api_answer.py / gen_ground_truth_judgment.py theo đường dẫn
# tương đối, nên phải chạy từ trong thư mục livebench/
cd "$WORKDIR/livebench" || exit 1
# Chạy trong process group riêng để khi hết TIME_LIMIT (hoặc script bị kill) thì dừng được
# cả gen_api_answer / tiến trình chấm điểm con, không để lại tiến trình mồ côi giữ GPU.
setsid python run_livebench.py \
    --model "$MODEL" \
    --bench-name "$BENCH" \
    --api-base "$API_BASE" \
    --model-display-name "$DISPLAY" \
    --livebench-release-option 2024-11-25 \
    --mode single \
    --parallel-requests "$PARALLEL" \
    --max-tokens "$MAX_TOKENS" \
    "${EXTRA_ARGS[@]}" \
    >> "$LOG" 2>&1 &
RUN_PID=$!
trap 'kill -- -"$RUN_PID" 2>/dev/null; exit 143' TERM INT

# TIME_LIMIT (giây, env tuỳ chọn): hết giờ thì dừng model này; các câu đã chấm vẫn được giữ
TIMED_OUT_FLAG="$OUTDIR/.timed_out_$$"
if [ -n "${TIME_LIMIT:-}" ]; then
    echo "==> Giới hạn thời gian: ${TIME_LIMIT}s"
    ( sleep "$TIME_LIMIT"
      touch "$TIMED_OUT_FLAG"
      kill -- -"$RUN_PID" 2>/dev/null; sleep 30; kill -9 -- -"$RUN_PID" 2>/dev/null ) &
    WATCHDOG_PID=$!
fi
wait "$RUN_PID"
STATUS=$?
if [ -n "${WATCHDOG_PID:-}" ]; then pkill -P "$WATCHDOG_PID" 2>/dev/null; kill "$WATCHDOG_PID" 2>/dev/null; fi
# Đợi các tiến trình con (gen_api_answer, worker chấm điểm) thoát hẳn trước khi sang model khác
for _ in $(seq 30); do pgrep -g "$RUN_PID" >/dev/null || break; sleep 1; done
kill -9 -- -"$RUN_PID" 2>/dev/null
# run_livebench.py vẫn exit 0 khi benchmark lỗi, nên kiểm tra thêm trong log
if [ $STATUS -eq 0 ] && grep -q "Benchmark failed!" "$LOG"; then STATUS=1; fi

if [ -f "$TIMED_OUT_FLAG" ]; then
    rm -f "$TIMED_OUT_FLAG"
    echo "==> HẾT GIỜ (${TIME_LIMIT}s): đã dừng model, giữ các câu đã chấm. Log: $LOG"
    echo "==> HẾT GIỜ sau ${TIME_LIMIT}s" >> "$LOG"
    STATUS=124
elif [ $STATUS -eq 0 ]; then
    echo "==> Hoàn tất. Log: $LOG"
else
    echo "==> LỖI (exit $STATUS). Xem log: $LOG"
fi
echo "Kết quả: livebench/data/$BENCH/.../model_judgment/ground_truth_judgment.jsonl"
exit $STATUS
