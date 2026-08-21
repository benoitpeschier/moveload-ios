#include "MoveLoadAutoApp.h"
#include "movesense.h"

MOVESENSE_APPLICATION_STACKSIZE(1024)

MOVESENSE_PROVIDERS_BEGIN(1)

MOVESENSE_PROVIDER_DEF(MoveLoadAutoApp)

MOVESENSE_PROVIDERS_END(1)

MOVESENSE_FEATURES_BEGIN()

OPTIONAL_CORE_MODULE(DataLogger, true)
OPTIONAL_CORE_MODULE(Logbook, true)
OPTIONAL_CORE_MODULE(LedService, true)
OPTIONAL_CORE_MODULE(IndicationService, true)
OPTIONAL_CORE_MODULE(BleService, true)
OPTIONAL_CORE_MODULE(EepromService, true)
OPTIONAL_CORE_MODULE(BypassService, false)
OPTIONAL_CORE_MODULE(SystemMemoryService, false)
OPTIONAL_CORE_MODULE(DebugService, false)

// Standard heart rate profile, so Garmin/Suunto/Coros watches can pair with
// the sensor as an ordinary HR strap and carry the cardio into whichever
// training platform the athlete already uses. Set this to false to drop the
// watch half of the firmware without touching anything else — the recording
// logic does not depend on it.
OPTIONAL_CORE_MODULE(BleStandardHRS, true)
OPTIONAL_CORE_MODULE(BleNordicUART, false)
OPTIONAL_CORE_MODULE(CustomGattService, false)

DEBUGSERVICE_BUFFER_SIZE(6, 120);
DEBUG_EEPROM_MEMORY_AREA(false, 0, 0)
LOGBOOK_EEPROM_MEMORY_AREA(0, MEMORY_SIZE_FILL_REST);

// Two simultaneous peripheral connections: the watch on the HR profile and
// MoveLoad on the Movesense protocol, at the same time. Before core library
// 2.3.1 the two could not coexist ("GSP doesn't work with dual BLE" in
// CHANGES.md) — this firmware requires 2.3.1 or later.
MOVESENSE_BLE_CONFIG_2PERIPHERALS;

APPINFO_NAME("MoveLoad Auto");
APPINFO_VERSION("1.0.0");
APPINFO_COMPANY("Accel");

MOVESENSE_FEATURES_END()
