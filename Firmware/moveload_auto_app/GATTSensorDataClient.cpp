#include "movesense.h"

#include "GATTSensorDataClient.h"
#include "MoveLoadFirmwareInfo.h"
#include "common/core/debug.h"
#include "oswrapper/thread.h"

#include "comm_ble_gattsvc/resources.h"
#include "comm_ble/resources.h"
#include "mem_logbook/resources.h"
#include "meas_temp/resources.h"

// Each resource module has to be included explicitly to reach WB_RES::LOCAL —
// these are the ones the commands added below drive.
#include "movesense_info/resources.h"
#include "movesense_time/resources.h"
#include "system_mode/resources.h"
#include "mem_datalogger/resources.h"
#include "system_energy/resources.h"

// Functions for serializing binary data
#include "meas_acc/resources.h"
#include "meas_gyro/resources.h"
#include "meas_magn/resources.h"
#include "meas_imu/resources.h"
#include "meas_ecg/resources.h"
#include "meas_hr/resources.h"
#include "movesense_time/resources.h"
#include "sbem-code/sbem_definitions.h"

enum Commands 
{
    HELLO = 0,
    SUBSCRIBE = 1,
    UNSUBSCRIBE = 2,
    FETCH_LOG = 3,
    GET = 4,
    CLEAR_LOGBOOK = 5,
    PUT_DATALOGGER_CONFIG = 6,
    PUT_SYSTEM_MODE = 7,
    PUT_UTC_TIME = 8,
    PUT_DATALOGGER_STATE = 9,
};
enum Responses 
{
    COMMAND_RESULT = 1,
    DATA = 2,
    DATA_PART2 = 3, // In case the subscription data is larger than fits in the single BLE packet, continue with Part2 & 3
    DATA_PART3 = 4,
};

namespace {
/// Copies a whiteboard string into a fixed buffer, always null-terminated.
void copyInto(char* pDest, size_t capacity, const char* pSource)
{
    if (pSource == nullptr) { pDest[0] = 0; return; }
    size_t i = 0;
    while (i + 1 < capacity && pSource[i] != 0) { pDest[i] = pSource[i]; i++; }
    pDest[i] = 0;
}
}

const char* const GATTSensorDataClient::LAUNCHABLE_NAME = "GattData";

namespace {
/// The one instance's notification state, kept aside so MoveLoadAutoApp can
/// ask without a handle on the object — the module system builds both and
/// hands out neither.
bool g_gspClientActive = false;
}

bool GATTSensorDataClient::hasActiveClient()
{
    return g_gspClientActive;
}
// UUID: 34802252-7185-4d5d-b431-630e7050e8f0
constexpr uint8_t SENSOR_DATASERVICE_UUID[] = { 0xf0, 0xe8, 0x50, 0x70, 0x0e, 0x63, 0x31, 0xb4, 0x5d, 0x4d, 0x85, 0x71, 0x52, 0x22, 0x80, 0x34 };
constexpr uint8_t COMMAND_CHAR_UUID[] = { 0xf0, 0xe8, 0x50, 0x70, 0x0e, 0x63, 0x31, 0xb4, 0x5d, 0x4d, 0x85, 0x71, 0x01, 0x00, 0x80, 0x34 };
constexpr uint16_t commandCharUUID16 = 0x0001;
constexpr uint8_t DATA_CHAR_UUID[] = { 0xf0, 0xe8, 0x50, 0x70, 0x0e, 0x63, 0x31, 0xb4, 0x5d, 0x4d, 0x85, 0x71, 0x02, 0x00, 0x80, 0x34 };
constexpr uint16_t dataCharUUID16 = 0x0002;

GATTSensorDataClient::GATTSensorDataClient():
    ResourceClient(WBDEBUG_NAME(__FUNCTION__), WB_EXEC_CTX_APPLICATION),
    LaunchableModule(LAUNCHABLE_NAME, WB_EXEC_CTX_APPLICATION),
    mCommandCharResource(wb::ID_INVALID_RESOURCE),
    mDataCharResource(wb::ID_INVALID_RESOURCE),
    mNotificationsEnabled(false),
    mSensorSvcHandle(0),
    mCommandCharHandle(0),
    mLogIdToFetch(0),
    mLogFetchOffset(0),
    mLogFetchReference(0),
    mLogFetchAcked(false),
    mDataCharHandle(0),
    mPendingPutReference(kNoReference),
    mPendingGetReference(kNoReference),
    mPendingGet(PendingGet::None)
{
    mSerial[0] = 0;
    mProductName[0] = 0;
    mSwVersion[0] = 0;
    // Seeded from the compile-time identity rather than left empty: /Info/App
    // is not answered by this device, and an empty app name reads to the app
    // as "not our firmware".
    copyInto(mAppName, sizeof(mAppName), MOVELOAD_APP_NAME);
    copyInto(mAppVersion, sizeof(mAppVersion), MOVELOAD_APP_VERSION);
}

GATTSensorDataClient::~GATTSensorDataClient()
{
}

bool GATTSensorDataClient::initModule()
{
    mModuleState = WB_RES::ModuleStateValues::INITIALIZED;
    return true;
}

void GATTSensorDataClient::deinitModule()
{
    mModuleState = WB_RES::ModuleStateValues::UNINITIALIZED;
}

