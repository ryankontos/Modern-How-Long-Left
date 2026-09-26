import Foundation

/// Identifiers shared by the app, watch app, widgets, and complications.
///
/// These values are sourced from the original How Long Left project and are
/// kept in one place so every target uses the same containers.
public enum HLLConfiguration {
    public static let appGroupIdentifier = "group.com.ryankontos.How-Long-Left"
    public static let cloudContainerIdentifier = "iCloud.ryankontos.howlongleft"
    public static let iOSBundleIdentifier = "com.ryankontos.How-Long-Left"
    public static let watchBundleIdentifier = "com.ryankontos.How-Long-Left.watchkit"
    public static let widgetBundleIdentifier = "com.ryankontos.How-Long-Left.iOSWidget"
    public static let complicationBundleIdentifier = "com.ryankontos.How-Long-Left.watchkit.Complications"
}
