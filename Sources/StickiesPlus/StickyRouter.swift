import Foundation
import FoundationModels

/// A titled sticky a text could be filed onto.
struct RouteCandidate {
    let noteID: Int64
    let title: String
    /// A few recent lines, so the model learns what the sticky is for.
    let recentLines: [String]
}

/// Decides which titled sticky a text belongs on. nil means the 📥 Inbox.
enum StickyRouter {
    private static let inboxChoice = "Inbox"
    private static let maxPrefixLength = 30
    // Tuned against real self-texts: a stricter "prefer Inbox" wording sent obvious matches to the inbox.
    private static let instructions = """
        You sort short notes a person texted to themselves onto their sticky notes.
        Each sticky has a title and example lines that show what belongs on it.
        Choose the sticky where this note would naturally be written. For example: things to buy go on a \
        groceries or shopping sticky; anything the person needs to do (send, call, email, follow up, an errand \
        or a place to go) goes on a to-do or this-week sticky; ideas and things to research go on an ideas sticky.
        Choose Inbox only when the note doesn't belong on any sticky.
        """

    struct Route {
        /// nil = inbox
        let noteID: Int64?
        /// The text to write on the sticky (prefix removed when one was used).
        let text: String
    }

    static func route(_ text: String, candidates: [RouteCandidate], inbox: RouteCandidate?) async -> Route {
        if let match = prefixMatch(text, candidates: candidates + [inbox].compactMap { $0 }) {
            return match
        }
        guard !candidates.isEmpty, let index = try? await chooseWithModel(text, candidates: candidates) else {
            return Route(noteID: nil, text: text)
        }
        return Route(noteID: candidates[index].noteID, text: text)
    }

    // MARK: Prefix shortcut: "groceries: eggs", "groc: eggs", "#groceries eggs"

    static func prefixMatch(_ text: String, candidates: [RouteCandidate]) -> Route? {
        guard let (key, rest) = splitPrefix(text), !rest.isEmpty else { return nil }
        let normalizedKey = normalize(key)
        guard !normalizedKey.isEmpty else { return nil }
        let titled = candidates.map { ($0, normalize($0.title)) }
        if let exact = titled.first(where: { $0.1 == normalizedKey }) {
            return Route(noteID: exact.0.noteID, text: rest)
        }
        let prefixed = titled.filter { $0.1.hasPrefix(normalizedKey) }
        guard prefixed.count == 1 else { return nil }  // ambiguous or no match: let the model decide
        return Route(noteID: prefixed[0].0.noteID, text: rest)
    }

    private static func splitPrefix(_ text: String) -> (String, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            let body = trimmed.dropFirst()
            guard let space = body.firstIndex(where: \.isWhitespace) else { return nil }
            return (String(body[..<space]), body[space...].trimmingCharacters(in: .whitespaces))
        }
        guard let colon = trimmed.firstIndex(of: ":"),
              trimmed.distance(from: trimmed.startIndex, to: colon) <= maxPrefixLength else { return nil }
        let rest = trimmed[trimmed.index(after: colon)...]
        if rest.hasPrefix("//") { return nil }  // a URL like https://…
        return (String(trimmed[..<colon]), rest.trimmingCharacters(in: .whitespaces))
    }

    /// "🛒 Groceries" → "groceries": letters and digits only, lowercased.
    static func normalize(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init))
    }

    // MARK: On-device model

    /// Returns the index of the chosen candidate, or nil for Inbox / model unavailable.
    private static func chooseWithModel(_ text: String, candidates: [RouteCandidate]) async throws -> Int? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let labels = uniqueLabels(candidates.map(\.title))
        let schema = try GenerationSchema(
            root: DynamicGenerationSchema(name: "Sticky", description: "The sticky to put the note on",
                                          anyOf: labels + [inboxChoice]),
            dependencies: [])
        let stickies = zip(labels, candidates).map { label, candidate in
            let examples = candidate.recentLines.isEmpty ? "none yet" : candidate.recentLines.joined(separator: "; ")
            return "- \(label) (examples: \(examples))"
        }.joined(separator: "\n")
        let prompt = "Stickies:\n\(stickies)\n- \(inboxChoice) (only if nothing above fits)\n\nNote: \"\(text)\"\nWhich sticky?"

        let session = LanguageModelSession(instructions: instructions)
        // Greedy sampling: the same text and stickies always give the same answer.
        let response = try await session.respond(to: prompt, schema: schema, options: GenerationOptions(sampling: .greedy))
        let choice = try response.content.value(String.self)
        return labels.firstIndex(of: choice)
    }

    /// Choices must be distinct, so repeat titles (or one named "Inbox") get a number.
    private static func uniqueLabels(_ titles: [String]) -> [String] {
        var seen: Set<String> = [inboxChoice]
        return titles.map { title in
            var label = title
            var n = 2
            while seen.contains(label) { label = "\(title) (\(n))"; n += 1 }
            seen.insert(label)
            return label
        }
    }
}
