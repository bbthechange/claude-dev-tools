import Foundation

/// Routes supported by the deep link system.
/// Usage: `xcrun simctl openurl booted "{{PROJECT_NAME_LOWERCASE}}://home"`
///
/// Add new routes as screens are built. Update:
/// 1. Add case to this enum
/// 2. Add switch case in init?(url:)
/// 3. Handle in MainTabView.handleDeepLink()
/// 4. Update scripts/sim.sh header comment
enum DeepLinkRoute: Equatable, Sendable {
    case home
    // Add routes as screens are built:
    // case settings
    // case detail(id: String)

    init?(url: URL) {
        guard url.scheme == "{{PROJECT_NAME_LOWERCASE}}" else { return nil }
        switch url.host {
        case "home": self = .home
        // case "settings": self = .settings
        default: return nil
        }
    }
}
