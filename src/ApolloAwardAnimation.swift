import Foundation
import UIKit

private func ApolloAwardAnimationDebug(_ message: String) {
    #if APOLLO_SIM_BUILD
    NotificationCenter.default.post(name: Notification.Name("ApolloAwardAnimationDiagnostic"), object: message)
    #endif
}

private final class ApolloAwardEmbeddedImages: AnimationImageProvider {
    let images: [String: CGImage]
    var cacheEligible: Bool { false }
    init(_ images: [String: CGImage]) { self.images = images }
    // No bundle paths, remote URLs, or Lottie's default image provider.
    func imageForAsset(asset: ImageAsset) -> CGImage? { images[asset.id] }
}

private final class ApolloAwardAnimationEntry {
    let animation: LottieAnimation
    let provider: ApolloAwardEmbeddedImages
    let cost: Int
    init(_ data: Data) throws {
        let document: ApolloAwardAnimationDocument
        do { document = try ApolloAwardAnimationDocument(data: data) }
        catch {
            ApolloAwardAnimationDebug("preflight failed bytes=\(data.count)")
            throw error
        }
        do { animation = try LottieAnimation.from(data: document.data) }
        catch {
            ApolloAwardAnimationDebug("Lottie decoding failed type=\(type(of: error)) bytes=\(data.count)")
            throw error
        }
        provider = ApolloAwardEmbeddedImages(document.images)
        cost = document.cacheCost
    }
}

// Each request owns an ephemeral, credential-free session and limits bytes
// while receiving them. Parsing/image decoding stays on its serial delegate
// queue. The small cache coordinator below is exclusively main-thread-owned.
private final class ApolloAwardAnimationRequest: NSObject, URLSessionDataDelegate {
    let url: URL
    var callbacks: [UUID: (ApolloAwardAnimationEntry?) -> Void] = [:]
    private var session: URLSession?
    private var body = Data()
    private var accepted = false
    private var complete = false

    init(url: URL) { self.url = url }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ApolloReborn-awards-animation/1.0", forHTTPHeaderField: "User-Agent")
        session?.dataTask(with: request).resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let type = response.mimeType?.lowercased() ?? ""
        accepted = (response as? HTTPURLResponse)?.statusCode == 200 &&
            (type == "application/json" || type == "text/plain" || type == "application/octet-stream") &&
            response.expectedContentLength <= ApolloAwardAnimationDocument.maximumBytes
        completionHandler(accepted ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count + data.count <= ApolloAwardAnimationDocument.maximumBytes else {
            accepted = false
            dataTask.cancel()
            return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !complete else { return }
        complete = true
        let entry = accepted && error == nil ? try? ApolloAwardAnimationEntry(body) : nil
        body.removeAll()
        session.finishTasksAndInvalidate()
        self.session = nil
        DispatchQueue.main.async { ApolloAwardAnimationCache.shared.finished(self, entry: entry) }
    }
}

private final class ApolloAwardAnimationCache {
    static let shared = ApolloAwardAnimationCache()
    private var entries: [URL: ApolloAwardAnimationEntry] = [:]
    private var order: [URL] = []
    private var cost = 0
    private var failures: [URL: Date] = [:]
    private var requests: [URL: ApolloAwardAnimationRequest] = [:]
    private var queue: [ApolloAwardAnimationRequest] = []
    private var active = 0

    #if APOLLO_SIM_BUILD
    var debugSnapshot: [String: Any] {
        ["cached": entries.count, "cacheCost": cost, "queued": queue.count, "activeRequests": active, "failures": failures.count]
    }
    #endif

