import Foundation

public enum FanServiceIdentity {
    public static let machService = "app.ember.heatmonitor.fans"
    public static let plist = "app.ember.heatmonitor.fans.plist"
}
@objc(EmberFanService) public protocol FanService {
    // Only two operations cross the privilege boundary. No paths, commands, keys or RPMs.
    func setMaximum(_ enabled: Bool, reply: @escaping @Sendable (Int32, Bool) -> Void)
}
