import Foundation
import Testing
@testable import HermesLensCore

@Test func theWorkingToneBacksOffAndStopsAfterAMinute() {
    #expect(LunaWorkingTone.times == [1.5, 11.5, 21.5, 31.5, 41.5, 51.5])
    // The session reads the quiet time every half second.
    var played: [TimeInterval] = []
    var previous = 0.0
    for tick in 1...240 {
        let quiet = Double(tick) * 0.5
        if LunaWorkingTone.plays(from: previous, to: quiet) { played.append(quiet) }
        previous = quiet
    }
    #expect(played == [1.5, 11.5, 21.5, 31.5, 41.5, 51.5])
    #expect(!LunaWorkingTone.plays(from: 0, to: 1))
    #expect(!LunaWorkingTone.plays(from: 52, to: 600))
}

@Test func lunaWarnsOnceBeforeTheCallLimitWhenThereIsTimeToSaySo() {
    #expect(LunaCallEnding.warningDelay(remaining: 538) == 523)
    #expect(LunaCallEnding.warningDelay(remaining: 25) == 10)
    #expect(LunaCallEnding.warningDelay(remaining: 24) == nil)
    #expect(LunaCallEnding.warningDelay(remaining: 5) == nil)
    #expect(LunaCallEnding.note.contains("new call"))
}
