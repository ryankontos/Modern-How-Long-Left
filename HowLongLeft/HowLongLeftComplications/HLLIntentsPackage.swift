import AppIntents
import HLLKit

struct HowLongLeftComplicationsIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [HLLKitIntentsPackage.self] }
}
