#include "movesense.h"

#include "MoveLoadAutoApp.h"
#include "common/core/debug.h"

#include "mem_datalogger/resources.h"
#include "meas_hr/resources.h"
#include "system_states/resources.h"
#include "comm_ble/resources.h"
#include "comm_ble_hrs/resources.h"
#include "ui_ind/resources.h"

const char* const MoveLoadAutoApp::LAUNCHABLE_NAME = "MoveLoadAuto";

// How long the LED stays on after the recording starts or stops.
#define INDICATION_DURATION_MS 2000

// How long the strap must stay off the body *and* the sensor stay still
// before the recording is closed. Losing skin contact mid-session is common
// enough that stopping on contact alone would cut sessions in two; requiring
// stillness as well means only a sensor genuinely put down — on the bench in
// the changing room — ends the recording.
#define STOP_DELAY_MS 60000

MoveLoadAutoApp::MoveLoadAutoApp():
    ResourceClient(WBDEBUG_NAME(__FUNCTION__), WB_EXEC_CTX_APPLICATION),
    LaunchableModule(LAUNCHABLE_NAME, WB_EXEC_CTX_APPLICATION),
    mDataLoggerState(WB_RES::DataLoggerStateValues::DATALOGGER_INVALID),
    mConnectorState(2),  // 2 = unknown, per /System/States Connector
    mMovementState(0),
    mTransitionPending(false),
    mHrsEnabled(false),
    mStopTimer(wb::ID_INVALID_TIMER),
    mIndicationTimer(wb::ID_INVALID_TIMER)
{
}

MoveLoadAutoApp::~MoveLoadAutoApp()
{
}

bool MoveLoadAutoApp::initModule()
{
    mModuleState = WB_RES::ModuleStateValues::INITIALIZED;
    return true;
}

void MoveLoadAutoApp::deinitModule()
{
    mModuleState = WB_RES::ModuleStateValues::UNINITIALIZED;
}

bool MoveLoadAutoApp::startModule()
{
    mModuleState = WB_RES::ModuleStateValues::STARTED;

    // Learn where things stand before reacting to any change: the sensor may
    // boot with the strap already on, and the DataLogger may already be
    // running from before a reset.
    asyncGet(WB_RES::LOCAL::MEM_DATALOGGER_STATE());
    asyncGet(WB_RES::LOCAL::SYSTEM_STATES_STATEID(), AsyncRequestOptions::Empty, WB_RES::StateIdValues::CONNECTOR);
    asyncGet(WB_RES::LOCAL::SYSTEM_STATES_STATEID(), AsyncRequestOptions::Empty, WB_RES::StateIdValues::MOVEMENT);

    // Strap contact is the session boundary; movement only holds the stop
    // back. Both are persistent states, unlike the transient DoubleTap the
    // previous firmware used.
    asyncSubscribe(WB_RES::LOCAL::SYSTEM_STATES_STATEID(), AsyncRequestOptions::Empty, WB_RES::StateIdValues::CONNECTOR);
    asyncSubscribe(WB_RES::LOCAL::SYSTEM_STATES_STATEID(), AsyncRequestOptions::Empty, WB_RES::StateIdValues::MOVEMENT);

    // The watch half: follow the standard HR profile's notification switch.
    asyncSubscribe(WB_RES::LOCAL::COMM_BLE_HRS());

    return true;
}

void MoveLoadAutoApp::stopModule()
{
    cancelStopTimer();
    stopTimer(mIndicationTimer);
    mIndicationTimer = wb::ID_INVALID_TIMER;

    asyncUnsubscribe(WB_RES::LOCAL::COMM_BLE_HRS());
    if (mHrsEnabled)
    {
        asyncUnsubscribe(WB_RES::LOCAL::MEAS_HR());
        mHrsEnabled = false;
    }
    asyncUnsubscribe(WB_RES::LOCAL::SYSTEM_STATES_STATEID(), AsyncRequestOptions::Empty, WB_RES::StateIdValues::MOVEMENT);
    asyncUnsubscribe(WB_RES::LOCAL::SYSTEM_STATES_STATEID(), AsyncRequestOptions::Empty, WB_RES::StateIdValues::CONNECTOR);

    mModuleState = WB_RES::ModuleStateValues::STOPPED;
}

bool MoveLoadAutoApp::isLogging() const
{
    return mDataLoggerState == WB_RES::DataLoggerStateValues::DATALOGGER_LOGGING;
}