bool GATTSensorDataClient::startModule()
{
    mModuleState = WB_RES::ModuleStateValues::STARTED;

    // Clear subscription table
    for (size_t i=0; i<MAX_DATASUB_COUNT; i++)
    {
        mDataSubs[i].clientReference = 0;
        mDataSubs[i].resourceId = wb::ID_INVALID_RESOURCE;
        mDataSubs[i].subStarted = false;
        mDataSubs[i].subCompleted = false;
    }

    // Follow BLE connection status
    asyncSubscribe(WB_RES::LOCAL::COMM_BLE_PEERS());

    // Configure custom gatt service
    configGattSvc();

    // HELLO must answer straight away with the serial the app pairs on and the
    // app name it checks before skipping the reboot on stop, so both are
    // fetched once here rather than per command.
    asyncGet(WB_RES::LOCAL::INFO());
    asyncGet(WB_RES::LOCAL::INFO_APP());

    return true;
}

void GATTSensorDataClient::sendCommandStatus(uint8_t reference, uint16_t status)
{
    uint8_t msg[4] = {COMMAND_RESULT, reference,
                      static_cast<uint8_t>(status & 0xFF),
                      static_cast<uint8_t>((status >> 8) & 0xFF)};
    WB_RES::Characteristic dataCharValue;
    dataCharValue.bytes = wb::MakeArray<uint8_t>(msg, sizeof(msg));
    asyncPut(mDataCharResource, AsyncRequestOptions(NULL, 0, true), dataCharValue);
}

void GATTSensorDataClient::sendCommandBytes(uint8_t reference, const uint8_t* pPayload, size_t length)
{
    if (length + 2 > sizeof(mDataMsgBuffer)) length = sizeof(mDataMsgBuffer) - 2;
    mDataMsgBuffer[0] = COMMAND_RESULT;
    mDataMsgBuffer[1] = reference;
    memcpy(&mDataMsgBuffer[2], pPayload, length);

    WB_RES::Characteristic dataCharValue;
    dataCharValue.bytes = wb::MakeArray<uint8_t>(mDataMsgBuffer, length + 2);
    asyncPut(mDataCharResource, AsyncRequestOptions(NULL, 0, true), dataCharValue);
}

void GATTSensorDataClient::onDeleteResult(wb::RequestId requestId,
                                          wb::ResourceId resourceId,
                                          wb::Result resultCode,
                                          const wb::Value& rResultData)
{
    // Erasing the logbook is a DELETE, so its result lands here rather than in
    // onPutResult — the command still owes the app an answer either way.
    if (mPendingPutReference != kNoReference)
    {
        const uint8_t reference = mPendingPutReference;
        mPendingPutReference = kNoReference;
        sendCommandStatus(reference, static_cast<uint16_t>(resultCode));
    }
}

void GATTSensorDataClient::onPutResult(wb::RequestId requestId,
                                       wb::ResourceId resourceId,
                                       wb::Result resultCode,
                                       const wb::Value& rResultData)
{
    // Writing the data characteristic is how every response leaves this class,
    // so its own result must not be reported back as if it were a command's.
    if (resourceId.localResourceId == WB_RES::LOCAL::COMM_BLE_GATTSVC_SVCHANDLE_CHARHANDLE::LID) return;

    if (mPendingPutReference != kNoReference)
    {
        const uint8_t reference = mPendingPutReference;
        mPendingPutReference = kNoReference;
        sendCommandStatus(reference, static_cast<uint16_t>(resultCode));
    }
}

void GATTSensorDataClient::stopModule()
{
    // Unsubscribe sensor data
    unsubscribeAllStreams();

    // Clean up GATT stuff
    asyncUnsubscribe(mCommandCharResource);
    asyncUnsubscribe(mDataCharResource);
    
    releaseResource(mCommandCharResource);
    releaseResource(mDataCharResource);
    
    mCommandCharResource = wb::ID_INVALID_RESOURCE;
    mDataCharResource = wb::ID_INVALID_RESOURCE;

    mModuleState = WB_RES::ModuleStateValues::STOPPED;
}

void GATTSensorDataClient::configGattSvc()
{
    WB_RES::GattSvc customGattSvc;
    WB_RES::GattChar characteristics[2];
    WB_RES::GattChar &commandChar = characteristics[0];
    WB_RES::GattChar &dataChar = characteristics[1];

    // Define the CMD characteristics
    WB_RES::GattProperty dataCharProp = WB_RES::GattProperty::NOTIFY;
    WB_RES::GattProperty commandCharProp = WB_RES::GattProperty::WRITE;

    dataChar.props = wb::MakeArray<WB_RES::GattProperty>( &dataCharProp, 1);
    dataChar.uuid = wb::MakeArray<uint8_t>( reinterpret_cast<const uint8_t*>(&DATA_CHAR_UUID), sizeof(DATA_CHAR_UUID));

    commandChar.props = wb::MakeArray<WB_RES::GattProperty>( &commandCharProp, 1);
    commandChar.uuid = wb::MakeArray<uint8_t>( reinterpret_cast<const uint8_t*>(&COMMAND_CHAR_UUID), sizeof(COMMAND_CHAR_UUID));

    // Combine chars to service
    customGattSvc.uuid = wb::MakeArray<uint8_t>( SENSOR_DATASERVICE_UUID, sizeof(SENSOR_DATASERVICE_UUID));
    customGattSvc.chars = wb::MakeArray<WB_RES::GattChar>(characteristics, 2);

    // Create custom service
    asyncPost(WB_RES::LOCAL::COMM_BLE_GATTSVC(), AsyncRequestOptions(NULL,0,true), customGattSvc);
}

