# Hướng dẫn sử dụng LiveBench test model Ollama

## 1. Yêu cầu
- Ollama đang chạy: `http://localhost:11434`
- Model đã có trong ollama (xem bằng `ollama list`)
- LiveBench đã cài: `pip install -e .` trong `.venv`

## 2. Cách test nhanh — chỉ cần nhập tên model

```bash
cd /home/caoanhhao/projects/livebench2.0/Livebench2.0
bash test_model.sh <tên-model-trong-ollama>
```

Ví dụ:
```bash
bash test_model.sh saluki100k:latest
bash test_model.sh nemotron-3.5-bolt:e4b
bash test_model.sh Qwen3.5-9B-DeepSeek-V4-Flash-GGUF:latest
```

Script tự động:
- Lấy tên model từ ollama
- Gọi `livebench/run_livebench.py --api-base http://localhost:11434/v1`
- Lưu log vào `results/<model>/run_<ngày>.log`

## 3. Xem kết quả
```bash
ls results/
cat results/saluki100k/run_2026-10-31.log
```

Kết quả điểm số nằm trong `livebench/data/live_bench/.../model_answer/<model>.jsonl` và `model_judgment/ground_truth_judgment.jsonl`.

## 4. Chạy nhiều model cùng lúc
```bash
bash run_all_models.sh   # chạy cả 3 model đã cấu hình
```

## 5. Tuỳ chỉnh
- Đổi benchmark: sửa `--bench-name live_bench` thành `live_bench/coding`, `live_bench/reasoning`, v.v.
- Đổi số request song song: `--parallel-requests 4`
- Đổi số token tối đa: `--max-tokens 8192`
