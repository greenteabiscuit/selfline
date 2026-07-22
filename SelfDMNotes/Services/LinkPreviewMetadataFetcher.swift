import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol LinkPreviewMetadataFetching: Sendable {
    func fetchPreview(for url: URL) async throws -> LinkPreviewMetadata
}

final class LinkPreviewMetadataFetcher: LinkPreviewMetadataFetching, @unchecked Sendable {
    static let maximumHTMLBytes = 1_048_576
    static let maximumImageBytes = 2_097_152
    static let requestTimeout: TimeInterval = 12

    private static let htmlContentTypes: Set<String> = [
        "text/html", "application/xhtml+xml"
    ]
    private static let imageContentTypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp",
        "image/x-icon", "image/vnd.microsoft.icon"
    ]

    private let httpClient: any LinkPreviewHTTPFetching
    private let parser: HTMLLinkPreviewParser
    private let imageProcessor: LinkPreviewImageProcessor

    init(
        httpClient: any LinkPreviewHTTPFetching = LinkPreviewHTTPClient(),
        parser: HTMLLinkPreviewParser = HTMLLinkPreviewParser(),
        imageProcessor: LinkPreviewImageProcessor = LinkPreviewImageProcessor()
    ) {
        self.httpClient = httpClient
        self.parser = parser
        self.imageProcessor = imageProcessor
    }

    func fetchPreview(for url: URL) async throws -> LinkPreviewMetadata {
        let page = try await httpClient.fetch(
            LinkPreviewHTTPRequest(
                url: url,
                acceptedContentTypes: Self.htmlContentTypes,
                maximumBytes: Self.maximumHTMLBytes,
                timeout: Self.requestTimeout
            )
        )
        try Task.checkCancellation()
        let parsed = parser.parse(data: page.data, baseURL: page.finalURL)
        var imageURL: String?
        var imagePNGData: Data?

        for candidate in parsed.imageCandidates.prefix(2) {
            do {
                let response = try await httpClient.fetch(
                    LinkPreviewHTTPRequest(
                        url: candidate,
                        acceptedContentTypes: Self.imageContentTypes,
                        maximumBytes: Self.maximumImageBytes,
                        timeout: Self.requestTimeout
                    )
                )
                try Task.checkCancellation()
                imagePNGData = try imageProcessor.makeStaticThumbnail(from: response.data)
                imageURL = response.finalURL.absoluteString
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                // A hostile or unavailable image must not discard useful text metadata.
                continue
            }
        }

        return LinkPreviewMetadata(
            canonicalURL: page.finalURL.absoluteString,
            title: parsed.title,
            summary: parsed.summary,
            imageURL: imageURL,
            siteName: parsed.siteName,
            imagePNGData: imagePNGData
        )
    }
}

struct ParsedHTMLLinkPreview: Equatable, Sendable {
    let title: String
    let summary: String?
    let siteName: String
    let imageCandidates: [URL]
}

