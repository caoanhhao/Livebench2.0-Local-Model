#!/bin/bash
# Chạy LiveBench cho các model ollama đã cấu hình bên dưới (lần lượt từng model).
# Mỗi model gọi test_model.sh -> max-tokens = num_ctx của ollama, log ở results/<model>/
#
# Cách dùng:
#   bash run_all_models.sh [bench_name] [question_end]
#   bash run_all_models.sh live_bench/reasoning 5
set -uo pipefail
WORKDIR="$(cd "$(dirname "$0")" && pwd)"
BENCH="${1:-live_bench}"
QUESTION_END="${2:-}"

MODELS=(
  "Qwen3.5-9B-DeepSeek-V4-Flash-GGUF:latest"
  "saluki100k:latest"
  "Nemotron-3.5-Bolt-E4B-4GB:Q4_K_M"
)

SUMMARY="$WORKDIR/results/summary.md"
mkdir -p "$WORKDIR/results"
echo "=== $(date -Iseconds) Chạy ${#MODELS[@]} model, bench: $BENCH ===" >> "$SUMMARY"

for model in "${MODELS[@]}"; do
  echo "=== Bắt đầu $model lúc $(date -Iseconds) ==="
  bash "$WORKDIR/test_model.sh" "$model" "$BENCH" $QUESTION_END
  status=$?
  echo "- $model: exit $status ($(date -Iseconds))" >> "$SUMMARY"
done

echo "==> Xong. Tóm tắt: $SUMMARY"
