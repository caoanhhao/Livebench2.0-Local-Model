# Hướng dẫn sử dụng LiveBench test model Ollama

## 1. Yêu cầu
- Ollama đang chạy: `http://localhost:11434`
- Model đã có trong ollama (xem bằng `ollama list`)
- LiveBench đã cài: `pip install -e .` trong `.venv`

## 2. Cách test nhanh — chỉ cần nhập tên model

```bash
cd /home/caoanhhao/projects/livebench2.0
bash test_model.sh <tên-model-trong-ollama> [bench_name] [question_end]
```

Ví dụ:
```bash
bash test_model.sh saluki100k:latest                                    # toàn bộ live_bench
bash test_model.sh Nemotron-3.5-Bolt-E4B-4GB:Q4_K_M live_bench/reasoning 5   # 5 câu đầu mỗi task reasoning
bash test_model.sh Qwen3.5-9B-DeepSeek-V4-Flash-GGUF:latest live_bench/math
```

Script tự động:
- Lấy `num_ctx` trong Modelfile của ollama làm `--max-tokens` (mặc định 4096 nếu không khai báo)
- `cd livebench/` rồi gọi `run_livebench.py --api-base http://localhost:11434/v1`
  (bắt buộc chạy từ `livebench/`, nếu không sẽ lỗi `can't open file gen_api_answer.py`)
- Lưu log vào `results/<model>/run_<ngày>_<giờ>.log`

## 3. Xem kết quả
```bash
ls results/
ls results/Nemotron-3.5-Bolt-E4B-4GB:Q4_K_M/
```

Kết quả điểm số nằm trong `livebench/data/live_bench/<category>/<task>/model_answer/<model>.jsonl` và `model_judgment/ground_truth_judgment.jsonl`.
Lưu ý: tên file answer là tên model viết thường (vd. `nemotron-3.5-bolt-e4b-4gb:q4_k_m.jsonl`).

## 4. Chạy nhiều model
```bash
bash run_all_models.sh                          # chạy các model khai báo trong MODELS=(...) của script
bash run_all_models.sh live_bench/reasoning 5   # tập con để test nhanh

BENCH=live_bench/reasoning QUESTION_END=5 bash run_models.sh saluki100k:latest Nemotron-3.5-Bolt-E4B-4GB:Q4_K_M
```

Cả hai script đều gọi `test_model.sh` cho từng model. `run_all_models.sh` ghi exit code từng model vào `results/summary.md`.

## 5. Tuỳ chỉnh
- Đổi benchmark: tham số thứ 2 của `test_model.sh` (`live_bench/coding`, `live_bench/reasoning`, ...)
- Số câu gửi song song: `PARALLEL=2 bash test_model.sh ...` (mặc định 1)
- Timeout mỗi request: tự tính = max-tokens/30 + 600 giây; đổi bằng `LIVEBENCH_TIMEOUT=7200 bash test_model.sh ...`
- Số token tối đa: lấy theo `PARAMETER num_ctx` trong Modelfile của ollama. Muốn giới hạn tạm thời: `MAX_TOKENS_CAP=8192 bash test_model.sh ...`
- Phát hiện lặp: mặc định bật (`LIVEBENCH_LOOP_DETECT=1`). Câu trả lời bị lặp lại liên tục (32k ký tự cuối nén còn < 8%) sẽ bị dừng sớm và tính 0 điểm, thay vì chạy hết max-tokens/timeout. Tắt bằng `LIVEBENCH_LOOP_DETECT=0`.