// Simple command structure:
// - command [1 byte]
// - client reference [1 byte, not zero!]
// - Command specific data
//
// Result and data notifications are returned via dataCharacteristic in format
// - result type [1 byte]: (1= response to command, )2: data notification from subscription
// - client reference [1 byte]
// - data: (2 byte "HTTP result" for commands, sbem formatted binary for subscriptions)

// Command reference:
// SUBSCRIBE (=1)
//   data == WB Resource path as string
//
// UNSUBSCRIBE (=2)
//   no data
//   reference must match one given in SUBSCRIBE command
// 
// FETCH_LOG (=3)
//   data == uint32, the logId of the log to fetch
//   Returns data in DATA & DATA_PART2 responses in the format of the 
//   logbook/data/subscription (uint32 offset + byte array). End is indicated by empty byte array(s)

// The sample this file came from implements 0-3 only. The stock Flash firmware
// answers 4-9 as well, and MoveLoad needs them: without them the app can
// connect and stream but cannot list the logbook, start or stop a recording,
// set the clock, erase, or switch the sensor into DFU mode — which also means
// no software way back to a working firmware. Added by hand for that reason.


GATTSensorDataClient::DataSub* GATTSensorDataClient::findDataSub(const wb::LocalResourceId localResourceId)
{
    for (size_t i=0; i<MAX_DATASUB_COUNT; i++)
    {
        const DataSub &ds= mDataSubs[i];
        if (ds.resourceId.localResourceId == localResourceId)
            return &(mDataSubs[i]);
    }
    return nullptr;
}

GATTSensorDataClient::DataSub* GATTSensorDataClient::findDataSub(const wb::ResourceId resourceId)
{
    for (size_t i=0; i<MAX_DATASUB_COUNT; i++)
    {
        const DataSub &ds= mDataSubs[i];
        if (ds.resourceId == resourceId)
            return &(mDataSubs[i]);
    }
    return nullptr;
}

GATTSensorDataClient::DataSub*  GATTSensorDataClient::findDataSubByRef(const uint8_t clientReference)
{
    for (size_t i=0; i<MAX_DATASUB_COUNT; i++)
    {
        const DataSub &ds= mDataSubs[i];
        if (ds.clientReference == clientReference)
            return &(mDataSubs[i]);
    }
    return nullptr;
}

GATTSensorDataClient::DataSub* GATTSensorDataClient::getFreeDataSubSlot()
{
    for (size_t i=0; i<MAX_DATASUB_COUNT; i++)
    {
        const DataSub &ds= mDataSubs[i];
        if (ds.clientReference == 0 && ds.resourceId == wb::ID_INVALID_RESOURCE)
            return &(mDataSubs[i]);
    }
    return nullptr;
}

