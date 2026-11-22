import Foundation

/// Curated catalog of open-weight GGUF models suitable for Apple Silicon iPads (8 GB RAM target)
/// alongside high-capacity options clearly labeled with their memory demands.
public enum ModelCatalog {
    public static let curatedModels: [CatalogModelEntry] = [
        CatalogModelEntry(
            id: "qwen2.5-3b-instruct-q4km",
            name: "Qwen 2.5 3B Instruct",
            family: "Qwen2",
            quantization: "Q4_K_M",
            parameterCountLabel: "3B",
            approximateSizeBytes: 2_070_000_000,
            estimatedRAMBytes: 2_950_000_000,
            contextWindow: 32_768,
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf")!,
            filename: "qwen2.5-3b-instruct-q4_k_m.gguf",
            summary: "Fast, well-balanced local assistant with strong coding, file reasoning, and multilingual quality on 8 GB iPad Pro M2.",
            recommendedFor8GBiPad: true,
            speedRating: "Very Fast",
            intelligenceRating: "High (3B)"
        ),
        CatalogModelEntry(
            id: "llama-3.2-3b-instruct-q4km",
            name: "Llama 3.2 3B Instruct",
            family: "Llama",
            quantization: "Q4_K_M",
            parameterCountLabel: "3B",
            approximateSizeBytes: 2_020_000_000,
            estimatedRAMBytes: 2_850_000_000,
            contextWindow: 131_072,
            downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
            filename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            summary: "Meta's compact instruction-tuned model optimized for on-device summarization and everyday assistant tasks.",
            recommendedFor8GBiPad: true,
            speedRating: "Very Fast",
            intelligenceRating: "High (3B)"
        ),
        CatalogModelEntry(
            id: "phi-3.5-mini-instruct-q4km",
            name: "Phi-3.5 Mini Instruct",
            family: "Phi3",
            quantization: "Q4_K_M",
            parameterCountLabel: "3.8B",
            approximateSizeBytes: 2_390_000_000,
            estimatedRAMBytes: 3_350_000_000,
            contextWindow: 131_072,
            downloadURL: URL(string: "https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf")!,
            filename: "Phi-3.5-mini-instruct-Q4_K_M.gguf",
            summary: "Strong logical reasoning, structured analysis, and code generation in a compact 3.8B footprint.",
            recommendedFor8GBiPad: true,
            speedRating: "Fast",
            intelligenceRating: "Very High (3.8B)"
        ),
        CatalogModelEntry(
            id: "gemma-2-2b-it-q4km",
            name: "Gemma 2 2B Instruct",
            family: "Gemma2",
            quantization: "Q4_K_M",
            parameterCountLabel: "2B",
            approximateSizeBytes: 1_710_000_000,
            estimatedRAMBytes: 2_450_000_000,
            contextWindow: 8_192,
            downloadURL: URL(string: "https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf")!,
            filename: "gemma-2-2b-it-Q4_K_M.gguf",
            summary: "Lightweight Google Gemma 2 model leaving ample RAM headroom for multitasking and 3D Studio.",
            recommendedFor8GBiPad: true,
            speedRating: "Ultra Fast",
            intelligenceRating: "Good (2B)"
        ),
        CatalogModelEntry(
            id: "qwen2.5-7b-instruct-q4km",
            name: "Qwen 2.5 7B Instruct",
            family: "Qwen2",
            quantization: "Q4_K_M",
            parameterCountLabel: "7B",
            approximateSizeBytes: 4_680_000_000,
            estimatedRAMBytes: 5_850_000_000,
            contextWindow: 32_768,
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m.gguf")!,
            filename: "qwen2.5-7b-instruct-q4_k_m.gguf",
            summary: "High-capability 7B model. Tight on 8 GB iPadOS (recommended with 4K context and Increased Memory Limit entitlement).",
            recommendedFor8GBiPad: false,
            speedRating: "Moderate",
            intelligenceRating: "Flagship Local (7B)"
        ),
        CatalogModelEntry(
            id: "mistral-7b-instruct-v0.3-q4km",
            name: "Mistral 7B Instruct v0.3",
            family: "Llama",
            quantization: "Q4_K_M",
            parameterCountLabel: "7B",
            approximateSizeBytes: 4_370_000_000,
            estimatedRAMBytes: 5_450_000_000,
            contextWindow: 32_768,
            downloadURL: URL(string: "https://huggingface.co/bartowski/Mistral-7B-Instruct-v0.3-GGUF/resolve/main/Mistral-7B-Instruct-v0.3-Q4_K_M.gguf")!,
            filename: "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf",
            summary: "Proven 7B instruction model. Requires careful context sizing on 8 GB devices.",
            recommendedFor8GBiPad: false,
            speedRating: "Moderate",
            intelligenceRating: "High (7B)"
        )
    ]
}
