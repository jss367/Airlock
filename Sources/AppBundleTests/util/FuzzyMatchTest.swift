@testable import AppBundle
import XCTest

final class FuzzyMatchTest: XCTestCase {
    // MARK: - Empty strings

    func testEmptyQueryMatchesEverything() {
        assertEquals(fuzzyMatch(query: "", target: "anything"), 0)
    }

    func testEmptyQueryMatchesEmptyTarget() {
        assertEquals(fuzzyMatch(query: "", target: ""), 0)
    }

    func testNonEmptyQueryDoesNotMatchEmptyTarget() {
        assertNil(fuzzyMatch(query: "a", target: ""))
    }

    // MARK: - No match

    func testNoMatchReturnsNil() {
        assertNil(fuzzyMatch(query: "xyz", target: "abc"))
    }

    func testPartialQueryNoFullMatch() {
        // Only first two chars found, third missing
        assertNil(fuzzyMatch(query: "abz", target: "abcdef"))
    }

    func testQueryLongerThanTarget() {
        assertNil(fuzzyMatch(query: "abcdef", target: "abc"))
    }

    // MARK: - Case insensitivity

    func testCaseInsensitive() {
        let score1 = fuzzyMatch(query: "abc", target: "ABC")
        let score2 = fuzzyMatch(query: "ABC", target: "abc")
        let score3 = fuzzyMatch(query: "aBc", target: "AbC")
        assertNotNil(score1)
        assertNotNil(score2)
        assertNotNil(score3)
        assertEquals(score1, score2)
        assertEquals(score2, score3)
    }

    // MARK: - Exact match

    func testExactMatch() {
        let score = fuzzyMatch(query: "abc", target: "abc")
        assertNotNil(score)
    }

    func testSingleCharExactMatch() {
        let score = fuzzyMatch(query: "a", target: "a")
        assertNotNil(score)
    }

    // MARK: - Prefix matches score higher than non-prefix

    func testPrefixMatchScoresHigherThanMiddleMatch() {
        let prefixScore = fuzzyMatch(query: "ab", target: "abcdef")!
        let middleScore = fuzzyMatch(query: "cd", target: "abcdef")!
        // Prefix gets start-of-string bonus (15) + word boundary bonus (10)
        // Middle match does not get start-of-string bonus
        assertTrue(prefixScore > middleScore)
    }

    // MARK: - Consecutive match bonus

    func testConsecutiveMatchesScoreHigherThanScattered() {
        let consecutive = fuzzyMatch(query: "abc", target: "abcxyz")!
        let scattered = fuzzyMatch(query: "abc", target: "axbxcx")!
        assertTrue(consecutive > scattered)
    }

    // MARK: - Word boundary bonus

    func testWordBoundaryWithSpace() {
        // "te" matching "some test" - 't' at word boundary
        let boundaryScore = fuzzyMatch(query: "t", target: "some test")!
        let midWordScore = fuzzyMatch(query: "o", target: "some test")!
        // 't' at word boundary gets +10; 'o' is mid-word
        assertTrue(boundaryScore > midWordScore)
    }

    func testWordBoundaryWithHyphen() {
        let score = fuzzyMatch(query: "b", target: "a-b")
        assertNotNil(score)
        // 'b' is after '-', so it gets word boundary bonus (10) + base (1) = 11
        assertEquals(score, 11)
    }

    func testWordBoundaryWithUnderscore() {
        let score = fuzzyMatch(query: "b", target: "a_b")
        assertNotNil(score)
        assertEquals(score, 11)
    }

    func testWordBoundaryWithDot() {
        let score = fuzzyMatch(query: "b", target: "a.b")
        assertNotNil(score)
        assertEquals(score, 11)
    }

    // MARK: - Start of string bonus

    func testStartOfStringBonus() {
        // First char gets: base(1) + word boundary(10) + start of string(15) = 26
        let score = fuzzyMatch(query: "a", target: "a")
        assertEquals(score, 26)
    }

    func testStartOfStringBonusMultiChar() {
        // 'a' at pos 0: base(1) + word boundary(10) + start(15) = 26
        // 'b' at pos 1: base(1) + consecutive(5) = 6
        let score = fuzzyMatch(query: "ab", target: "ab")
        assertEquals(score, 32)
    }

    // MARK: - Scoring order: exact > prefix > substring > fuzzy

    func testExactAndPrefixSameScore() {
        let exact = fuzzyMatch(query: "test", target: "test")!
        let prefix = fuzzyMatch(query: "test", target: "testing")!
        // Same char positions, so same score
        assertEquals(exact, prefix)
    }

    func testPrefixScoresHigherThanSubstring() {
        let prefix = fuzzyMatch(query: "test", target: "testing")!
        let substring = fuzzyMatch(query: "test", target: "a test")!
        // Prefix gets start-of-string bonus that substring doesn't
        assertTrue(prefix > substring)
    }

    func testConsecutiveSubstringVsScattered() {
        // Consecutive substring in middle vs scattered chars without boundary bonuses
        let consecutive = fuzzyMatch(query: "abc", target: "xabcx")!
        let scattered = fuzzyMatch(query: "abc", target: "xaxbxc")!
        assertTrue(consecutive > scattered)
    }

    // MARK: - Special characters

    func testSpecialCharactersInQuery() {
        let score = fuzzyMatch(query: "a.b", target: "a.b")
        assertNotNil(score)
    }

    func testMatchWithNumbers() {
        let score = fuzzyMatch(query: "v2", target: "version2")
        assertNotNil(score)
    }

    // MARK: - Character order matters

    func testCharacterOrderMustBePreserved() {
        assertNotNil(fuzzyMatch(query: "ab", target: "ab"))
        assertNil(fuzzyMatch(query: "ba", target: "ab"))
    }

    // MARK: - Repeated characters

    func testRepeatedCharacters() {
        let score = fuzzyMatch(query: "aa", target: "aardvark")
        assertNotNil(score)
    }

    func testRepeatedCharacterNotEnoughOccurrences() {
        assertNil(fuzzyMatch(query: "aaa", target: "ab"))
    }

    // MARK: - Unicode

    func testUnicodeCharacters() {
        let score = fuzzyMatch(query: "caf", target: "café")
        assertNotNil(score)
    }

    // MARK: - Long strings

    func testLongTarget() {
        let target = String(repeating: "x", count: 1000) + "abc"
        let score = fuzzyMatch(query: "abc", target: target)
        assertNotNil(score)
    }

    // MARK: - Single character

    func testSingleCharNotFound() {
        assertNil(fuzzyMatch(query: "z", target: "abcdef"))
    }

    func testSingleCharFoundMiddle() {
        // 'c' at index 2, not at word boundary, not at start
        let score = fuzzyMatch(query: "c", target: "abcdef")
        assertEquals(score, 1)
    }
}
