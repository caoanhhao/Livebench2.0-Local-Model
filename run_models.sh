#!/bin/bash
# Chạy LiveBench cho các model ollama truyền vào dòng lệnh (lần lượt từng model).
# Mỗi model gọi test_model.sh -> max-tokens = num_ctx của ollama, log ở results/<model>/
#
# Cách dùng:
#   BENCH=live_bench/reasoning QUESTION_END=5 bash run_models.sh <model1> [model2 ...]
#   bash run_models.sh saluki100k:latest Nemotron-3.5-Bolt-E4B-4GB:Q4_K_M
set -uo pipefail
WORKDIR="$(cd "$(dirname "$0")" && pwd)"
BENCH="${BENCH:-live_bench}"
QUESTION_END="${QUESTION_END:-}"

if [ $# -eq 0 ]; then
  echo "==> Sử dụng: [BENCH=...] [QUESTION_END=N] bash run_models.sh <model1> [model2 ...]"
  exit 1
fi

failed=0
for model in "$@"; do
  echo "=== Running $model (bench: $BENCH) ==="
  bash "$WORKDIR/test_model.sh" "$model" "$BENCH" $QUESTION_END || failed=$((failed + 1))
  echo "=== $model finished ==="
done

echo "Results saved per model in results/<model_name>/ ($failed model lỗi)"
exit $((failed > 0))
