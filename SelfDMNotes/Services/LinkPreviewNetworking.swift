import Darwin
import Foundation
import dnssd

struct LinkPreviewHTTPRequest: Sendable {
    let url: URL
    let acceptedContentTypes: Set<String>
    let maximumBytes: Int
    let timeout: TimeInterval
}

struct LinkPreviewHTTPResponse: Equatable, Sendable {
    let data: Data
    let finalURL: URL
    let contentType: String
}

protocol LinkPreviewHTTPFetching: Sendable {
    func fetch(_ request: LinkPreviewHTTPRequest) async throws -> LinkPreviewHTTPResponse
}

protocol LinkPreviewHostResolving: Sendable {
    func resolve(host: String, timeout: TimeInterval) async throws -> [ResolvedIPAddress]
}

struct ResolvedIPAddress: Hashable, Sendable {
    enum Family: Sendable {
        case ipv4
        case ipv6
    }

    let family: Family
    let bytes: [UInt8]
}

enum LinkPreviewURLNormalizer {
    static let maximumURLLength = 2_048

    static func normalize(_ url: URL) throws -> URL {
        guard url.absoluteString.count <= maximumURLLength,
              !url.absoluteString.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              var components = URLComponents(
                  url: url.standardized,
                  resolvingAgainstBaseURL: false
              ),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.user == nil,
              url.password == nil,
              var host = url.host(percentEncoded: false)?.lowercased(),
              !host.isEmpty else {
            throw LinkPreviewNetworkError.invalidURL
        }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { throw LinkPreviewNetworkError.invalidURL }

        components.scheme = scheme
        components.host = canonicalIPAddress(host) ?? host
        if (scheme == "http" && components.port == 80)
            || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if let port = components.port, !(1...65_535).contains(port) {
            throw LinkPreviewNetworkError.invalidURL
        }
        components.fragment = nil
        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/"
        }
        guard let normalized = components.url,
              normalized.absoluteString.count <= maximumURLLength else {
            throw LinkPreviewNetworkError.invalidURL
        }
        return normalized
    }

    static func detectedLink(originalURL: String, url: URL) throws -> DetectedLink {
        let normalized = try normalize(url)
        guard isUnfurlEligible(normalized) else {
            throw LinkPreviewNetworkError.unsafeDestination
        }
        return DetectedLink(
            originalURL: originalURL,
            requestKey: normalized.absoluteString,
            url: normalized
        )
    }

    private static func isUnfurlEligible(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased() else {
            return false
        }
        if host == "localhost" || host.hasSuffix(".localhost") {
            return false
        }

        var ipv4 = in_addr()
        if inet_aton(host, &ipv4) == 1 {
            return withUnsafeBytes(of: &ipv4) { $0.first != 127 }
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            return withUnsafeBytes(of: &ipv6) { bytes in
                !bytes.dropLast().allSatisfy({ $0 == 0 }) || bytes.last != 1
            }
        }
        return true
    }

    private static func canonicalIPAddress(_ host: String) -> String? {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return nil
            }
            return String(
                decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)),
                as: UTF8.self
            )
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                return nil
            }
            return String(
                decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)),
                as: UTF8.self
            )
        }
        return nil
    }
}

struct LinkDetector: Sendable {
    func links(in text: String) -> [DetectedLink] {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            return []
        }
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        var result: [DetectedLink] = []
        var seen = Set<String>()
        detector.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return
            }
            let original = source.substring(with: match.range)
            guard original.range(
                of: #"^https?://"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil,
                  let link = try? LinkPreviewURLNormalizer.detectedLink(
                      originalURL: original,
                      url: url
                  ),
                  seen.insert(link.requestKey).inserted else {
                return
            }
            result.append(link)
        }
        return result
    }
}

struct LinkTargetValidator: Sendable {
    private static let blockedHostSuffixes = [
        "localhost", ".localhost", ".local", ".internal", "home.arpa", ".home.arpa",
        ".invalid", ".test", ".example", ".onion"
    ]

