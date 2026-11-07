import Foundation
import Observation

/// UI state for the Lab window that should survive view reloads.
@Observable
final class LabState {
    static let windowID = "lab"

    /// Currently selected peripheral in the sidebar (discovered or connected).
    var selectedID: UUID?
    var filterText = ""
    var onlyNamed = true
    var logFilter = ""
    var hideNoise = true
}
