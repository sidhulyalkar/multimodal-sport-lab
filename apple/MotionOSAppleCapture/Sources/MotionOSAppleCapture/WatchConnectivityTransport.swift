#if canImport(WatchConnectivity)
import Foundation
import WatchConnectivity

public final class WatchConnectivityTransport: NSObject, WCSessionDelegate {
    public let session: WCSession
    public var onFileReceived: ((URL, [String: Any]?) -> Void)?

    public override init() {
        session = .default
        super.init()
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
        }
    }

    @discardableResult
    public func transferJournal(
        _ url: URL,
        metadata: [String: Any]? = nil
    ) -> WCSessionFileTransfer? {
        guard session.activationState == .activated else { return nil }
        return session.transferFile(url, metadata: metadata)
    }

    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    public func session(_ session: WCSession, didReceive file: WCSessionFile) {
        do {
            let manager = FileManager.default
            let stagingDirectory = manager.temporaryDirectory
                .appendingPathComponent("MotionOSReceived", isDirectory: true)
            try manager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )

            let stagedURL = stagingDirectory.appendingPathComponent(
                "\(UUID().uuidString)-\(file.fileURL.lastPathComponent)"
            )
            try manager.copyItem(at: file.fileURL, to: stagedURL)
            onFileReceived?(stagedURL, file.metadata)
        } catch {
            // The app can observe missing transfer completion through its
            // journal inbox. Never hand out the delegate's ephemeral URL.
        }
    }

    #if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {}
    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
#endif