    let resolver: any LinkPreviewHostResolving

    func validate(_ url: URL, timeout: TimeInterval) async throws {
        let normalized = try LinkPreviewURLNormalizer.normalize(url)
        guard let rawHost = normalized.host(percentEncoded: false) else {
            throw LinkPreviewNetworkError.invalidURL
        }
        let host = rawHost.lowercased()
        guard host.count <= 253,
              !host.contains("%"),
              !Self.blockedHostSuffixes.contains(where: { suffix in
                  suffix.hasPrefix(".") ? host.hasSuffix(suffix) : host == suffix
              }) else {
            throw LinkPreviewNetworkError.unsafeDestination
        }

        if let literal = Self.parseIPAddress(host) {
            guard Self.isGloballyRoutable(literal) else {
                throw LinkPreviewNetworkError.unsafeDestination
            }
            return
        }
        guard host.contains("."),
              host.split(separator: ".").allSatisfy({ label in
                  !label.isEmpty && label.count <= 63
              }) else {
            throw LinkPreviewNetworkError.unsafeDestination
        }

        let addresses = try await resolver.resolve(host: host, timeout: timeout)
        guard !addresses.isEmpty,
              addresses.allSatisfy(Self.isGloballyRoutable) else {
            throw LinkPreviewNetworkError.unsafeDestination
        }
    }

    static func isGloballyRoutable(_ address: ResolvedIPAddress) -> Bool {
        switch address.family {
        case .ipv4:
            guard address.bytes.count == 4 else { return false }
            return isGloballyRoutableIPv4(address.bytes)
        case .ipv6:
            let bytes = address.bytes
            guard bytes.count == 16 else { return false }
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return isGloballyRoutableIPv4(Array(bytes[12..<16]))
            }
            if Array(bytes[0..<12]) == [0x00, 0x64, 0xff, 0x9b] + Array(repeating: 0, count: 8) {
                return isGloballyRoutableIPv4(Array(bytes[12..<16]))
            }
            guard bytes[0] & 0xe0 == 0x20 else { return false }
            if bytes[0] == 0x20, bytes[1] == 0x01 {
                if bytes[2] == 0x0d, bytes[3] == 0xb8 { return false }
                // 2001::/23 contains protocol assignments and benchmarking/
                // documentation ranges, not ordinary globally routed hosts.
                if bytes[2] <= 0x01 { return false }
            }
            if bytes[0] == 0x20, bytes[1] == 0x02 { return false }
            if bytes[0] == 0x3f, bytes[1] & 0xf0 == 0xf0 { return false }
            return true
        }
    }

    private static func isGloballyRoutableIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let first = bytes[0]
        let second = bytes[1]
        if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
        if first == 100, (64...127).contains(second) { return false }
        if first == 169, second == 254 { return false }
        if first == 172, (16...31).contains(second) { return false }
        if first == 192 {
            if second == 0 || second == 168 { return false }
            if second == 88, bytes[2] == 99 { return false }
        }
        if first == 198, second == 18 || second == 19 { return false }
        if first == 198, second == 51, bytes[2] == 100 { return false }
        if first == 203, second == 0, bytes[2] == 113 { return false }
        return true
    }

    private static func parseIPAddress(_ host: String) -> ResolvedIPAddress? {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            return withUnsafeBytes(of: &ipv4) {
                ResolvedIPAddress(family: .ipv4, bytes: Array($0))
            }
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            return withUnsafeBytes(of: &ipv6) {
                ResolvedIPAddress(family: .ipv6, bytes: Array($0))
            }
        }
        return nil
    }
}

final class SystemLinkPreviewHostResolver: LinkPreviewHostResolving, @unchecked Sendable {
    private let callbackQueue = DispatchQueue(
        label: "com.selfdmnotes.link-preview-dns",
        qos: .utility
    )
    private let lifecycleHooks: DNSResolutionLifecycleHooks?

