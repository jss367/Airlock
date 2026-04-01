/// Returns a score for how well `query` fuzzy-matches `target`.
/// Returns nil if there is no match (not all query characters found in order).
/// Higher score = better match.
func fuzzyMatch(query: String, target: String) -> Int? {
    let queryChars = Array(query.lowercased())
    let targetChars = Array(target.lowercased())

    guard !queryChars.isEmpty else { return 0 }

    var score = 0
    var queryIdx = 0
    var prevMatchIdx = -2 // tracks consecutive matches
    var prevCharWasSeparator = true // start of string counts as word boundary

    for (targetIdx, char) in targetChars.enumerated() {
        if queryIdx < queryChars.count && char == queryChars[queryIdx] {
            score += 1

            // Bonus for consecutive matches
            if targetIdx == prevMatchIdx + 1 {
                score += 5
            }

            // Bonus for matching at word boundary
            if prevCharWasSeparator {
                score += 10
            }

            // Bonus for matching at start of string
            if targetIdx == 0 {
                score += 15
            }

            prevMatchIdx = targetIdx
            queryIdx += 1
        }

        prevCharWasSeparator = char == " " || char == "-" || char == "_" || char == "."
    }

    // All query characters must be found
    return queryIdx == queryChars.count ? score : nil
}
