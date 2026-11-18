import Foundation
import FoundationModels

/// Sorts a text-to-self into a category using Apple's on-device model,
/// falling back to simple keyword rules when Apple Intelligence isn't available.
enum TextClassifier {
    private static let instructions = """
        Classify a short note someone texted to themselves.
        todo = a task, errand, appointment, or place to go (for example "dry cleaners" or "call mom").
        idea = a business, app, product, or creative idea.
        shopping = specific things to buy.
        link = mostly a URL.
        note = anything else.
        """

    private static let todoPrefixes = ["call", "email", "text", "follow up", "look into", "remember", "need to",
                                       "todo", "to do", "schedule", "book", "pay", "send", "finish", "fix", "pick up"]
    private static let ideaWords = ["idea", "what if", "app that", "app for", "business", "startup", "could make"]
    private static let shoppingPrefixes = ["buy", "get more", "grocery", "groceries"]

    static func classify(_ text: String) async -> TextCategory {
        if let category = try? await classifyWithModel(text) { return category }
        return classifyWithRules(text)
    }

    private static func classifyWithModel(_ text: String) async throws -> TextCategory? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let choices = DynamicGenerationSchema(
            name: "Category", description: "The category of the note",
            anyOf: TextCategory.allCases.map(\.rawValue))
        let schema = try GenerationSchema(root: choices, dependencies: [])
        // A fresh session per text so earlier texts don't sway later answers.
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: text, schema: schema)
        return TextCategory(rawValue: try response.content.value(String.self))
    }

    static func classifyWithRules(_ text: String) -> TextCategory {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.hasPrefix("http") || lower.contains("://") { return .link }
        if ideaWords.contains(where: lower.contains) { return .idea }
        if shoppingPrefixes.contains(where: lower.hasPrefix) { return .shopping }
        if todoPrefixes.contains(where: lower.hasPrefix) { return .todo }
        return .note
    }
}