    init(lifecycleHooks: DNSResolutionLifecycleHooks? = nil) {
        self.lifecycleHooks = lifecycleHooks
    }

    func resolve(host: String, timeout: TimeInterval) async throws -> [ResolvedIPAddress] {
        let operation = DNSResolutionOperation(
            host: host,
            queue: callbackQueue,
            lifecycleHooks: lifecycleHooks
        )
        return try await withTaskCancellationHandler {
            try await operation.value(timeout: timeout)
        } onCancel: {
            operation.cancel()
        }
    }
}

struct DNSResolutionLifecycleHooks: Sendable {
    let didAssociateQueue: @Sendable () -> Void
    let didCleanUpOnQueue: @Sendable () -> Void
}

private final class DNSResolutionOperation: @unchecked Sendable {
    private let host: String
    private let queue: DispatchQueue
    private let lifecycleHooks: DNSResolutionLifecycleHooks?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[ResolvedIPAddress], Error>?
    private var service: DNSServiceRef?
    private var retainedContext: UnsafeMutableRawPointer?
    private var timeoutWorkItem: DispatchWorkItem?
    private var settleWorkItem: DispatchWorkItem?
    private var addresses = Set<ResolvedIPAddress>()
    private var queueAssociated = false
    private var finished = false

    init(
        host: String,
        queue: DispatchQueue,
        lifecycleHooks: DNSResolutionLifecycleHooks?
    ) {
        self.host = host
        self.queue = queue
        self.lifecycleHooks = lifecycleHooks
    }

    func value(timeout: TimeInterval) async throws -> [ResolvedIPAddress] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !finished else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()
            start(timeout: timeout)
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func start(timeout: TimeInterval) {
        let context = Unmanaged.passRetained(self).toOpaque()
        let timeoutItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure(LinkPreviewNetworkError.timedOut))
        }

        // Keep creation, ownership publication, queue association, and the
        // finished check under one lock. Cancellation can then only happen
        // wholly before or wholly after DNSServiceRef setup.
        lock.lock()
        guard !finished else {
            lock.unlock()
            Unmanaged<DNSResolutionOperation>.fromOpaque(context).release()
            return
        }
        retainedContext = context
        var reference: DNSServiceRef?
        let status = DNSServiceGetAddrInfo(
            &reference,
            0,
            0,
            UInt32(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6),
            host,
            dnsResolutionCallback,
            context
        )
        guard status == kDNSServiceErr_NoError, let reference else {
            service = reference
            lock.unlock()
            finish(.failure(LinkPreviewNetworkError.dnsResolutionFailed))
            return
        }
        service = reference
        guard DNSServiceSetDispatchQueue(reference, queue) == kDNSServiceErr_NoError else {
            lock.unlock()
            finish(.failure(LinkPreviewNetworkError.dnsResolutionFailed))
            return
        }
        queueAssociated = true
        timeoutWorkItem = timeoutItem
        lock.unlock()
        lifecycleHooks?.didAssociateQueue()
        queue.asyncAfter(deadline: .now() + max(0.1, timeout), execute: timeoutItem)
    }

    fileprivate func receive(
        flags: DNSServiceFlags,
        error: DNSServiceErrorType,
        address: UnsafePointer<sockaddr>?
    ) {
        lock.lock()
        let shouldIgnore = finished
        lock.unlock()
        guard !shouldIgnore else { return }
        if error == kDNSServiceErr_NoSuchRecord {
            scheduleSettle()
            return
        }
        guard error == kDNSServiceErr_NoError, let address else {
            finish(.failure(LinkPreviewNetworkError.dnsResolutionFailed))
            return
        }
        let resolved: ResolvedIPAddress?
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            resolved = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                var value = $0.pointee.sin_addr
                return withUnsafeBytes(of: &value) {
                    ResolvedIPAddress(family: .ipv4, bytes: Array($0))
                }
            }
        case AF_INET6:
            resolved = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                var value = $0.pointee.sin6_addr
                return withUnsafeBytes(of: &value) {
                    ResolvedIPAddress(family: .ipv6, bytes: Array($0))
                }
            }
        default:
            resolved = nil
        }
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        settleWorkItem?.cancel()
        settleWorkItem = nil
        if let resolved { addresses.insert(resolved) }
        lock.unlock()
        if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 {
            scheduleSettle()
        }
    }

    private func scheduleSettle() {
        let settle = DispatchWorkItem { [weak self] in
            guard let self else { return }
            lock.lock()
            let values = Array(addresses)
            lock.unlock()
            finish(values.isEmpty
                ? .failure(LinkPreviewNetworkError.dnsResolutionFailed)
                : .success(values))
        }
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        settleWorkItem?.cancel()
        settleWorkItem = settle
        lock.unlock()
        // DNSServiceGetAddrInfo is a streaming API. A short quiet period
        // collects the initial A and AAAA answer sets before validation.
        queue.asyncAfter(deadline: .now() + 0.25, execute: settle)
    }

    private func finish(_ result: Result<[ResolvedIPAddress], Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let requiresQueueCleanup = queueAssociated
        let service = requiresQueueCleanup ? nil : service
        let context = requiresQueueCleanup ? nil : retainedContext
        if !requiresQueueCleanup {
            self.service = nil
            retainedContext = nil
        }
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        settleWorkItem?.cancel()
        settleWorkItem = nil
        lock.unlock()

        continuation?.resume(with: result)
        if requiresQueueCleanup {
            // DNS-SD requires teardown on the queue associated with the ref.
            // Enqueuing also ensures an executing callback returns before its
            // retained context can be released.
            queue.async { [self] in cleanupAssociatedResources() }
        } else {
            if let service { DNSServiceRefDeallocate(service) }
            if let context {
                Unmanaged<DNSResolutionOperation>.fromOpaque(context).release()
            }
        }
    }

    private func cleanupAssociatedResources() {
        lock.lock()
        let service = service
        self.service = nil
        let context = retainedContext
        retainedContext = nil
        queueAssociated = false
        lock.unlock()

        if let service { DNSServiceRefDeallocate(service) }
        if let context {
            Unmanaged<DNSResolutionOperation>.fromOpaque(context).release()
        }
        lifecycleHooks?.didCleanUpOnQueue()
    }
}

