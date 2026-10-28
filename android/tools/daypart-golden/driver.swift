// Part of android/tools/daypart-golden.sh. Compiled with
// iOS/Page/Models/MotionCurves.swift and iOS/Page/Models/Daypart.swift (the
// source of truth), it prints the time-of-day golden: a '# ' header, then one
// tab-separated row per sampled minute of the local day:
//   hhmm, the four weights (earlyMorning, morning, afternoon, nighttime),
//   working c1 c2 c3 skyTop skyBottom, quiet skyTop, needsYou skyTop skyBottom
//   (#RRGGBB), working intensity and speed, quiet intensity and speed, stars.
// Numbers are %.4f. Rows: every 5 minutes, each window edge and edge ±1
// minute, 23:59 and 01:12 (the harness's clock): 306 in all.
import Foundation

var minutes = Set(stride(from: 0, to: 1440, by: 5))
for w in DaypartWeights.windows {
    for e in [Int(w.start), Int(w.end)] { for d in -1...1 { minutes.insert((e + d + 1440) % 1440) } }
}
minutes.insert(1439)
minutes.insert(72)

let header = ["hhmm", "earlyMorning", "morning", "afternoon", "nighttime",
              "working.c1", "working.c2", "working.c3", "working.skyTop", "working.skyBottom",
              "quiet.skyTop", "needsYou.skyTop", "needsYou.skyBottom",
              "working.intensity", "working.speed", "quiet.intensity", "quiet.speed", "stars"]
var out = "# " + header.joined(separator: "\t") + "\n"
func num(_ x: Double) -> String { String(format: "%.4f", x) }
for m in minutes.sorted() {
    let w = DaypartWeights.at(minuteOfDay: Double(m))
    let tone = DaypartTone.blended(w)
    let working = tone.working, quiet = tone.quiet, needs = tone.needsYou
    var row = [String(format: "%02d:%02d", m / 60, m % 60)]
    row += Daypart.allCases.map { num(w.weight($0)) }
    row += [working.c1, working.c2, working.c3, working.skyTop, working.skyBottom, quiet.skyTop, needs.skyTop, needs.skyBottom].map(\.hexString)
    row += [working.intensity, working.speed, quiet.intensity, quiet.speed, w.stars].map(num)
    out += row.joined(separator: "\t") + "\n"
}
FileHandle.standardOutput.write(Data(out.utf8))
