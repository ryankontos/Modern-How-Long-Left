import AppIntents
import HLLKit

struct HowLongLeftAppIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [HLLKitIntentsPackage.self] }
}
