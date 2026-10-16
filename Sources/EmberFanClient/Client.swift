import Foundation
import FanIPC
import Security

// A tiny unprivileged, independently signed bridge keeps the root helper's
// client hash stable while the enclosing app's resource seal is finalized.
@main enum FanClientMain {
    static func main() {
        guard let executable = Bundle.main.executableURL else { exit(77) }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = app.appendingPathComponent("Contents/MacOS/EmberFanHelper")
        guard let requirement = validatedRequirement(app: app, helper: helper) else { exit(77) }
        let owned = XPCOwner(NSXPCConnection(machServiceName: FanServiceIdentity.machService, options: .privileged))
        let connection = owned.connection
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: FanService.self)
        connection.resume()
        // Read stdin off the main queue; XPC and its replies remain live.
        DispatchQueue.global(qos: .utility).async {
            let connection = owned.connection
            while let line = readLine() {
                guard line == "max" || line == "auto" else { break }
                let result = ReplyBox()
                let semaphore = DispatchSemaphore(value: 0)
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                    result.set(ENOTCONN, false); semaphore.signal()
                } as? FanService
                proxy?.setMaximum(line == "max") { code, active in
                    result.set(code, active); semaphore.signal()
                }
                guard semaphore.wait(timeout: .now() + 15) == .success else { break }
                let (code, active) = result.get()
                let data = Data("\(code) \(active ? 1 : 0)\n".utf8)
                do { try FileHandle.standardOutput.write(contentsOf: data) } catch { break }
            }
            connection.invalidate()
            exit(0)
        }
        dispatchMain()
    }
    private static func validatedRequirement(app: URL, helper: URL) -> String? {
        var bundleCode: SecStaticCode?, helperCode: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &bundleCode) == 0, let bundleCode,
              SecStaticCodeCheckValidity(bundleCode, flags, nil) == 0,
              SecStaticCodeCreateWithPath(helper as CFURL, [], &helperCode) == 0, let helperCode,
              SecStaticCodeCheckValidity(helperCode, flags, nil) == 0 else { return nil }
        var req: SecRequirement?, text: CFString?
        guard SecCodeCopyDesignatedRequirement(helperCode, [], &req) == 0, let req,
              SecRequirementCopyString(req, [], &text) == 0 else { return nil }
        return text as String?
    }
}
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Int32, Bool) = (ENOTCONN, false)
    func set(_ code: Int32, _ active: Bool) { lock.lock(); value = (code, active); lock.unlock() }
    func get() -> (Int32, Bool) { lock.lock(); defer { lock.unlock() }; return value }
}

private final class XPCOwner: @unchecked Sendable {
    let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
}