void GATTSensorDataClient::handleIncomingCommand(const wb::Array<uint8> &commandData)
{
    uint8_t cmd = commandData[0];
    uint8_t reference = commandData[1];
    const uint8_t *pData = commandData.size()>2 ? &(commandData[2]) : nullptr;
    uint16_t dataLen = commandData.size() - 2;

    switch (cmd)
    {
        case Commands::HELLO:
        {
            // The sample answered the literal bytes "Hello", which the app read
            // as a protocol version byte followed by null-terminated strings —
            // so it displayed the sensor's name as "ello". The real layout is
            // a version byte then serial, product, firmware, app, app version.
            uint8_t msg[128];
            size_t at = 0;
            msg[at++] = 1; // protocol version
            const char* fields[5] = {mSerial, mProductName, mSwVersion, mAppName, mAppVersion};
            for (size_t f = 0; f < 5; f++)
            {
                const char* p = fields[f];
                while (*p != 0 && at < sizeof(msg) - 1) msg[at++] = static_cast<uint8_t>(*p++);
                if (at < sizeof(msg)) msg[at++] = 0;
            }
            sendCommandBytes(reference, msg, at);
            return;
        }
        case Commands::PUT_SYSTEM_MODE:
        {
            // Mode 12 is FwUpdateMode: this is what lets the app put the sensor
            // into DFU without the AFE-pin dance, so it is the command that
            // makes every later firmware iteration cheap.
            if (pData == nullptr || dataLen < 1) { sendCommandStatus(reference, 400); return; }
            mPendingPutReference = reference;
            asyncPut(WB_RES::LOCAL::SYSTEM_MODE(), AsyncRequestOptions::ForceAsync,
                     static_cast<WB_RES::SystemModeValues::Type>(pData[0]));
            return;
        }
        case Commands::PUT_DATALOGGER_STATE:
        {
            if (pData == nullptr || dataLen < 1) { sendCommandStatus(reference, 400); return; }
            mPendingPutReference = reference;
            asyncPut(WB_RES::LOCAL::MEM_DATALOGGER_STATE(), AsyncRequestOptions::ForceAsync,
                     static_cast<WB_RES::DataLoggerStateValues::Type>(pData[0]));
            return;
        }
        case Commands::PUT_UTC_TIME:
        {
            // Microseconds since the epoch, little endian — the sensor's clock
            // resets to 2015 on every power loss, so the app sets it on connect.
            if (pData == nullptr || dataLen < sizeof(uint64_t)) { sendCommandStatus(reference, 400); return; }
            uint64_t micros = 0;
            memcpy(&micros, pData, sizeof(uint64_t));
            mPendingPutReference = reference;
            asyncPut(WB_RES::LOCAL::TIME(), AsyncRequestOptions::ForceAsync, static_cast<int64_t>(micros));
            return;
        }
        case Commands::GET:
        {
            if (pData == nullptr || dataLen < 2) { sendCommandStatus(reference, 400); return; }
            char path[64];
            size_t n = dataLen < sizeof(path) - 1 ? dataLen : sizeof(path) - 1;
            memcpy(path, pData, n);
            path[n] = 0;

            mPendingGetReference = reference;
            if (strcmp(path, "/Mem/DataLogger/State") == 0)
            {
                mPendingGet = PendingGet::DataLoggerState;
                asyncGet(WB_RES::LOCAL::MEM_DATALOGGER_STATE(), AsyncRequestOptions::ForceAsync);
            }
            else if (strcmp(path, "/Mem/Logbook/IsFull") == 0)
            {
                mPendingGet = PendingGet::LogbookIsFull;
                asyncGet(WB_RES::LOCAL::MEM_LOGBOOK_ISFULL(), AsyncRequestOptions::ForceAsync);
            }
            else if (strcmp(path, "/System/Energy/Level") == 0)
            {
                mPendingGet = PendingGet::BatteryLevel;
                asyncGet(WB_RES::LOCAL::SYSTEM_ENERGY_LEVEL(), AsyncRequestOptions::ForceAsync);
            }
            else if (strcmp(path, "/Mem/Logbook/entries") == 0 || strcmp(path, "/Mem/Logbook/Entries") == 0)
            {
                mPendingGet = PendingGet::LogbookEntries;
                asyncGet(WB_RES::LOCAL::MEM_LOGBOOK_ENTRIES(), AsyncRequestOptions::ForceAsync);
            }
            else
            {
                mPendingGetReference = kNoReference;
                mPendingGet = PendingGet::None;
                sendCommandStatus(reference, 404);
            }
            return;
        }
        case Commands::CLEAR_LOGBOOK:
        {
            mPendingPutReference = reference;
            asyncDelete(WB_RES::LOCAL::MEM_LOGBOOK_ENTRIES(), AsyncRequestOptions::ForceAsync);
            return;
        }
        case Commands::SUBSCRIBE:
        {
            DataSub *pDataSub = getFreeDataSubSlot();

            if (!pDataSub)
            {
                DEBUGLOG("No free datasub slot");
                // 507: HTTP_CODE_INSUFFICIENT_STORAGE
                uint8_t errorMsg[] = {COMMAND_RESULT, reference, 0x01,0xFB};
                
                WB_RES::Characteristic dataCharValue;
                dataCharValue.bytes = wb::MakeArray<uint8_t>(errorMsg, sizeof(errorMsg));
                asyncPut(mDataCharResource, AsyncRequestOptions(NULL, 0, true), dataCharValue);
                return;
            }

            // Store client reference to array and trigger subsribe
            DataSub &dataSub = *pDataSub;

            char pathBuffer[160]; // Big enough sincer MTU is 161
            memset(pathBuffer, 0, sizeof(pathBuffer));

            // Copy and null-terminate
            memcpy(pathBuffer, pData, dataLen);

            dataSub.subStarted = true;
            dataSub.subCompleted = false;
            dataSub.clientReference = reference;
            getResource(pathBuffer, dataSub.resourceId);

            asyncSubscribe(dataSub.resourceId, AsyncRequestOptions::ForceAsync);
        }
        break;
        case Commands::FETCH_LOG:
        {
            // Use the "old" API for fetching the log (GET)
            ASSERT(pData != nullptr);
            ASSERT(dataLen == sizeof(uint32_t));
            
            memcpy(&mLogIdToFetch, pData, dataLen);
            mLogFetchReference = reference;
            mLogFetchAcked = false;

            // TODO: Is there need for descriptors? Probably not but needs extra logic if there is.
            asyncGet(WB_RES::LOCAL::MEM_LOGBOOK_BYID_LOGID_DATA(), AsyncRequestOptions::ForceAsync, mLogIdToFetch);
            break;
        }
        case Commands::UNSUBSCRIBE:
        {
            DEBUGLOG("Commands::UNSUBSCRIBE. reference: %d", reference);

            // Store client reference to array and trigger subsribe
            DataSub *pDataSub = findDataSubByRef(reference);
            if (pDataSub != nullptr)
            {
                asyncUnsubscribe(pDataSub->resourceId);
                pDataSub->resourceId = wb::ID_INVALID_RESOURCE;
                pDataSub->clientReference = 0;
            }
            // Answer, like every other command. The sample returned in silence
            // and the app waited out its whole timeout on it — fifteen seconds
            // at the end of an HRV test, which read as a freeze.
            sendCommandStatus(reference, 200);
        }
        break;
    }
}


