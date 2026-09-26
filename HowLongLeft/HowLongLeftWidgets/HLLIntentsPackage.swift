import AppIntents
import HLLKit

struct HowLongLeftWidgetsIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [HLLKitIntentsPackage.self] }
}