struct HTMLLinkPreviewParser: Sendable {
    private static let tagExpression = try! NSRegularExpression(
        pattern: #"<(meta|link)\b[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let titleExpression = try! NSRegularExpression(
        pattern: #"<title\b[^>]*>(.*?)</title\s*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let attributeExpression = try! NSRegularExpression(
        pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)(?:\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+)))?"#,
        options: []
    )

    func parse(data: Data, baseURL: URL) -> ParsedHTMLLinkPreview {
        let html = decode(data)
        let source = html as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        var metadata: [String: String] = [:]
        var iconURL: URL?

        for match in Self.tagExpression.matches(in: html, range: fullRange) {
            let tag = source.substring(with: match.range)
            let attributes = parseAttributes(tag)
            let kind = source.substring(with: match.range(at: 1)).lowercased()
            if kind == "meta",
               let key = (attributes["property"] ?? attributes["name"])?.lowercased(),
               let content = attributes["content"],
               metadata[key] == nil {
                metadata[key] = content
            } else if kind == "link",
                      let relationship = attributes["rel"]?.lowercased(),
                      relationship.split(whereSeparator: \.isWhitespace).contains(where: {
                          $0 == "icon" || $0 == "shortcut"
                      }),
                      let href = attributes["href"],
                      iconURL == nil {
                iconURL = safeResourceURL(href, relativeTo: baseURL)
            }
        }

        let titleMatch = Self.titleExpression.firstMatch(in: html, range: fullRange)
        let htmlTitle = titleMatch.map {
            source.substring(with: $0.range(at: 1))
        }
        let host = baseURL.host(percentEncoded: false) ?? baseURL.absoluteString
        let title = sanitize(metadata["og:title"] ?? htmlTitle, maximumLength: 300)
            ?? sanitize(host, maximumLength: 300)
            ?? "Linked website"
        let summary = sanitize(
            metadata["og:description"] ?? metadata["description"],
            maximumLength: 1_000
        )
        let siteName = sanitize(metadata["og:site_name"], maximumLength: 200)
            ?? sanitize(host, maximumLength: 200)
            ?? "Website"

        var imageCandidates: [URL] = []
        if let imageValue = metadata["og:image"] ?? metadata["og:image:url"],
           let image = safeResourceURL(imageValue, relativeTo: baseURL) {
            imageCandidates.append(image)
        }
        if let iconURL, !imageCandidates.contains(iconURL) {
            imageCandidates.append(iconURL)
        } else if imageCandidates.isEmpty,
                  let favicon = URL(string: "/favicon.ico", relativeTo: baseURL)?.absoluteURL,
                  let safeFavicon = try? LinkPreviewURLNormalizer.normalize(favicon) {
            imageCandidates.append(safeFavicon)
        }

        return ParsedHTMLLinkPreview(
            title: title,
            summary: summary,
            siteName: siteName,
            imageCandidates: imageCandidates
        )
    }

    private func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
    }

    private func parseAttributes(_ tag: String) -> [String: String] {
        let source = tag as NSString
        let range = NSRange(location: 0, length: source.length)
        var result: [String: String] = [:]
        for match in Self.attributeExpression.matches(in: tag, range: range) {
            let name = source.substring(with: match.range(at: 1)).lowercased()
            guard result[name] == nil else { continue }
            for index in 2...4 where match.range(at: index).location != NSNotFound {
                result[name] = decodeEntities(source.substring(with: match.range(at: index)))
                break
            }
        }
        return result
    }

    private func safeResourceURL(_ value: String, relativeTo baseURL: URL) -> URL? {
        guard let resolved = URL(string: value, relativeTo: baseURL)?.absoluteURL else {
            return nil
        }
        return try? LinkPreviewURLNormalizer.normalize(resolved)
    }

    private func sanitize(_ value: String?, maximumLength: Int) -> String? {
        guard var value else { return nil }
        value = decodeEntities(value)
        value = value.replacingOccurrences(
            of: #"<[^>]*>"#,
            with: " ",
            options: .regularExpression
        )
        let scalars = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }
        let collapsed = String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumLength))
    }

    private func decodeEntities(_ input: String) -> String {
        let expression = try! NSRegularExpression(
            pattern: #"&(#x[0-9A-Fa-f]+|#[0-9]+|amp|quot|apos|lt|gt|nbsp);"#,
            options: [.caseInsensitive]
        )
        let source = input as NSString
        let matches = expression.matches(
            in: input,
            range: NSRange(location: 0, length: source.length)
        )
        var result = input
        for match in matches.reversed() {
            let entity = source.substring(with: match.range(at: 1)).lowercased()
            let replacement: String?
            if entity.hasPrefix("#x") {
                replacement = UInt32(entity.dropFirst(2), radix: 16)
                    .flatMap(UnicodeScalar.init)
                    .map(String.init)
            } else if entity.hasPrefix("#") {
                replacement = UInt32(entity.dropFirst(), radix: 10)
                    .flatMap(UnicodeScalar.init)
                    .map(String.init)
            } else {
                replacement = [
                    "amp": "&", "quot": "\"", "apos": "'", "lt": "<",
                    "gt": ">", "nbsp": " "
                ][entity]
            }
            if let replacement,
               let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }
}

struct LinkPreviewImageProcessor: Sendable {
    static let maximumPixelCount: Int64 = 20_000_000
    static let maximumThumbnailPixelSize = 512

    func makeStaticThumbnail(from data: Data) throws -> Data {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              isAcceptedImageType(typeIdentifier),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  sourceOptions
              ) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              width > 0,
              height > 0,
              width <= Self.maximumPixelCount / height else {
            throw LinkPreviewImageError.invalidImage
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maximumThumbnailPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            throw LinkPreviewImageError.invalidImage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw LinkPreviewImageError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination),
              output.length <= LinkPreviewMetadataFetcher.maximumImageBytes else {
            throw LinkPreviewImageError.invalidImage
        }
        return output as Data
    }

    private func isAcceptedImageType(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .jpeg)
            || type.conforms(to: .png)
            || type.conforms(to: .gif)
            || type.conforms(to: .webP)
            || identifier == "com.microsoft.ico"
    }
}

enum LinkPreviewImageError: LocalizedError, Equatable {
    case invalidImage

    var errorDescription: String? {
        "The preview image was malformed, unsupported, or had unsafe dimensions."
    }
}