void GATTSensorDataClient::onGetResult(wb::RequestId requestId,
                                      wb::ResourceId resourceId,
                                      wb::Result resultCode,
                                      const wb::Value& rResultData)
{
    DEBUGLOG("GATTSensorDataClient::onGetResult");
    switch(resourceId.localResourceId)
    {
        case WB_RES::LOCAL::MEM_DATALOGGER_STATE::LID:
        case WB_RES::LOCAL::MEM_LOGBOOK_ISFULL::LID:
        case WB_RES::LOCAL::SYSTEM_ENERGY_LEVEL::LID:
        {
            if (mPendingGetReference == kNoReference) return;
            const uint8_t reference = mPendingGetReference;
            mPendingGetReference = kNoReference;
            const PendingGet kind = mPendingGet;
            mPendingGet = PendingGet::None;

            uint8_t value = 0;
            if (kind == PendingGet::DataLoggerState)
                value = static_cast<uint8_t>(rResultData.convertTo<WB_RES::DataLoggerState>());
            else if (kind == PendingGet::LogbookIsFull)
                value = rResultData.convertTo<bool>() ? 1 : 0;
            else
                value = static_cast<uint8_t>(rResultData.convertTo<uint8>());

            // [status(2, LE)] then the single byte the app reads.
            uint8_t body[3] = {static_cast<uint8_t>(resultCode & 0xFF),
                               static_cast<uint8_t>((resultCode >> 8) & 0xFF),
                               value};
            sendCommandBytes(reference, body, sizeof(body));
            return;
        }
        case WB_RES::LOCAL::MEM_LOGBOOK_ENTRIES::LID:
        {
            if (mPendingGetReference == kNoReference) return;
            const uint8_t reference = mPendingGetReference;
            mPendingGetReference = kNoReference;
            mPendingGet = PendingGet::None;

            const WB_RES::LogEntries &entries = rResultData.convertTo<const WB_RES::LogEntries&>();

            // The app reads: status(2, LE), one byte it ignores, then 16 bytes
            // per entry — id(4) modificationTimestamp(4) size(8), all little
            // endian. The ignored byte carries the count, which costs nothing
            // and makes the packet readable by eye.
            uint8_t body[128];
            size_t at = 0;
            body[at++] = static_cast<uint8_t>(resultCode & 0xFF);
            body[at++] = static_cast<uint8_t>((resultCode >> 8) & 0xFF);
            const size_t countAt = at;
            body[at++] = 0;

            uint8_t written = 0;
            for (size_t i = 0; i < entries.elements.size(); i++)
            {
                if (at + 16 > sizeof(body)) break;
                const WB_RES::LogEntry &e = entries.elements[i];
                const uint32_t id = e.id;
                const uint32_t stamp = e.modificationTimestamp;
                const uint64_t size = e.size.hasValue() ? e.size.getValue() : 0;
                memcpy(&body[at], &id, 4);      at += 4;
                memcpy(&body[at], &stamp, 4);   at += 4;
                memcpy(&body[at], &size, 8);    at += 8;
                written++;
            }
            body[countAt] = written;
            sendCommandBytes(reference, body, at);
            return;
        }
        case WB_RES::LOCAL::INFO::LID:
        {
            const WB_RES::DeviceInfo &info = rResultData.convertTo<const WB_RES::DeviceInfo&>();
            copyInto(mSerial, sizeof(mSerial), info.serial.operator const char*());
            copyInto(mProductName, sizeof(mProductName), info.productName.operator const char*());
            copyInto(mSwVersion, sizeof(mSwVersion), info.sw.operator const char*());
            return;
        }
        case WB_RES::LOCAL::INFO_APP::LID:
        {
            const WB_RES::AppInfo &appInfo = rResultData.convertTo<const WB_RES::AppInfo&>();
            copyInto(mAppName, sizeof(mAppName), appInfo.name.operator const char*());
            copyInto(mAppVersion, sizeof(mAppVersion), appInfo.version.operator const char*());
            return;
        }
        case WB_RES::LOCAL::COMM_BLE_GATTSVC_SVCHANDLE::LID:
        {
            // This code finalizes the service setup (triggered by code in onPostResult)
            const WB_RES::GattSvc &svc = rResultData.convertTo<const WB_RES::GattSvc &>();
            for (size_t i=0; i<svc.chars.size(); i++)
            {
                // Find out characteristic handles and store them for later use
                const WB_RES::GattChar &c = svc.chars[i];
                // Extract 16 bit sub-uuid from full 128bit uuid
                DEBUGLOG("c.uuid.size(): %u", c.uuid.size());
                uint16_t uuid16 = *reinterpret_cast<const uint16_t*>(&(c.uuid[12]));
                
                DEBUGLOG("char[%u] uuid16: 0x%04X", i, uuid16);

                if(uuid16 == dataCharUUID16)
                    mDataCharHandle = c.handle.hasValue() ? c.handle.getValue() : 0;
                else if(uuid16 == commandCharUUID16)
                    mCommandCharHandle = c.handle.hasValue() ? c.handle.getValue() : 0;
            }

            if (!mCommandCharHandle || !mDataCharHandle)
            {
                DEBUGLOG("ERROR: Not all chars were configured!");
                return;
            }

            char pathBuffer[32]= {'\0'};
            snprintf(pathBuffer, sizeof(pathBuffer), "/Comm/Ble/GattSvc/%d/%d", mSensorSvcHandle, mCommandCharHandle);
            getResource(pathBuffer, mCommandCharResource);
            snprintf(pathBuffer, sizeof(pathBuffer), "/Comm/Ble/GattSvc/%d/%d", mSensorSvcHandle, mDataCharHandle);
            getResource(pathBuffer, mDataCharResource);

            // Forse subscriptions asynchronously to save stack (will have stack overflow if not) 
            // Subscribe to listen to intervalChar notifications (someone writes new value to intervalChar) 
            asyncSubscribe(mCommandCharResource, AsyncRequestOptions(NULL, 0, true));
            // Subscribe to listen to measChar notifications (someone enables/disables the INDICATE characteristic) 
            asyncSubscribe(mDataCharResource,  AsyncRequestOptions(NULL, 0, true));
            break;
        }

        case WB_RES::LOCAL::MEM_LOGBOOK_BYID_LOGID_DATA::LID:
        {
            const auto &stream = rResultData.convertTo<const wb::ByteStream &>();
            DEBUGLOG("MEM_LOGBOOK_BYID_LOGID_DATA. resultCode: %d", resultCode);

            // The sample said "don't do a thing" here and returned in silence.
            // The app awaits an acknowledgement for FETCH_LOG, so silence is an
            // infinite wait: probing an id that does not exist — which is how
            // recordings past the fourth are found — hung until the command
            // timed out. A rejection is what tells it "no log at that id", and
            // it already treats that as an ordinary absence.
            if (resultCode >= 400)
            {
                if (!mLogFetchAcked)
                {
                    mLogFetchAcked = true;
                    sendCommandStatus(mLogFetchReference, static_cast<uint16_t>(resultCode));
                }
                return;
            }

            // Success needs an acknowledgement too, once, before the data.
            if (!mLogFetchAcked)
            {
                mLogFetchAcked = true;
                sendCommandStatus(mLogFetchReference, 200);
            }

            DEBUGLOG("Sendind from get. size: %d", stream.length());

            handleSendingLogbookData(stream.data, stream.length());
            if (resultCode == wb::HTTP_CODE_CONTINUE)
            {
                // Do another GET request to get the next bytes (needs to be async)
                asyncGet(WB_RES::LOCAL::MEM_LOGBOOK_BYID_LOGID_DATA(), AsyncRequestOptions::ForceAsync, mLogIdToFetch);
            }
            if (resultCode == wb::HTTP_CODE_OK)
            {
                DEBUGLOG("Fetching log complete. sending end marker.");
                // Send end marker (offset and no bytes)
                handleSendingLogbookData(nullptr, 0);
                // Mark "no current log"
                mLogIdToFetch=0;
                mLogFetchOffset=0;
                mLogFetchReference=0;
            }
            break;
        }
    }
}

