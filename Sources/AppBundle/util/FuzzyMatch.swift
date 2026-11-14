import Foundation

/// Text prepared for fuzzy matching: case and diacritics folded, with the start of each word marked.
/// Build it once per item, not once per keystroke
struct FuzzyTarget: Sendable {
    fileprivate let chars: [Character]
    fileprivate let startsWord: [Bool]

    init(_ text: String) {
        var chars: [Character] = []
        var startsWord: [Bool] = []
        chars.reserveCapacity(text.count)
        startsWord.reserveCapacity(text.count)
        var prev: Character? = nil
        for char in text {
            let isBoundary: Bool = switch prev {
                case nil: true
                case let prev?:
                    // "foo bar", "foo-bar", "fooBar", "foo2"
                    !(prev.isLetter || prev.isNumber)
                        || (prev.isLowercase && char.isUppercase)
                        || (char.isNumber && !prev.isNumber)
            }
            if let ascii = char.asciiValue {
                // Most text is ASCII, and folding through Foundation is slow
                let isUppercase = ascii >= 65 && ascii <= 90
                chars.append(isUppercase ? Character(UnicodeScalar(ascii + 32)) : char)
                startsWord.append(isBoundary)
            } else {
                // Folding can turn one character into several. Only the first one starts the word
                for (offset, folded) in fuzzyFold(String(char)).enumerated() {
                    chars.append(folded)
                    startsWord.append(isBoundary && offset == 0)
                }
            }
            prev = char
        }
        self.chars = chars
        self.startsWord = startsWord
    }
}

private func fuzzyFold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
}

/// The query's whitespace-separated words, folded the same way as `FuzzyTarget`
func fuzzyQueryTokens(_ query: String) -> [[Character]] {
    fuzzyFold(query).split(whereSeparator: \.isWhitespace).map(Array.init)
}

/// Returns a score for how well `query` fuzzy-matches `target`.
/// Returns nil if there is no match: not all query characters found in order, or found too
/// scattered to mean anything. Higher score = better match.
func fuzzyMatch(query: String, target: String) -> Int? {
    fuzzyMatch(query: Array(fuzzyFold(query)), target: FuzzyTarget(target))
}

/// `query` must already be folded, see `fuzzyQueryTokens`.
///
/// Every matched character scores 1, plus 5 when it directly follows the previous match, plus 10
/// at the start of a word, plus 15 at the start of the string. A match may jump ahead to the
/// start of any later word, which is what makes acronyms work. Inside a word it may skip letters
/// at a cost of 1 each ("sfr" finds "Safari"), but it can't land in the middle of another word,
/// so letters scattered across a long window title don't match at all.
/// Of all the ways to place the query in the target, the best-scoring one counts
func fuzzyMatch(query: [Character], target: FuzzyTarget) -> Int? {
    guard !query.isEmpty else { return 0 }
    let chars = target.chars
    guard query.count <= chars.count else { return nil }

    let none = Int.min / 2 // No way to match the query up to here. Halved so penalties can't overflow
    // prev[i]: best score with the previous query character matched at chars[i]
    var prev = [Int](repeating: none, count: chars.count)
    var current = prev
    for (queryIdx, queryChar) in query.enumerated() {
        // Best of prev[k] over k <= i - 2, for a jump to the start of a word
        var bestBeforeGap = none
        // Best of prev[k] + k over the k <= i - 2 in the same word as i, for a skip inside the word
        var bestInWordPlusIdx = none
        for i in chars.indices {
            if i >= 2, prev[i - 2] > none { bestBeforeGap = max(bestBeforeGap, prev[i - 2]) }
            if target.startsWord[i] {
                bestInWordPlusIdx = none
            } else if i >= 2, !target.startsWord[i - 1], prev[i - 2] > none {
                bestInWordPlusIdx = max(bestInWordPlusIdx, prev[i - 2] + i - 2)
            }
            current[i] = none
            guard chars[i] == queryChar else { continue }
            let position = 1 + (target.startsWord[i] ? 10 : 0) + (i == 0 ? 15 : 0)
            if queryIdx == 0 {
                current[i] = position
                continue
            }
            var best = none
            if i >= 1, prev[i - 1] > none { best = prev[i - 1] + 5 }
            if target.startsWord[i] {
                best = max(best, bestBeforeGap)
            } else if bestInWordPlusIdx > none {
                // prev[k] - (i - k - 1) skipped characters == (prev[k] + k) - i + 1
                best = max(best, bestInWordPlusIdx - i + 1)
            }
            if best > none { current[i] = best + position }
        }
        swap(&prev, &current)
    }
    // Zero or less: the skipped letters outweigh what matched
    guard let score = prev.max(), score > 0 else { return nil }
    return score
}