private let dnsResolutionCallback: DNSServiceGetAddrInfoReply = {
    _, flags, _, error, _, address, _, context in
    guard let context else { return }
    Unmanaged<DNSResolutionOperation>
        .fromOpaque(context)
        .takeUnretainedValue()
        .receive(flags: flags, error: error, address: address)
}

final class LinkPreviewHTTPClient: LinkPreviewHTTPFetching, @unchecked Sendable {
    static let maximumRedirects = 5

    private let validator: LinkTargetValidator
    private let protocolClasses: [AnyClass]?
    private let beforeContinuationRegistration: (@Sendable () -> Void)?

    init(
        resolver: any LinkPreviewHostResolving = SystemLinkPreviewHostResolver(),
        protocolClasses: [AnyClass]? = nil,
        beforeContinuationRegistration: (@Sendable () -> Void)? = nil
    ) {
        validator = LinkTargetValidator(resolver: resolver)
        self.protocolClasses = protocolClasses
        self.beforeContinuationRegistration = beforeContinuationRegistration
    }

    func fetch(_ request: LinkPreviewHTTPRequest) async throws -> LinkPreviewHTTPResponse {
        try Task.checkCancellation()
        guard request.maximumBytes > 0, request.timeout > 0 else {
            throw LinkPreviewNetworkError.invalidRequest
        }
        let normalized = try LinkPreviewURLNormalizer.normalize(request.url)
        let deadline = Date().addingTimeInterval(request.timeout)
        try await validator.validate(normalized, timeout: remaining(until: deadline))
        try Task.checkCancellation()
        return try await URLSessionAccumulator(
            request: request,
            initialURL: normalized,
            deadline: deadline,
            validator: validator,
            protocolClasses: protocolClasses,
            beforeContinuationRegistration: beforeContinuationRegistration
        ).value()
    }

