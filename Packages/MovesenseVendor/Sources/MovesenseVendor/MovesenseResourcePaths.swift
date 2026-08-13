import Foundation

/// Whiteboard resource path constants used by `MovesenseSensorService`.
///
/// There used to be `Mem/DataLogger/Config`/`State` PUT paths here for
/// remotely starting/stopping on-device recording, but `doPut` against
/// `Mem/DataLogger` consistently fails (HTTP 400, empty body) on this
/// vendored MDS SDK build regardless of path/payload format tried — see
/// `MovesenseSensorService.startLogging`. Recording is started/stopped by
/// double/triple-tapping the sensor itself instead (untested as of
/// 2026-08-11 whether the stock firmware wires tap detection — confirmed
/// present as `/System/States/DoubleTap` per `system/states.yaml` — to
/// `Mem/DataLogger` state changes; only the *download* side (GET, below)
/// is unaffected by the PUT issue and stays wired up.)
enum MovesenseResourcePaths {
    static func logbookByIdData(_ id: String) -> String { "Mem/Logbook/byId/\(id)" }

    /// MDS-level convenience resources — per `Movesense/readme.txt`, these
    /// return the logbook already converted to JSON (MDS decodes the raw
    /// SBEM format for us), unlike the device's own `Mem/Logbook/*` paths.
    static func mdsLogbookEntries(serial: String) -> String { "MDS/Logbook/\(serial)/Entries" }
    static func mdsLogbookData(serial: String, id: String) -> String { "MDS/Logbook/\(serial)/ById/\(id)/Data" }
}
