# Ollama context optimize

Proxy OpenAI-compatible đứng trước Ollama. Các bản có hậu tố `NNNk` được gộp thành một họ dưới tên gốc (`saluki100k`, `saluki130k`, … và `saluki` → họ `saluki`). Agent gọi tên gốc, proxy tự chọn bản nhỏ nhất còn đủ ngữ cảnh: bản nhỏ giữ nhiều lớp trên GPU hơn nên nhanh hơn.

- Cỡ ngữ cảnh lấy từ hậu tố tên: `saluki100k` → 100000, `gemma4:26b-256k` → 256000. Bản không hậu tố (`saluki`) đọc `num_ctx` trong Modelfile.
- Thêm/xoá bản trong Ollama là proxy tự thấy (đọc lại danh sách mỗi 60 giây), không cần sửa cấu hình.
- Ước lượng thiếu → Ollama trả 400 kèm số token thật → proxy gửi lại sang bản đủ lớn.
- Ngữ cảnh giảm (agent nén hội thoại) → chỉ hạ cấp khi dưới 60% bản nhỏ hơn, tránh tải lại model liên tục.
- Model không thuộc họ nào, và tên bản cụ thể như `saluki130k`, được chuyển thẳng tới Ollama.
- `GET /v1/models` liệt kê mỗi họ một tên gốc cộng tất cả model khác.

## Dùng

Base URL: `http://127.0.0.1:11435/v1`, model: tên gốc của họ (`saluki`, `Qwen3.5-9B-DeepSeek-V4-Flash-GGUF`) hoặc bất kỳ model Ollama nào.

```bash
systemctl --user enable --now ~/projects/livebench2.0/tools/ollama-context-optimize/ollama-context-optimize.service  # cài + tự chạy cùng máy + start
systemctl --user restart ollama-context-optimize    # sau khi sửa ollama_context_optimize.py
systemctl --user status ollama-context-optimize     # trạng thái
journalctl --user -u ollama-context-optimize -f     # xem proxy chọn bản nào
systemctl --user disable --now ollama-context-optimize  # tắt và bỏ tự chạy
```

Đã cấu hình sẵn:
- **omp** (`~/.omp/agent/models.yml`, provider `ollama-context-optimize`): `discovery: openai-models-list`, tự lấy danh sách model và context từ `/v1/models` của proxy. Thêm/xoá model trong Ollama rồi chạy `omp models refresh`.
- **opencode** (`~/.config/opencode/opencode.jsonc`, provider `ollama-context-optimize`): plugin [opencode-plugin.js](opencode-plugin.js) (cài ở `~/.config/opencode/plugins/ollama-context-optimize-discovery.js`) nạp danh sách model từ `/v1/models`, kiểm tra lại mỗi 60 giây và tự reload provider khi danh sách đổi.

  Cài lại sau khi sửa plugin (chép rồi `mv`, không symlink; server opencode cache module theo đường dẫn nên cần khởi động lại opencode để nhận bản mới):
  ```bash
  cp ~/projects/livebench2.0/tools/ollama-context-optimize/opencode-plugin.js ~/.config/opencode/.oco.tmp && mv ~/.config/opencode/.oco.tmp ~/.config/opencode/plugins/ollama-context-optimize-discovery.js
  ```

`GET /v1/models` trả kèm `context_length` (họ gộp: 90% bản lớn nhất; model khác: hậu tố `NNNk` hoặc `num_ctx`), `input_modalities` và `output_modalities: ["embedding"]` cho model embedding. Model Ollama không đọc được (`/api/show` lỗi) bị bỏ qua.

## Biến môi trường (trong `ollama-context-optimize.service`)

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `SALUKI_AUTO_LISTEN` | `127.0.0.1:11435` | Địa chỉ proxy |
| `SALUKI_AUTO_UPSTREAM` | `http://127.0.0.1:11434` | Ollama |
| `SALUKI_AUTO_FILL_RATIO` | `0.9` | Dùng tối đa 90% ngữ cảnh của một bản (chừa sai số ước lượng) |
| `SALUKI_AUTO_DOWNGRADE_RATIO` | `0.6` | Chỉ hạ cấp khi dưới 60% bản nhỏ hơn |
| `SALUKI_AUTO_IMAGE_TOKENS` | `2048` | Token ước lượng cho mỗi ảnh (base64 của ảnh không đếm như văn bản) |
| `SALUKI_AUTO_OUTPUT_RESERVE` | `16384` | Chừa cho output khi request không gửi `max_tokens` |
| `SALUKI_AUTO_DEBUG` | – | `1` để log các trường của request |

`reasoning_effort` `high`/`xhigh`/`max` bị bỏ đi (template saluki mặc định xhigh và không nhận `high`), `minimal`/`none` → `low`.