void MoveLoadAutoApp::onGetResult(whiteboard::RequestId requestId,
                                  whiteboard::ResourceId resourceId,
                                  whiteboard::Result resultCode,
                                  const whiteboard::Value& result)
{
    switch (resourceId.localResourceId)
    {
        case WB_RES::LOCAL::MEM_DATALOGGER_STATE::LID:
        {
            mDataLoggerState = result.convertTo<WB_RES::DataLoggerState>();
            DEBUGLOG("DataLogger state: %d", mDataLoggerState);
            evaluateRecordingState();
            break;
        }

        case WB_RES::LOCAL::SYSTEM_STATES_STATEID::LID:
        {
            // A plain GET answers with the state value alone, so the StateId
            // has to come from the request's own parameter list rather than
            // from the answer.
            const WB_RES::StateChange stateChange = result.convertTo<WB_RES::StateChange>();
            if (stateChange.stateId == WB_RES::StateIdValues::CONNECTOR)
            {
                mConnectorState = stateChange.newState;
            }
            else if (stateChange.stateId == WB_RES::StateIdValues::MOVEMENT)
            {
                mMovementState = stateChange.newState;
            }
            evaluateRecordingState();
            break;
        }
    }
}

void MoveLoadAutoApp::onPutResult(whiteboard::RequestId requestId,
                                  whiteboard::ResourceId resourceId,
                                  whiteboard::Result resultCode,
                                  const whiteboard::Value& result)
{
    if (resourceId.localResourceId == WB_RES::LOCAL::MEM_DATALOGGER_STATE::LID)
    {
        DEBUGLOG("DataLogger state PUT result: %d", resultCode);
        mTransitionPending = false;
        // Read the state back rather than assuming the PUT took: a refused
        // state change (a full logbook, for instance) must not leave us
        // believing we are recording when we are not.
        asyncGet(WB_RES::LOCAL::MEM_DATALOGGER_STATE());
    }
}

void MoveLoadAutoApp::onNotify(wb::ResourceId resourceId,
                               const wb::Value& value,
                               const wb::ParameterList& parameters)
{
    switch (resourceId.localResourceId)
    {
        case WB_RES::LOCAL::SYSTEM_STATES_STATEID::LID:
        {
            const WB_RES::StateChange stateChange = value.convertTo<WB_RES::StateChange>();

            if (stateChange.stateId == WB_RES::StateIdValues::CONNECTOR)
            {
                DEBUGLOG("Connector: %d", stateChange.newState);
                mConnectorState = stateChange.newState;
            }
            else if (stateChange.stateId == WB_RES::StateIdValues::MOVEMENT)
            {
                mMovementState = stateChange.newState;
            }
            else
            {
                break;
            }

            evaluateRecordingState();
            break;
        }

        // The watch turned heart rate notifications on or off.
        case WB_RES::LOCAL::COMM_BLE_HRS::LID:
        {
            hrsNotificationChanged(value.convertTo<const WB_RES::HRSState&>().notificationEnabled);
            break;
        }

        // Heart rate measured for the watch — forward it to the standard
        // profile. The DataLogger records /Meas/HR on its own, so this
        // subscription is for the watch only and nothing here touches what
        // is written to flash.
        case WB_RES::LOCAL::MEAS_HR::LID:
        {
            const WB_RES::HRData& hrData = value.convertTo<const WB_RES::HRData&>();

            WB_RES::HRSData hrsData;
            hrsData.hr = hrData.average;
            if (hrData.rrData.size() > 0)
            {
                hrsData.rr = wb::MakeArray<uint16_t>(&(hrData.rrData[0]), hrData.rrData.size());
            }
            asyncPost(WB_RES::LOCAL::COMM_BLE_HRS(), AsyncRequestOptions::Empty, hrsData);
            break;
        }
    }
}

void MoveLoadAutoApp::evaluateRecordingState()
{
    if (mTransitionPending)
    {
        // A start or stop is still in flight; whatever changed will be
        // reconsidered when its result comes back.
        return;
    }

    const bool strapOn = (mConnectorState == 1);
    const bool moving = (mMovementState == 1);

    if (!isLogging())
    {
        // Nothing is recording. Putting the strap on is what starts it.
        // An unknown connector state (2) deliberately does not: better to
        // record nothing than to fill the flash on a sensor sitting in a bag.
        cancelStopTimer();
        if (strapOn)
        {
            startLogging();
        }
        return;
    }

    // Recording. Either condition holding keeps it alive — the strap back on
    // the body, or a sensor still being carried around.
    if (strapOn || moving)
    {
        cancelStopTimer();
        return;
    }

    armStopTimer();
}