    private func remaining(until deadline: Date) throws -> TimeInterval {
        let interval = deadline.timeIntervalSinceNow
        guard interval > 0 else { throw LinkPreviewNetworkError.timedOut }
        return interval
    }
}

private final class URLSessionAccumulator: NSObject, URLSessionDataDelegate,
    URLSessionTaskDelegate, @unchecked Sendable {
    private let request: LinkPreviewHTTPRequest
    private let initialURL: URL
    private let deadline: Date
    private let validator: LinkTargetValidator
    private let protocolClasses: [AnyClass]?
    private let beforeContinuationRegistration: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LinkPreviewHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var receivedData = Data()
    private var redirectCount = 0
    private var redirectValidationTasks: [UUID: Task<Void, Never>] = [:]
    private var redirectCompletions: [UUID: RedirectCompletion] = [:]
    private var terminalResult: Result<LinkPreviewHTTPResponse, Error>?

    init(
        request: LinkPreviewHTTPRequest,
        initialURL: URL,
        deadline: Date,
        validator: LinkTargetValidator,
        protocolClasses: [AnyClass]?,
        beforeContinuationRegistration: (@Sendable () -> Void)?
    ) {
        self.request = request
        self.initialURL = initialURL
        self.deadline = deadline
        self.validator = validator
        self.protocolClasses = protocolClasses
        self.beforeContinuationRegistration = beforeContinuationRegistration
    }

    func value() async throws -> LinkPreviewHTTPResponse {
        return try await withTaskCancellationHandler {
            beforeContinuationRegistration?()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let terminalResult {
                    lock.unlock()
                    continuation.resume(with: terminalResult)
                    return
                }
                precondition(self.continuation == nil)
                self.continuation = continuation
                lock.unlock()
                start()
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func start() {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            finish(.failure(LinkPreviewNetworkError.timedOut))
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = min(8, remaining)
        configuration.timeoutIntervalForResource = remaining
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [
            "HTTPEnable": false,
            "HTTPSEnable": false,
            "SOCKSEnable": false,
            "ProxyAutoConfigEnable": false,
            "ProxyAutoDiscoveryEnable": false
        ]
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: cleanRequest(for: initialURL))
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            session.invalidateAndCancel()
            return
        }
        self.session = session
        self.task = task
        task.resume()
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + remaining) { [weak self] in
            self?.finish(.failure(LinkPreviewNetworkError.timedOut))
        }
    }

    private func cleanRequest(for url: URL) -> URLRequest {
        var result = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: min(8, max(0.1, deadline.timeIntervalSinceNow))
        )
        result.httpMethod = "GET"
        result.httpShouldHandleCookies = false
        result.setValue(
            request.acceptedContentTypes.sorted().joined(separator: ", "),
            forHTTPHeaderField: "Accept"
        )
        return result
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let mimeType = response.mimeType?.lowercased(),
              request.acceptedContentTypes.contains(mimeType) else {
            completionHandler(.cancel)
            finish(.failure(LinkPreviewNetworkError.unacceptableResponse))
            return
        }
        if response.expectedContentLength > Int64(request.maximumBytes) {
            completionHandler(.cancel)
            finish(.failure(LinkPreviewNetworkError.responseTooLarge))
            return
        }
        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard terminalResult == nil,
              receivedData.count <= request.maximumBytes - data.count else {
            lock.unlock()
            finish(.failure(LinkPreviewNetworkError.responseTooLarge))
            return
        }
        receivedData.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = newRequest.url else {
            completionHandler(nil)
            finish(.failure(LinkPreviewNetworkError.invalidURL))
            return
        }
        let redirectCompletion = RedirectCompletion(completionHandler)
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            redirectCompletion.call(nil)
            return
        }
        redirectCount += 1
        let tooManyRedirects = redirectCount > LinkPreviewHTTPClient.maximumRedirects
        lock.unlock()
        guard !tooManyRedirects else {
            redirectCompletion.call(nil)
            finish(.failure(LinkPreviewNetworkError.tooManyRedirects))
            return
        }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            redirectCompletion.call(nil)
            finish(.failure(LinkPreviewNetworkError.timedOut))
            return
        }
        let validationID = UUID()
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            redirectCompletion.call(nil)
            return
        }
        redirectCompletions[validationID] = redirectCompletion
        let validationTask = Task { [weak self] in
            defer { self?.removeRedirectValidationTask(validationID) }
            guard let self else {
                redirectCompletion.call(nil)
                return
            }
            do {
                let normalized = try LinkPreviewURLNormalizer.normalize(url)
                try await validator.validate(normalized, timeout: remaining)
                try Task.checkCancellation()
                redirectCompletion.call(cleanRequest(for: normalized))
            } catch {
                redirectCompletion.call(nil)
                finish(.failure(error))
            }
        }
        redirectValidationTasks[validationID] = validationTask
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let response = response
        let data = receivedData
        lock.unlock()
        if let error {
            let urlError = error as? URLError
            finish(.failure(
                urlError?.code == .timedOut
                    ? LinkPreviewNetworkError.timedOut
                    : LinkPreviewNetworkError.transportFailed
            ))
            return
        }
        guard let response,
              let finalURL = response.url,
              let contentType = response.mimeType?.lowercased() else {
            finish(.failure(LinkPreviewNetworkError.unacceptableResponse))
            return
        }
        finish(.success(LinkPreviewHTTPResponse(
            data: data,
            finalURL: finalURL,
            contentType: contentType
        )))
    }

    private func finish(_ result: Result<LinkPreviewHTTPResponse, Error>) {
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        terminalResult = result
        let continuation = continuation
        self.continuation = nil
        let task = task
        self.task = nil
        let session = session
        self.session = nil
        let redirectValidationTasks = Array(redirectValidationTasks.values)
        self.redirectValidationTasks.removeAll()
        let redirectCompletions = Array(redirectCompletions.values)
        self.redirectCompletions.removeAll()
        lock.unlock()

        for task in redirectValidationTasks { task.cancel() }
        for completion in redirectCompletions { completion.call(nil) }
        task?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    private func removeRedirectValidationTask(_ id: UUID) {
        lock.lock()
        redirectValidationTasks[id] = nil
        redirectCompletions[id] = nil
        lock.unlock()
    }
}

