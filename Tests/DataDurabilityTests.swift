import Foundation

@main
struct DataDurabilityTests {
    static func main() {
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 2_000)
        let useful = ProgressRecord(position: 2_058, duration: 4_024, completed: false,
                                    lastOpened: old, completionSource: nil)
        let accidentalZero = ProgressRecord(position: 0, duration: 0, completed: false,
                                            lastOpened: recent, completionSource: nil)
        precondition(ProgressRecoveryPolicy.shouldRecover(useful, over: accidentalZero),
                     "A failed load must never replace useful continuity with zero")

        let newerUseful = ProgressRecord(position: 2_400, duration: 4_024, completed: false,
                                         lastOpened: recent, completionSource: nil)
        precondition(!ProgressRecoveryPolicy.shouldRecover(useful, over: newerUseful),
                     "The newest valid playback position must win")

        let reset = ProgressRecord(position: 0, duration: 0, completed: false,
                                   lastOpened: recent, completionSource: "reset")
        precondition(!ProgressRecoveryPolicy.shouldRecover(useful, over: reset),
                     "An intentional reset must remain reset")
        precondition(ProgressRecoveryPolicy.shouldRecover(useful, over: nil),
                     "Missing progress must be recovered")

        print("Data durability tests passed")
    }
}