void MoveLoadAutoApp::startLogging()
{
    DEBUGLOG("startLogging()");
    mTransitionPending = true;

    // These two paths and this rate are what MoveLoad's own analysis assumes
    // — see LoggingConfig and MovesenseSensorService.accelerometerPath. A
    // different rate here would shift the walking detection and the effort
    // windows without anything reporting an error.
    WB_RES::DataEntry accEntry;
    accEntry.path = "/Meas/Acc/52";
    WB_RES::DataEntry hrEntry;
    hrEntry.path = "/Meas/HR";
    WB_RES::DataEntry entries[2] = { accEntry, hrEntry };

    WB_RES::DataLoggerConfig config;
    config.dataEntries.dataEntry = wb::MakeArray<WB_RES::DataEntry>(entries, 2);

    asyncPut(WB_RES::LOCAL::MEM_DATALOGGER_CONFIG(), AsyncRequestOptions::ForceAsync, config);
    asyncPut(WB_RES::LOCAL::MEM_DATALOGGER_STATE(), AsyncRequestOptions::ForceAsync,
             WB_RES::DataLoggerStateValues::DATALOGGER_LOGGING);

    indicateBriefly();
}

void MoveLoadAutoApp::stopLogging()
{
    DEBUGLOG("stopLogging()");
    mTransitionPending = true;

    // READY is what flushes the buffered samples to flash and closes the
    // logbook entry. Reaching power-off without it loses the session.
    asyncPut(WB_RES::LOCAL::MEM_DATALOGGER_STATE(), AsyncRequestOptions::ForceAsync,
             WB_RES::DataLoggerStateValues::DATALOGGER_READY);

    indicateBriefly();
}

void MoveLoadAutoApp::armStopTimer()
{
    if (mStopTimer != wb::ID_INVALID_TIMER)
    {
        return;  // already counting down
    }
    DEBUGLOG("Strap off and still — stopping in %d ms unless that changes", STOP_DELAY_MS);
    mStopTimer = startTimer(STOP_DELAY_MS, false);
}

void MoveLoadAutoApp::cancelStopTimer()
{
    if (mStopTimer == wb::ID_INVALID_TIMER)
    {
        return;
    }
    stopTimer(mStopTimer);
    mStopTimer = wb::ID_INVALID_TIMER;
}

void MoveLoadAutoApp::hrsNotificationChanged(bool enabled)
{
    if (enabled == mHrsEnabled)
    {
        return;
    }

    if (enabled)
    {
        asyncSubscribe(WB_RES::LOCAL::MEAS_HR());
    }
    else
    {
        asyncUnsubscribe(WB_RES::LOCAL::MEAS_HR());
    }

    mHrsEnabled = enabled;
}

void MoveLoadAutoApp::indicateBriefly()
{
    asyncPut(WB_RES::LOCAL::UI_IND_VISUAL(), AsyncRequestOptions::ForceAsync,
             WB_RES::VisualIndTypeValues::CONTINUOUS_VISUAL_INDICATION);

    if (mIndicationTimer != wb::ID_INVALID_TIMER)
    {
        stopTimer(mIndicationTimer);
    }
    mIndicationTimer = startTimer(INDICATION_DURATION_MS, false);
}

void MoveLoadAutoApp::onTimer(wb::TimerId timerId)
{
    if (timerId == mIndicationTimer)
    {
        mIndicationTimer = wb::ID_INVALID_TIMER;
        asyncPut(WB_RES::LOCAL::UI_IND_VISUAL(), AsyncRequestOptions::Empty,
                 WB_RES::VisualIndTypeValues::NO_VISUAL_INDICATIONS);
        return;
    }

    if (timerId == mStopTimer)
    {
        mStopTimer = wb::ID_INVALID_TIMER;
        // The conditions are re-read rather than trusted: sixty seconds is
        // long enough for the strap to have gone back on.
        if (mConnectorState != 1 && mMovementState != 1 && isLogging())
        {
            stopLogging();
        }
    }
}
