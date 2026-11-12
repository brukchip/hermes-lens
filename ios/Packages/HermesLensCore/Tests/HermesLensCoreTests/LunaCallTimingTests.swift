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

@Test func micLevelIsLoggedEveryThirtySecondsOrWhenSpeechStartsOrStops() {
    // Samples every 5 s: quiet for a minute, then speech, then quiet again.
    let peaks = Array(repeating: 0.01, count: 12) + [0.3, 0.4] + Array(repeating: 0.0, count: 3)
    var logged: [Int] = []
    var last = -Double.infinity
    var wasSpeech: Bool?
    for (index, peak) in peaks.enumerated() {
        let now = Double(index + 1) * LunaLevelTrace.sampleSeconds
        let speech = LunaLevelTrace.isSpeech(peak)
        if LunaLevelTrace.logs(speech: speech, wasSpeech: wasSpeech, secondsSinceLogged: now - last) {
            logged.append(Int(now)); last = now
        }
        wasSpeech = speech
    }
    // First sample, then every 30 s, then at once when speech starts and when it stops.
    #expect(logged == [5, 35, 65, 75])
}
