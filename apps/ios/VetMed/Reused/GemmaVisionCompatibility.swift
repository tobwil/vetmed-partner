import Foundation
import MLXLMCommon
import MLXVLM
import MLXNN

enum GemmaVisionCompatibility {
    /// mlx-swift-lm 3.31.4 sanitizes away shared-layer K/V weights but still constructs
    /// those unused modules. Remove exactly those optional modules before weight loading.
    /// The forward pass already reads the earlier layer's KV state, not these projections.
    /// No checkpoint edits, replacement weights, or changes to vision/audio parameters.
    static func register() async {
        await VLMTypeRegistry.shared.registerModelType("gemma4") { data in
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var vision = json["vision_config"] as? [String: Any] else { throw AppFailure("Gemma-Bildkonfiguration fehlt.") }
            // Gemma's documented 70-token budget: 630 patches instead of 2520.
            // Keep pooling/weights unchanged; apply the matching processor budget below.
            vision["default_output_length"] = 70; json["vision_config"] = vision
            json["vision_soft_tokens_per_image"] = 70
            let config = try JSONDecoder().decode(MLXVLM.Gemma4Configuration.self, from: JSONSerialization.data(withJSONObject: json))
            let text = config.textConfiguration
            guard text.hiddenLayers == 35, text.numKVSharedLayers == 20, text.hiddenSize == 1536 else {
                throw AppFailure("Diese Gemma-Vision-Konfiguration ist nicht für den lokalen Adapter geprüft.")
            }
            let model = MLXVLM.Gemma4(config)
            let modules = Dictionary(uniqueKeysWithValues: model.namedModules())
            for layer in (text.hiddenLayers - text.numKVSharedLayers)..<text.hiddenLayers {
                guard let attention = modules["language_model.model.layers.\(layer).self_attn"] else {
                    throw AppFailure("Gemma-Vision-Modulstruktur ist nicht kompatibel.")
                }
                for key in ["k_proj", "v_proj", "k_norm", "v_norm"] where attention.children()[key] != nil {
                    try attention.update(modules: ModuleChildren(values: [key: .none]), verify: .none)
                }
            }
            return model
        }
        await VLMProcessorTypeRegistry.shared.registerProcessorType("Gemma4Processor") { data, tokenizer in
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppFailure("Bildprozessor fehlt.") }
            json["size"] = ["width": 400, "height": 400]
            json["image_seq_length"] = 70
            let config = try JSONDecoder().decode(Gemma4ProcessorConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
            return Gemma4Processor(config, tokenizer: tokenizer)
        }
    }
}
