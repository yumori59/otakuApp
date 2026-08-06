import Foundation
import Domain

enum PurchasesServiceFactory {
    static func make() -> any PurchasesProviding {
        #if canImport(RevenueCat)
        let key = (Bundle.main.object(forInfoDictionaryKey: "REVENUECAT_API_KEY") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !key.isEmpty {
            return RevenueCatPurchasesService(apiKey: key)
        }
        #endif
        return DisabledPurchasesService()
    }
}
