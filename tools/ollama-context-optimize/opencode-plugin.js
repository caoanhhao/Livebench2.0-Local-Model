// Plugin opencode (v2): tự nạp danh sách model của provider `ollama-context-optimize` từ /v1/models của
// proxy, giống `discovery: openai-models-list` của omp. Danh sách được kiểm tra lại mỗi
// REFRESH_SECONDS giây; khi đổi thì plugin gọi provider.reload() nên không cần khởi động lại opencode.
//
// Cài (chép file, không symlink: server opencode cache module theo đường dẫn thật và đọc file
// ngay khi watcher thấy, nên chép ra chỗ khác rồi mv vào cho nguyên vẹn):
//   cp opencode-plugin.js ~/.config/opencode/.oco.tmp && mv ~/.config/opencode/.oco.tmp ~/.config/opencode/plugins/ollama-context-optimize-discovery.js

const PROVIDER_ID = "ollama-context-optimize"
const BASE_URL = process.env.OLLAMA_CONTEXT_OPTIMIZE_URL ?? "http://127.0.0.1:11435/v1"
const MAX_OUTPUT = 32768
const REFRESH_SECONDS = 60
const PROVIDER_PACKAGE = "@opencode/ai/providers/openai-compatible"
const PROVIDER_SETTINGS = { apiKey: "", baseURL: BASE_URL, provider: PROVIDER_ID }

async function discover() {
  const res = await fetch(`${BASE_URL}/models`, { signal: AbortSignal.timeout(3000) })
  return ((await res.json()).data ?? []).filter((m) => m.id && !m.output_modalities?.includes("embedding"))
}

function toModel(entry) {
  const context = entry.context_length ?? 4096
  const input = entry.input_modalities ?? ["text"]
  return {
    id: entry.id,
    modelID: entry.id,
    providerID: PROVIDER_ID,
    type: "chat",
    name: `${entry.id} (${Math.round(context / 1000)}k${input.includes("image") ? ", vision" : ""})`,
    capabilities: { tools: true, input, output: ["text"], temperature: true },
    limit: { context, output: Math.min(MAX_OUTPUT, Math.floor(context / 2)) },
    package: PROVIDER_PACKAGE,
    settings: PROVIDER_SETTINGS,
    headers: {},
    time: { released: 0 },
    cost: [],
    variants: [],
    status: "active",
    enabled: true,
  }
}

export default {
  id: PROVIDER_ID,
  setup: async (ctx) => {
    let models = null // null: proxy chưa trả lời, giữ nguyên cấu hình
    let signature = ""

    const refresh = async () => {
      try {
        const entries = await discover()
        const next = JSON.stringify(entries)
        if (next === signature) return false
        signature = next
        models = entries.map(toModel)
        return true
      } catch {
        return false
      }
    }

    await refresh()
    // Bản nháp (Immer) chỉ sửa được trong phần đồng bộ của transform: không await ở đây
    await ctx.provider.transform((draft) => {
      if (!models) return
      if (draft.get(PROVIDER_ID)) {
        draft.models.set(PROVIDER_ID, models)
      } else {
        draft.add({
          info: {
            id: PROVIDER_ID,
            name: "Ollama context optimize",
            activation: "enabled",
            package: PROVIDER_PACKAGE,
            settings: PROVIDER_SETTINGS,
          },
          models,
        })
      }
    })

    const timer = setInterval(async () => {
      if (await refresh()) await ctx.provider.reload()
    }, REFRESH_SECONDS * 1000)
    timer.unref?.()
    return async () => clearInterval(timer)
  },
}
