#pragma once

// One definition of the firmware's identity, because two places need it and a
// drift between them fails silently:
//
//   - APPINFO_NAME in App.cpp, which is what the Movesense tooling reports.
//   - the HELLO response in GATTSensorDataClient, which is what MoveLoad reads
//     and compares against `MovesenseSensorService.autoFirmwareName` before
//     skipping the reboot on stopLogging(). A mismatch there restores the
//     reboot and quietly undoes every stop.
//
// /Info/App would have been the tidy source, but this device does not answer
// that resource — /Info does, which is why the serial arrives and the app name
// did not.
#define MOVELOAD_APP_NAME "MoveLoad Auto"
// Bump this on every image that goes onto a sensor. Two builds that differ in
// behaviour but report the same version cannot be told apart once flashed, and
// "which firmware is actually on it?" then has no answer short of reflashing.
//   1.0.0  first working GSP build
//   1.1.0  SUBSCRIBE answers; the link release spares an active GSP client
//   1.2.0  LED vocabulary: 1 blink strap noticed, 3 recording started,
//          5 recording stopped — the only way to observe the automatic stop
//   1.3.0  a pulse counts only if the R-R intervals move: a damp strap keeps
//          the heart rate service emitting a plausible average, which defeated
//          both the arming gate and the stop watchdog
//   1.4.0  the intervals must move *like a heart*: 1.3.0 only asked that they
//          move, and the damp strap's noise varies rather than freezing
//   1.5.0  the no-pulse stop falls from three minutes to one
//   1.6.0  UNSUBSCRIBE answers; no auto-start while a phone is on GSP, which
//          was restarting a recording in the middle of the HRV test
//   1.7.0  the same guard where it counts — at the moment logging starts, not
//          only when arming begins: the strap goes on before the app opens
//   1.8.0  2 blinks when arming gives up without finding a pulse. A session
//          that failed to start on someone else's chest left nothing at all
//          to look at: the steady light said the strap was noticed, and
//          silence afterwards meant either "still listening" or "gave up
//          twelve minutes ago", which are not the same problem
//   1.9.0  the external-stop inhibition is time-bounded. It was cleared only
//          by a loss of contact, which a damp strap suppresses indefinitely,
//          so the morning HRV test — which stops the recording the sensor had
//          started on its own — inhibited every recording for the rest of the
//          day, silently and with no LED
//   1.10.0 the GSP client flag is cleared when the BLE link drops. It was
//          only ever cleared by a CCCD write, which a dropped link does not
//          send — so the sensor went on believing a phone was using it and
//          refused to arm for good
//   1.11.0 the heart rate measurement is not taken away from a connected
//          phone, and arming stops declaring "no pulse" at an athlete who has
//          one. Arming cannot complete while a GSP client is connected, so on
//          a morning where the strap goes on before the app is opened, the
//          five-minute arming timeout lands in the middle of the HRV test: it
//          blinked the two-blink no-pulse code — the signal the auto-start is
//          read by — and unsubscribed /Meas/HR, the measurement the test is
//          made of, with the retry three minutes later blocked by that same
//          connected phone. On 2026-09-05 the test kept two minutes of the
//          lying position and nothing at all standing
#define MOVELOAD_APP_VERSION "1.11.0"
