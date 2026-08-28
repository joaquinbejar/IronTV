import Foundation

/// One `#EXTINF` entry: the channel line plus the URL on the line after it.
public struct M3UEntry: Equatable, Sendable {
    public let name: String
    public let url: URL
    public let logoURL: URL?
    /// `tvg-id`. The same value `LiveStream.epgChannelID` carries from the
    /// Xtream API, so an M3U account loses nothing here.
    public let tvgID: String?
    /// `group-title`. Absent for entries a provider left ungrouped.
    public let group: String?

    public init(name: String, url: URL, logoURL: URL? = nil, tvgID: String? = nil, group: String? = nil) {
        self.name = name
        self.url = url
        self.logoURL = logoURL
        self.tvgID = tvgID
        self.group = group
    }
}

public enum M3UPlaylistError: Error, Equatable, LocalizedError {
    /// No `#EXTM3U` header, and no usable entry either — this is not a playlist.
    case notAPlaylist
    /// A playlist that parsed but contained nothing playable.
    case empty
    /// The response ended mid-entry: a channel line with no URL after it.
    case truncated

    public var errorDescription: String? {
        switch self {
        case .notAPlaylist:
            return String(localized: "That address did not return a playlist.")
        case .empty:
            return String(localized: "The playlist downloaded but contains no channels.")
        case .truncated:
            return String(localized: "The playlist download ended early — only part of the channel list arrived.")
        }
    }
}

/// Extended-M3U parser.
///
/// Line-driven and incremental on purpose: provider playlists reach tens of
/// megabytes and 100k+ entries, and tvOS has the least memory of the three
/// targets. Feed it lines as they arrive (``consume(line:)``) rather than
/// handing it a whole file as one `String`.
///
/// Forgiving in the same way the DTOs are forgiving about inconsistent panels:
/// an entry with no attributes, an unknown attribute, a missing `group-title`
/// or a stray blank line never discards the rest of the playlist.
public struct M3UPlaylistParser {
    public private(set) var entries: [M3UEntry] = []
    /// Entries whose URL line was unusable. Surfaced so a playlist that is
    /// mostly broken is not silently presented as a short but healthy one.
    public private(set) var skippedEntryCount = 0
    private var sawHeader = false
    private var pending: PendingEntry?

    private struct PendingEntry {
        let name: String
        let logoURL: URL?
        let tvgID: String?
        let group: String?
    }

    public init() {}

    public mutating func consume(line rawLine: String) {
        // CRLF playlists are common; trimming here rather than at the reader
        // keeps the caller free to split on \n alone.
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        if line.hasPrefix("#EXTM3U") {
            sawHeader = true
            return
        }
        if line.hasPrefix("#EXTINF") {
            pending = Self.parseEXTINF(line)
            return
        }
        // Any other directive (#EXTGRP, #EXTVLCOPT, comments) is skipped
        // without dropping the entry it belongs to.
        if line.hasPrefix("#") { return }

        guard let pending else { return }
        self.pending = nil
        guard let url = URL(string: line), url.scheme != nil else {
            skippedEntryCount += 1
            return
        }
        entries.append(
            M3UEntry(name: pending.name, url: url, logoURL: pending.logoURL, tvgID: pending.tvgID, group: pending.group)
        )
    }

    /// Call once the stream ends. Throws rather than returning a short list:
    /// a truncated download must not look like a provider with few channels.
    public func finish() throws -> [M3UEntry] {
        guard sawHeader || !entries.isEmpty else { throw M3UPlaylistError.notAPlaylist }
        // A trailing #EXTINF whose URL line never arrived means the response
        // was cut short. Checked even when earlier entries parsed: otherwise a
        // download that died a third of the way through is served as a
        // complete, and much smaller, catalog.
        guard pending == nil else { throw M3UPlaylistError.truncated }
        guard !entries.isEmpty else { throw M3UPlaylistError.empty }
        return entries
    }

    /// Convenience for fixtures and small inputs. The streaming path is the
    /// one production uses.
    public static func parse(_ text: String) throws -> [M3UEntry] {
        var parser = M3UPlaylistParser()
        text.enumerateLines { line, _ in parser.consume(line: line) }
        return try parser.finish()
    }

    // MARK: - #EXTINF

    /// `#EXTINF:-1 tvg-id="x" tvg-logo="http://…" group-title="News",Channel Name`
    ///
    /// The display name is everything after the FIRST comma that is outside a
    /// quoted attribute value. Attributes come first and the name runs to the
    /// end of the line, so a name containing commas — "France 24, Live" — keeps
    /// them; splitting on the last comma would eat the name instead.
    private static func parseEXTINF(_ line: String) -> PendingEntry {
        let afterColon: Substring
        if let colon = line.firstIndex(of: ":") {
            afterColon = line[line.index(after: colon)...]
        } else {
            afterColon = Substring(line)
        }

        var inQuotes = false
        var firstCommaOutsideQuotes: String.Index?
        var index = afterColon.startIndex
        while index < afterColon.endIndex {
            let character = afterColon[index]
            if character == "\"" {
                inQuotes.toggle()
            } else if character == "," && !inQuotes {
                firstCommaOutsideQuotes = index
                break
            }
            index = afterColon.index(after: index)
        }

        let attributeText: Substring
        let name: String
        if let comma = firstCommaOutsideQuotes {
            attributeText = afterColon[afterColon.startIndex..<comma]
            name = String(afterColon[afterColon.index(after: comma)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            attributeText = afterColon
            name = ""
        }

        let attributes = parseAttributes(attributeText)
        let logo = attributes["tvg-logo"].flatMap(URL.init(string:))
        return PendingEntry(
            // An entry with no name still plays; falling back to tvg-name and
            // then to a placeholder beats dropping the channel.
            name: name.isEmpty ? (attributes["tvg-name"] ?? String(localized: "Unnamed channel")) : name,
            logoURL: logo,
            tvgID: attributes["tvg-id"].flatMap { $0.isEmpty ? nil : $0 },
            group: attributes["group-title"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// `key="value"` pairs in any order. Unknown keys are kept and ignored by
    /// the caller rather than making the line unparseable.
    private static func parseAttributes(_ text: Substring) -> [String: String] {
        var attributes: [String: String] = [:]
        var index = text.startIndex
        while index < text.endIndex {
            guard let equals = text[index...].firstIndex(of: "=") else { break }
            // The key is the token immediately before `=`, not everything
            // since the last attribute: the duration that opens every #EXTINF
            // ("-1 ") sits in front of the first one and would be glued on.
            let beforeEquals = text[index..<equals]
            let keyStart = beforeEquals.lastIndex(where: { $0 == " " || $0 == "\t" })
                .map { beforeEquals.index(after: $0) } ?? beforeEquals.startIndex
            let key = String(beforeEquals[keyStart...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            var valueStart = text.index(after: equals)
            guard valueStart < text.endIndex else { break }

            if text[valueStart] == "\"" {
                valueStart = text.index(after: valueStart)
                guard let closing = text[valueStart...].firstIndex(of: "\"") else { break }
                attributes[key] = String(text[valueStart..<closing])
                index = text.index(after: closing)
            } else {
                let end = text[valueStart...].firstIndex(of: " ") ?? text.endIndex
                attributes[key] = String(text[valueStart..<end])
                index = end
            }
            while index < text.endIndex, text[index] == " " {
                index = text.index(after: index)
            }
        }
        return attributes
    }
}
