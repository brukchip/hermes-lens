import Foundation
import Testing
@testable import HermesLensCore

@Test func theWorkingToneBacksOffAndStopsAMinuteAfterTheRequestStarted() {
    #expect(LunaWorkingTone.times == [1.5, 11.5, 21.5, 31.5, 41.5, 51.5])
    // Read every half second; quiet the whole time.
    func run(talkingBetween talk: ClosedRange<Double>? = nil) -> [Double] {
        var played: [Double] = []
        var last: Int?
        var quiet = 0.0
        for tick in 1...240 {
            let working = Double(tick) * 0.5
            quiet = talk?.contains(working) == true ? 0 : quiet + 0.5
            if let slot = LunaWorkingTone.due(workingFor: working, quietFor: quiet, lastPlayed: last) {
                played.append(working); last = slot
            }
        }
        return played
    }
    #expect(run() == [1.5, 11.5, 21.5, 31.5, 41.5, 51.5])
    // Talk from 10 s to 25 s: the missed 11.5 and 21.5 slots give one tone once it has been
    // quiet for 1.5 s; the minute still counts from the start of the request.
    #expect(run(talkingBetween: 10...25) == [1.5, 26.5, 31.5, 41.5, 51.5])
    #expect(LunaWorkingTone.due(workingFor: 61, quietFor: 30, lastPlayed: nil) == nil)
    #expect(LunaWorkingTone.due(workingFor: 1, quietFor: 30, lastPlayed: nil) == nil)
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
