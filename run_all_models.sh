#!/bin/bash
set -uo pipefail
source /home/caoanhhao/projects/livebench2.0/Livebench2.0/.venv/bin/activate
WORKDIR=/home/caoanhhao/projects/livebench2.0/Livebench2.0/livebench
cd $WORKDIR

run_model() {
  local model_name="$1"
  local display_name="$2"
  local out_file="$3"
  echo "=== Starting $display_name at $(date -Iseconds) ===" >> "$out_file"
  python run_livebench.py \
    --model "$model_name" \
    --bench-name live_bench \
    --api-base http://localhost:11434/v1 \
    --model-display-name "$display_name" \
    --livebench-release-option 2024-11-25 \
    --mode single --parallel-requests 2 --max-tokens 4096 \
    >> "$out_file" 2>&1
  echo "=== Finished $display_name at $(date -Iseconds) ===" >> "$out_file"
  echo "Exit code: $?" >> "$out_file"
}

echo "=== Running 3 local ollama models ===" >> /home/caoanhhao/projects/livebench2.0/Livebench2.0/results/summary.md

run_model "Qwen3.5-9B-DeepSeek-V4-Flash-GGUF:latest" "Qwen3.5-9B-DeepSeek-V4-Flash" "/home/caoanhhao/projects/livebench2.0/Livebench2.0/results/Qwen3.5-9B-DeepSeek-V4-Flash/run_2026-10-31.log"
run_model "saluki100k:latest" "saluki100k" "/home/caoanhhao/projects/livebench2.0/Livebench2.0/results/saluki100k/run_2026-10-31.log"
run_model "nemotron-3.5-bolt:e4b" "nemotron-3.5-bolt" "/home/caoanhhao/projects/livebench2.0/Livebench2.0/results/nemotron-3.5-bolt/run_2026-10-31.log"
