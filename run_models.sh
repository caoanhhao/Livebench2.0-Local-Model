#!/bin/bash
# Run LiveBench for 3 ollama local models, save per-model results
set -euo pipefail
VENV=".venv"
API_BASE="http://localhost:11434/v1"
BENCH="live_bench"
RELEASE="2024-11-25"

activate() { source "$VENV/bin/activate"; }

run_model() {
  local model_name="$1"
  local display_name="$2"
  local out_dir="results/${display_name}"
  echo "=== Running $display_name (model: $model_name) ==="
  mkdir -p "$out_dir"
  python livebench/run_livebench.py \
    --model "$model_name" \
    --bench-name "$BENCH" \
    --api-base "$API_BASE" \
    --model-display-name "$display_name" \
    --livebench-release-option "$RELEASE" \
    --mode single \
    --parallel-requests 2 \
    --max-tokens 4096 \
    2>&1 | tee "$out_dir/full_run_$(date +%Y%m%d_%H%M%S).txt"
  echo "=== $display_name finished ==="
}

# Configure per-model file outputs (markdown summaries from answers)
echo "Results saved per model in results/<model_name>/"