/** @see whiteboard::ResourceClient::onGetResult */
void  GATTSensorDataClient::onSubscribeResult(wb::RequestId requestId,
                                              wb::ResourceId resourceId,
                                              wb::Result resultCode,
                                              const wb::Value& rResultData)
{
    DEBUGLOG("onSubscribeResult() resourceId: %u, resultCode: %d", resourceId, resultCode);

    switch (resourceId.localResourceId)
    {
        case WB_RES::LOCAL::COMM_BLE_PEERS::LID:
            {
                DEBUGLOG("OnSubscribeResult: WB_RES::LOCAL::COMM_BLE_PEERS: %d", resultCode);
                return;
            }
            break;
        case WB_RES::LOCAL::COMM_BLE_GATTSVC_SVCHANDLE_CHARHANDLE::LID:
            {
                DEBUGLOG("OnSubscribeResult: COMM_BLE_GATTSVC*: %d", resultCode);
                return;
            }
            break;
        default:
        {
            // All other notifications. These must be the client subscribed data streams
            GATTSensorDataClient::DataSub *ds = findDataSub(resourceId);
            if (ds == nullptr)
            {
                DEBUGLOG("DataSub not found for resource: %u", resourceId);
                return;
            }
            ASSERT(ds->subStarted);
            if (ds->subCompleted)
            {
                DEBUGLOG("subCompleted already: %u", resourceId);
                return;
            }

            const uint8_t reference = ds->clientReference;
            if (resultCode >= 400)
            {
                ds->clientReference = 0;
                ds->resourceId = wb::ID_INVALID_RESOURCE;
                ds->subStarted=false;
                ds->subCompleted=false;
            }
            else
            {
                ds->subCompleted=true;
            }
            // Answer either way. The sample returned in silence here, which
            // makes a refused subscription indistinguishable from a stream
            // that has not produced its first sample yet — and the app would
            // wait for ever on the difference.
            sendCommandStatus(reference, static_cast<uint16_t>(resultCode));
        }
        break;
    }
}

