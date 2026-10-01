#if canImport(WatchConnectivity)
import Foundation
import WatchConnectivity

public final class WatchConnectivityTransport: NSObject, WCSessionDelegate {
    public let session: WCSession
    public var onFileReceived: ((URL, [String: Any]?) -> Void)?
    public var onFileTransferFinished: (
        (URL, [String: Any]?, Error?) -> Void
    )?
    public var onUserInfoReceived: (([String: Any]) -> Void)?
    public var onMessageReceived: (([String: Any]) -> Void)?
    public var onApplicationContextReceived: (([String: Any]) -> Void)?
    public var onStateChanged: (() -> Void)?

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

        // WatchConnectivity already owns queued background transfers. Reuse an
        // existing transfer for the same MotionOS session instead of creating
        // duplicate payloads when the UI is reopened or a retry is requested.
        if let sessionID = metadata?["session_id"] as? String,
           let existing = session.outstandingFileTransfers.first(where: {
               $0.file.metadata?["session_id"] as? String == sessionID
           }) {
            return existing
        }

        return session.transferFile(url, metadata: metadata)
    }

    @discardableResult
    public func queueUserInfo(
        _ userInfo: [String: Any]
    ) -> WCSessionUserInfoTransfer? {
        guard session.activationState == .activated else { return nil }
        return session.transferUserInfo(userInfo)
    }

    @discardableResult
    public func updateApplicationContext(
        _ context: [String: Any]
    ) -> Bool {
        guard session.activationState == .activated else { return false }
        do {
            try session.updateApplicationContext(context)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func sendMessage(
        _ message: [String: Any]
    ) -> Bool {
        guard session.activationState == .activated,
              session.isReachable
        else {
            return false
        }

        session.sendMessage(
            message,
            replyHandler: nil,
            errorHandler: nil
        )
        return true
    }

    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        onStateChanged?()
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        onStateChanged?()
    }

    #if os(iOS)
    public func sessionWatchStateDidChange(_ session: WCSession) {
        // Apple calls this when pairing, Watch-app installation, complication,
        // or active-Watch directory state changes. Propagate it so the
        // readiness UI does not retain a stale installation result.
        onStateChanged?()
    }
    #endif

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

    public func session(
        _ session: WCSession,
        fileTransfer: WCSessionFileTransfer,
        didFinishWithError error: Error?
    ) {
        onFileTransferFinished?(
            fileTransfer.file.fileURL,
            fileTransfer.file.metadata,
            error
        )
        onStateChanged?()
    }

    public func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        onUserInfoReceived?(userInfo)
    }

    public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        onMessageReceived?(message)
    }

    public func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        onApplicationContextReceived?(applicationContext)
    }

    #if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {
        onStateChanged?()
    }

    public func sessionDidDeactivate(_ session: WCSession) {
        // Surface the deactivation before activating the newly selected Watch,
        // so consumers can discard state belonging to the previous companion.
        onStateChanged?()
        session.activate()
    }
    #endif
}
#endif
