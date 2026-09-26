import AppIntents
import HLLKit

struct HowLongLeftWatchIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [HLLKitIntentsPackage.self] }
}