private final class RedirectCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: (URLRequest?) -> Void
    private var completed = false

    init(_ handler: @escaping (URLRequest?) -> Void) {
        self.handler = handler
    }

    func call(_ request: URLRequest?) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        handler(request)
    }
}

enum LinkPreviewNetworkError: LocalizedError, Equatable {
    case dnsResolutionFailed
    case invalidRequest
    case invalidURL
    case responseTooLarge
    case timedOut
    case tooManyRedirects
    case transportFailed
    case unacceptableResponse
    case unsafeDestination

    var errorDescription: String? {
        switch self {
        case .dnsResolutionFailed:
            "The destination name could not be resolved safely."
        case .invalidRequest:
            "The preview request policy is invalid."
        case .invalidURL:
            "The link is not a valid HTTP or HTTPS destination."
        case .responseTooLarge:
            "The linked content exceeded the preview size limit."
        case .timedOut:
            "The linked website did not respond within the preview time limit."
        case .tooManyRedirects:
            "The linked website redirected too many times."
        case .transportFailed:
            "The linked website could not be reached."
        case .unacceptableResponse:
            "The linked website returned an unsupported status or content type."
        case .unsafeDestination:
            "Preview fetching was blocked because the link resolves to a local, private, reserved, or otherwise unsafe destination."
        }
    }
}