void GATTSensorDataClient::handleSendingLogbookData(const uint8_t *pData, uint32_t length)
{

    // Forward data to client in same format (offset + bytes)
    // If length > 150, split in two notifications
    memset(mDataMsgBuffer, 0, sizeof(mDataMsgBuffer));
    mDataMsgBuffer[0] = DATA;
    mDataMsgBuffer[1] = mLogFetchReference;
    
    // Copy offset
    size_t writePos = 2;
    memcpy(&(mDataMsgBuffer[writePos]), &mLogFetchOffset, sizeof(mLogFetchOffset));
    writePos += sizeof(mLogFetchOffset);

    size_t firstPartLen = (length>150) ? 150 : length;
    size_t secondPartLen = (length == firstPartLen) ? 0 : length - firstPartLen;
    DEBUGLOG("firstPartLen: %d, secondPartLen: %d", firstPartLen, secondPartLen);

    if (firstPartLen > 0)
    {
        memcpy(&(mDataMsgBuffer[writePos]), pData, firstPartLen);
        writePos += firstPartLen;
        mLogFetchOffset += firstPartLen;
    }
    else
    {
        DEBUGLOG("End of file marker");
    }

    WB_RES::Characteristic dataCharValue;
    dataCharValue.bytes = wb::MakeArray<uint8_t>(mDataMsgBuffer, writePos);
    asyncPut(mDataCharResource, AsyncRequestOptions::Empty, dataCharValue);

    if (secondPartLen > 0)
    {
        mDataMsgBuffer[0] = DATA_PART2;

        // Calc and write second offset
        writePos = 2;
        memcpy(&(mDataMsgBuffer[writePos]), &mLogFetchOffset, sizeof(mLogFetchOffset));
        writePos += sizeof(mLogFetchOffset);
        // Copy second part data
        memcpy(&(mDataMsgBuffer[writePos]), &(pData[firstPartLen]), secondPartLen);
        writePos += secondPartLen;
        mLogFetchOffset += secondPartLen;

        dataCharValue.bytes = wb::MakeArray<uint8_t>(mDataMsgBuffer, writePos);
        asyncPut(mDataCharResource, AsyncRequestOptions::Empty, dataCharValue);
    }
}

void GATTSensorDataClient::unsubscribeAllStreams()
{
    for (size_t i=0;i<MAX_DATASUB_COUNT; i++)
    {
        if (mDataSubs[i].resourceId != wb::ID_INVALID_RESOURCE)
        {
            asyncUnsubscribe(mDataSubs[i].resourceId);
            mDataSubs[i].clientReference = 0;
            mDataSubs[i].resourceId = wb::ID_INVALID_RESOURCE;
            mDataSubs[i].subStarted = false;
            mDataSubs[i].subCompleted = false;
        }
    }
}