    func load(_ url: URL, token: UUID, completion: @escaping (ApolloAwardAnimationEntry?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let entry = entries[url] {
            order.removeAll { $0 == url }
            order.append(url)
            DispatchQueue.main.async { completion(entry) }
            return
        }
        failures = failures.filter { $0.value.timeIntervalSinceNow > 0 }
        guard ApolloAwardAnimationDocument.accepts(url: url), failures[url] == nil else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        if let pending = requests[url], pending.callbacks.count < 16 {
            pending.callbacks[token] = completion
            return
        }
        guard requests[url] == nil, queue.count < 16 else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let request = ApolloAwardAnimationRequest(url: url)
        request.callbacks[token] = completion
        requests[url] = request
        queue.append(request)
        drain()
    }

    func cancel(_ url: URL, token: UUID) {
        guard let request = requests[url] else { return }
        request.callbacks.removeValue(forKey: token)
        if request.callbacks.isEmpty, let index = queue.firstIndex(where: { $0 === request }) {
            queue.remove(at: index)
            requests.removeValue(forKey: url)
        }
        // An active bounded download may finish and warm the shared icon cache.
    }

    private func drain() {
        while active < 2, !queue.isEmpty {
            let next = queue.removeFirst()
            active += 1
            next.start()
        }
    }

    func finished(_ request: ApolloAwardAnimationRequest, entry: ApolloAwardAnimationEntry?) {
        active -= 1
        requests.removeValue(forKey: request.url)
        if let entry = entry {
            entries[request.url] = entry
            order.append(request.url)
            cost += entry.cost
            while order.count > 12 || cost > 12 * 1024 * 1024 {
                let oldest = order.removeFirst()
                if let removed = entries.removeValue(forKey: oldest) { cost -= removed.cost }
            }
        } else {
            if failures.count >= 64 { failures.removeAll() }
            failures[request.url] = Date(timeIntervalSinceNow: 300)
        }
        let callbacks = Array(request.callbacks.values)
        request.callbacks.removeAll()
        for callback in callbacks { callback(entry) }
        drain()
    }
}

@objc(ApolloAwardAnimationView)
final class ApolloAwardAnimationView: UIView {
    private static let activePlayers = NSHashTable<ApolloAwardAnimationView>.weakObjects()
    #if APOLLO_SIM_BUILD
    private static let allViews = NSHashTable<ApolloAwardAnimationView>.weakObjects()
    @objc class func debugSnapshot() -> NSDictionary {
        let views: [[String: Any]] = allViews.allObjects.map { view in
            ["asset": view.animationURL.lastPathComponent, "display": view.displayActive,
             "window": view.window != nil, "hidden": view.isHidden, "failed": view.failed,
             "loading": view.loadToken != nil, "playing": view.player?.isAnimationPlaying ?? false,
             "progress": view.player?.currentProgress ?? -1, "bounds": String(describing: view.bounds),
             "stillHidden": view.stillImageView?.isHidden ?? false,
             "engine": String(describing: view.player?.currentRenderingEngine)]
        }
        return ["cache": ApolloAwardAnimationCache.shared.debugSnapshot,
                "players": activePlayers.allObjects.count, "views": views,
                "reduceMotion": UIAccessibility.isReduceMotionEnabled,
                "applicationState": UIApplication.shared.applicationState.rawValue] as NSDictionary
    }
    #endif
    private let animationURL: URL
    private weak var stillImageView: UIImageView?
    private var player: LottieAnimationView?
    private var loadToken: UUID?
    private var failed = false
    private var removed = false
    private var observers: [NSObjectProtocol] = []

    @objc var displayActive = false {
        didSet { updatePlayback() }
    }

    @objc(initWithURL:stillImageView:)
    init(url: URL, stillImageView: UIImageView) {
        animationURL = url
        self.stillImageView = stillImageView
        super.init(frame: .zero)
        #if APOLLO_SIM_BUILD
        Self.allViews.add(self)
        #endif
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isHidden = true
        for name in [UIAccessibility.reduceMotionStatusDidChangeNotification,
                     UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if note.name == UIApplication.willResignActiveNotification || note.name == UIApplication.didEnterBackgroundNotification {
                    self?.pause()
                } else {
                    self?.updatePlayback()
                }
            })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let token = loadToken { ApolloAwardAnimationCache.shared.cancel(animationURL, token: token) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePlayback()
    }

    @objc func prepareForRemoval() {
        removed = true
        displayActive = false
        player?.removeFromSuperview()
        player = nil
    }

    private func pause() {
        if let token = loadToken {
            ApolloAwardAnimationCache.shared.cancel(animationURL, token: token)
            loadToken = nil
        }
        player?.pause()
        player?.removeFromSuperview()
        player = nil
        Self.activePlayers.remove(self)
        isHidden = true
        stillImageView?.isHidden = false
    }

    private func updatePlayback() {
        guard !removed, displayActive, window != nil,
              UIApplication.shared.applicationState == .active,
              !UIAccessibility.isReduceMotionEnabled else {
            pause()
            return
        }
        if let player = player {
            isHidden = false
            stillImageView?.isHidden = true
            if !player.isAnimationPlaying { player.play() }
            ApolloAwardAnimationDebug("play asset=\(animationURL.lastPathComponent) playing=\(player.isAnimationPlaying) bounds=\(String(describing: bounds)) engine=\(String(describing: player.currentRenderingEngine))")
            return
        }
        guard loadToken == nil, !failed else { return }
        let token = UUID()
        loadToken = token
        ApolloAwardAnimationCache.shared.load(animationURL, token: token) { [weak self] entry in
            guard let self = self, self.loadToken == token else { return }
            self.loadToken = nil
            guard let entry = entry else {
                self.failed = true
                ApolloAwardAnimationDebug("view load failed asset=\(self.animationURL.lastPathComponent)")
                return
            }
            ApolloAwardAnimationDebug("view entry ready asset=\(self.animationURL.lastPathComponent) images=\(entry.provider.images.count) cost=\(entry.cost)")
            // A very large detail sheet keeps excess rows as still icons.
            // Offscreen cells release their renderer instead of extending the
            // cache's memory budget through UITableView's reuse pool.
            guard Self.activePlayers.allObjects.count < 16 else { return }
            // Unknown renderer features remain an optional visual enhancement;
            // they must not trigger debug assertions or log public JSON bodies.
            let logger = LottieLogger(assert: { _, _, _, _ in }, assertionFailure: { _, _, _ in },
                                      warn: { _, _, _ in }, info: { _ in })
            let player = LottieAnimationView(animation: entry.animation, imageProvider: entry.provider,
                                            configuration: LottieConfiguration(renderingEngine: .automatic), logger: logger)
            player.loopMode = .loop
            player.backgroundBehavior = .pauseAndRestore
            player.contentMode = .scaleAspectFit
            player.isUserInteractionEnabled = false
            player.frame = self.bounds
            player.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            self.addSubview(player)
            self.player = player
            Self.activePlayers.add(self)
            self.updatePlayback()
        }
    }
}
