#include "MoveLoadAutoApp.h"
#include "GATTSensorDataClient.h"
#include "MoveLoadFirmwareInfo.h"
#include "movesense.h"

MOVESENSE_APPLICATION_STACKSIZE(1024)

MOVESENSE_PROVIDERS_BEGIN(2)

MOVESENSE_PROVIDER_DEF(MoveLoadAutoApp)
// GSP — the protocol MoveLoad speaks to the sensor — is **not** a core module.
// It is application code, shipped as the gatt_sensordata_app sample, and the
// stock firmware includes it. Leaving it out produced a sensor the app could
// find, connect to, and then fail on with "service GSP introuvable": no way to
// list the logbook, download a session, or even switch back into DFU mode,
// since that switch is itself a GSP write. Recovery then needs the hardware
// route (FAQ.md, "How to use DFU recovery mode?": short the AFE pins while
// inserting the battery).
MOVESENSE_PROVIDER_DEF(GATTSensorDataClient)

MOVESENSE_PROVIDERS_END(2)

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
// Required by GATTSensorDataClient: GSP is a custom GATT service.
OPTIONAL_CORE_MODULE(CustomGattService, true)

DEBUGSERVICE_BUFFER_SIZE(6, 120);
DEBUG_EEPROM_MEMORY_AREA(false, 0, 0)
LOGBOOK_EEPROM_MEMORY_AREA(0, MEMORY_SIZE_FILL_REST);

// No BLE config macro on purpose: the core's own default is what the stock
// firmware and the GSP sample are validated against, and it is the only one
// here with a usable MTU.
//
// The two alternatives were both tried on hardware and both failed:
//
//   MOVESENSE_BLE_CONFIG_2PERIPHERALS = BleConfig(27,2,0,2,10,23,1896,6).
//   Its MTU of 23 leaves 20 bytes per notification, which does not slow GSP
//   down, it truncates it — HELLO came back with the serial and nothing after.
//
//   BleConfig(96,2,0,2,20,92,1896,6), two links at the larger size. It builds,
//   then the sensor never advertises at all: the softdevice needs RAM in
//   proportion to links x MTU x data length, the application's RAM origin is
//   fixed in the build flags, and sd_ble_enable fails at runtime with nothing
//   to see. Recovery is the AFE-pin route, since there is no BLE to reach.
//
// So the watch and the phone connect at different moments rather than at once:
// the watch during the session, the phone after it. That is how the sensor is
// actually used, and a link that truncates or never comes up is worse than a
// link taken in turns.

APPINFO_NAME(MOVELOAD_APP_NAME);
APPINFO_VERSION(MOVELOAD_APP_VERSION);
APPINFO_COMPANY("Accel");

MOVESENSE_FEATURES_END()
