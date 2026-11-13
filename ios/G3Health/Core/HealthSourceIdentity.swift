import Foundation

/// Classify device metadata conservatively; an arbitrary watch is not an Apple Watch.
enum HealthSourceIdentity {
    static func isAppleWatch(productType: String?, model: String?, manufacturer: String?) -> Bool {
        let product = normalized(productType)
        let model = normalized(model)
        let maker = normalized(manufacturer)
        if product.range(of: #"^watch[0-9]+,[0-9]+$"#, options: .regularExpression) != nil { return true }
        if model == "apple watch" || model.hasPrefix("apple watch ") { return true }
        let appleManufacturer = maker == "apple" || maker == "apple inc." || maker == "apple inc"
        return appleManufacturer && (model == "watch" || model.hasPrefix("watch "))
    }

    private static func normalized(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