void GATTSensorDataClient::onNotify(wb::ResourceId resourceId,
                                   const wb::Value& value,
                                   const wb::ParameterList& rParameters)
{
    switch(resourceId.localResourceId)
    {
        case WB_RES::LOCAL::COMM_BLE_PEERS::LID:
            {
                WB_RES::PeerChange peerChange = value.convertTo<WB_RES::PeerChange>();
                if (peerChange.state == peerChange.state.DISCONNECTED)
                {
                    // if connection is dropped, unsubscribe all data streams so that sensor does not stay on for no reason
                    unsubscribeAllStreams();

                    // The notification flag is driven by the CCCD, and a link
                    // that simply drops writes no CCCD — the phone pocketed,
                    // out of range, the app killed. Without this it stays true
                    // for ever, and since MoveLoadAutoApp reads it as "somebody
                    // is deliberately using the sensor", the strap going on
                    // never arms anything again: no LED, no recording, no clue.
                    // Seen 2026-09-05, after the app began releasing the link
                    // on every move to the background.
                    mNotificationsEnabled = false;
                    g_gspClientActive = false;
                }
            }

            break;
        case WB_RES::LOCAL::COMM_BLE_GATTSVC_SVCHANDLE_CHARHANDLE::LID:
        {
            WB_RES::LOCAL::COMM_BLE_GATTSVC_SVCHANDLE_CHARHANDLE::SUBSCRIBE::ParameterListRef parameterRef(rParameters);
            if (parameterRef.getCharHandle() == mCommandCharHandle) 
            {
                const WB_RES::Characteristic &charValue = value.convertTo<const WB_RES::Characteristic &>();

                DEBUGLOG("onNotify: mCommandCharHandle: len: %d", charValue.bytes.size());

                handleIncomingCommand(charValue.bytes);
                return;
            }
            else if (parameterRef.getCharHandle() == mDataCharHandle) 
            {
                const WB_RES::Characteristic &charValue = value.convertTo<const WB_RES::Characteristic &>();
                // Update the notification state so we know if to forward data to datapipe
                mNotificationsEnabled = charValue.notifications.hasValue() ? charValue.notifications.getValue() : false;
                g_gspClientActive = mNotificationsEnabled;
                DEBUGLOG("onNotify: mDataCharHandle. mNotificationsEnabled: %d", mNotificationsEnabled);
            }
            break;
        }

        case WB_RES::LOCAL::MEM_LOGBOOK_BYID_LOGID_DATA::LID:
        {
            GATTSensorDataClient::DataSub *ds = findDataSub(resourceId.localResourceId);
            if (ds == nullptr)
            {
                DEBUGLOG("DataSub not found for resource: %u", resourceId);
                return;
            }

            // Handle special case of subscribing logbook data
            const auto &dataNotification = value.convertTo<const WB_RES::LogDataNotification &>();
            const size_t length = dataNotification.bytes.size();
            DEBUGLOG("Logbook data notification. offset: %d, length: %d", dataNotification.offset, length);


            // Forward data to client in same format (offset + bytes)
            // If length > 150, split in two notifications
            memset(mDataMsgBuffer, 0, sizeof(mDataMsgBuffer));
            mDataMsgBuffer[0] = DATA;
            mDataMsgBuffer[1] = ds->clientReference;
            
            // Copy offset
            size_t writePos = 2;
            memcpy(&(mDataMsgBuffer[writePos]), &(dataNotification.offset), sizeof(dataNotification.offset));
            writePos += sizeof(dataNotification.offset);
            size_t firstPartLen = (length>150) ? 150 : length;
            size_t secondPartLen = (length == firstPartLen) ? 0 : length - firstPartLen;
            DEBUGLOG("firstPartLen: %d, secondPartLen: %d", firstPartLen, secondPartLen);
            if (firstPartLen > 0)
            {
                memcpy(&(mDataMsgBuffer[writePos]), &(dataNotification.bytes[0]), firstPartLen);
                writePos += firstPartLen;
            }
            else
            {
                DEBUGLOG("End of file marker");
            }

            WB_RES::Characteristic dataCharValue;
            dataCharValue.bytes = wb::MakeArray<uint8_t>(mDataMsgBuffer, writePos);
            asyncPut(mDataCharResource, AsyncRequestOptions::Empty, dataCharValue);

            if (secondPartLen > 0)
            {
                mDataMsgBuffer[0] = DATA_PART2;

                // Calc and write second offset
                writePos = 2;
                uint32_t secondOffset = dataNotification.offset + firstPartLen;
                memcpy(&(mDataMsgBuffer[writePos]), &secondOffset, sizeof(secondOffset));
                writePos += sizeof(secondOffset);
                // Copy second part data
                memcpy(&(mDataMsgBuffer[writePos]), &(dataNotification.bytes[firstPartLen]), secondPartLen);
                writePos += secondPartLen;

                dataCharValue.bytes = wb::MakeArray<uint8_t>(mDataMsgBuffer, writePos);
                asyncPut(mDataCharResource, AsyncRequestOptions::Empty, dataCharValue);
            }
            break;
        }

        default:
        {
            // All other notifications. These must be the client subscribed data streams
            GATTSensorDataClient::DataSub *ds = findDataSub(resourceId);
            if (ds == nullptr)
            {
                DEBUGLOG("DataSub not found for resource: %u", resourceId);
                return;
            }
        
            DEBUGLOG("DS clientReference: %u", ds->clientReference);
            DEBUGLOG("DS subStarted: %u", ds->subStarted);
            DEBUGLOG("DS subCompleted: %u", ds->subCompleted);

            // Make sure we can serialize the data
            size_t length = getSbemLength(resourceId.localResourceId, value);
            if (length == 0)
            {
                DEBUGLOG("No length for localResourceId: %u", resourceId.localResourceId);
                return;
            }



            // Forward data to client
            memset(mDataMsgBuffer, 0, sizeof(mDataMsgBuffer));
            mDataMsgBuffer[0] = DATA;
            mDataMsgBuffer[1] = ds->clientReference;

            size_t writePos = 2;
            size_t firstPartLen = (length>150) ? 150 : length;
            size_t secondPartLen = (length == firstPartLen) ? 0 : length - firstPartLen;
            DEBUGLOG("firstPartLen: %d, secondPartLen: %d", firstPartLen, secondPartLen);

            // Write the first part of notification value
            length = writeToSbemBuffer(&mDataMsgBuffer[2], sizeof(mDataMsgBuffer)-2, 0, resourceId.localResourceId, value);
            writePos += firstPartLen;

            WB_RES::Characteristic dataCharValue;
            dataCharValue.bytes = wb::MakeArray<uint8_t>(mDataMsgBuffer, writePos);
            asyncPut(mDataCharResource, AsyncRequestOptions::Empty, dataCharValue);

            if (secondPartLen > 0)
            {
                mDataMsgBuffer[0] = DATA_PART2;
                writePos = 2;
                // Write the second part of data starting from offset "firstPartLen"
                length = writeToSbemBuffer(&mDataMsgBuffer[2], sizeof(mDataMsgBuffer)-2, firstPartLen, resourceId.localResourceId, value);
                writePos += secondPartLen;
                // And send it
                dataCharValue.bytes = wb::MakeArray<uint8_t>(mDataMsgBuffer, writePos);
                asyncPut(mDataCharResource, AsyncRequestOptions::Empty, dataCharValue);
            }
            return;

            break;
        }

    }
}

void GATTSensorDataClient::onPostResult(wb::RequestId requestId, 
                                       wb::ResourceId resourceId, 
                                       wb::Result resultCode, 
                                       const wb::Value& rResultData)
{
    DEBUGLOG("GATTSensorDataClient::onPostResult: %d", resultCode);

    if (resultCode == wb::HTTP_CODE_CREATED)
    {
        // Custom Gatt service was created
        mSensorSvcHandle = (int32_t)rResultData.convertTo<uint16_t>();
        DEBUGLOG("Custom Gatt service was created. handle: %d", mSensorSvcHandle);
        
        // Request more info about created svc so we get the char handles
        asyncGet(WB_RES::LOCAL::COMM_BLE_GATTSVC_SVCHANDLE(), AsyncRequestOptions(NULL,0,true), mSensorSvcHandle);
        // Note: The rest of the init is performed in onGetResult()
    }
}