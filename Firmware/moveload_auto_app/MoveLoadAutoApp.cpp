#include "movesense.h"

#include "MoveLoadAutoApp.h"
#include "common/core/debug.h"
#include <string.h>

#include "mem_datalogger/resources.h"
#include "meas_hr/resources.h"
#include "system_states/resources.h"
#include "comm_ble/resources.h"
#include "GATTSensorDataClient.h"
#include "comm_ble/resources.h"
#include "comm_ble_hrs/resources.h"
#include "ui_ind/resources.h"

const char* const MoveLoadAutoApp::LAUNCHABLE_NAME = "MoveLoadAuto";

// How long the LED stays on after the recording starts or stops.
#define INDICATION_DURATION_MS 2000

// One blink is 180 ms lit, 180 ms dark: fast enough to read a count of three
// at a glance, slow enough to be seen at all.
#define BLINK_STEP_MS 180

// The vocabulary. Three at the start of an automatic recording, five at the
// end — different counts rather than different lengths, because a count can be
// reported over the phone and a length cannot.
#define BLINKS_RECORDING_STARTED 3
#define BLINKS_RECORDING_STOPPED 5

// Two when the arming window closes without a pulse. The steady light already
// says "strap noticed"; without this, the silence that follows means either
// "still listening" or "gave up minutes ago", and those are different faults.
// It repeats every retry, so a sensor that cannot read the wearer says so
// about every eight minutes instead of looking asleep.
#define BLINKS_NO_PULSE_FOUND 2

// How long the strap must stay off the body *and* the sensor stay still
// before the recording is closed. Losing skin contact mid-session is common
// enough that stopping on contact alone would cut sessions in two; requiring
// stillness as well means only a sensor genuinely put down — on the bench in
// the changing room — ends the recording.
#define STOP_DELAY_MS 60000

// How long to wait for a pulse after contact is made before concluding the
// sensor is not on anybody.
//
// Was 90 s, which was too short: on the first hardware test the pulse appeared
// only after a while — dry indoor skin takes its time to conduct — and arming
// had already given up, leaving nothing to see for another ten minutes. The
// cost of waiting longer is only the heart rate measurement running on a strap
// that turns out to be empty; the cost of waiting too little is a session that
// never records, which is the failure that actually matters.
#define ARMING_TIMEOUT_MS 300000

// After a failed attempt, how long before listening for a pulse again while
// contact persists. Giving up for good would be worse than a stray recording:
// skin that is dry at the start of a session becomes conductive once the
// athlete warms up, and a session silently never recorded is the failure that
// actually costs something. Retrying keeps the heart rate measurement off
// most of the time, so a strap left damp in a bag still costs almost nothing.
//
// Shortened with the longer window above: what matters to the athlete is the
// worst case between putting the strap on and recording starting, and that is
// the window plus the gap. Five and three keeps it under ten minutes while
// still leaving the measurement off for most of a damp strap's life.
#define ARMING_RETRY_MS 180000

// The recording watchdog ticks once a minute; one tick with nothing that looks
// like a heart ends the recording. A strap taken off still wet keeps reporting
// contact, so this is the only thing that stops a sensor left on a damp belt
// from recording all evening — the "no contact and no movement" rule never
// even starts its timer in that case.
//
// One tick rather than three (the athlete's call, 2026-09-01). It is less
// brittle than it sounds: a tick only counts as bad when the *whole* sixty
// seconds held fewer than RR_ALIVE_TRANSITIONS_NEEDED plausible beats, so a
// dropout of a few seconds mid-minute leaves enough good beats to pass. The
// risk it accepts is a genuine minute-long loss of signal mid-session ending
// the recording — against which the counter resets on any good tick.
#define WATCHDOG_TICK_MS 60000
#define WATCHDOG_TICKS_WITHOUT_HR 1

// Plausible human heart rate. A wet strap produces no QRS at all, so this is
// mostly a guard against a garbage first reading rather than a fine filter.
// What separates a heart from a damp strap, second attempt.
//
// The first (1.3.0) asked only that the intervals *change*, on the theory that
// an artefact repeats itself. Tested on hardware: the recording still never
// stopped, so the noise varies rather than freezing — the detector fires on
// random peaks and the intervals scatter across the whole window it accepts,
// 270 to 2000 ms.
//
// So the test is not that the interval moves but that it moves *like a heart*:
// beat to beat, by tens of milliseconds. The eight intervals captured from a
// real chest on 2026-09-01 moved by 16, 24, 32, 71, 78, 94 and 219 ms — a
// resting athlete at 46 bpm, which is about as much natural variability as
// there is. Random crossings of a 270–2000 ms window average far more.
//
// A change of exactly zero is not alive either: that is the frozen case 1.3.0
// was aimed at, and it must still be rejected.
#define RR_ALIVE_MAX_DELTA_MS 250
#define RR_ALIVE_TRANSITIONS_NEEDED 5

// How long an externally requested stop keeps the sensor from re-arming.
//
// The flag it bounds means "a human just told me to stop, do not undo it",
// and that intent lasts minutes. It used to be cleared by one thing only —
// the strap losing contact — which a strap that stays damp suppresses
// indefinitely, because a wet strap bridges the studs exactly like skin. So
// the morning's HRV test, which stops the recording the sensor had started on
// its own, inhibited every recording for the rest of the day: no arming, no
// LED, nothing to see.
//
// Twenty minutes: the test itself is ten, the flag is set at its start, so
// this expires about ten minutes after it ends — by which time the strap is
// off — while still being far longer than a deliberate tap needs respecting.
// Nothing is at risk on expiry: re-arming still has to find a heart-like
// pulse, which a strap on a bench does not have.
#define EXTERNAL_STOP_RESPECT_MS 1200000

#define HR_MIN_BPM 30
#define HR_MAX_BPM 220

/// The running instance, so the GSP client can answer /MoveLoad/State without
/// a whiteboard round-trip — the same idiom as g_gspClientActive in the other
/// direction. There is exactly one of each module.
MoveLoadAutoApp* g_moveLoadAutoApp = nullptr;

MoveLoadAutoApp::MoveLoadAutoApp():
    ResourceClient(WBDEBUG_NAME(__FUNCTION__), WB_EXEC_CTX_APPLICATION),
    LaunchableModule(LAUNCHABLE_NAME, WB_EXEC_CTX_APPLICATION),
    mDataLoggerState(WB_RES::DataLoggerStateValues::DATALOGGER_INVALID),
    mConnectorState(2),  // 2 = unknown, per /System/States Connector
    mMovementState(0),
    mTransitionPending(false),
    mHrsEnabled(false),
    mArming(false),
    mHeartRateSubscribed(false),
    mHeartRateSeen(false),
    mTicksWithoutHeartRate(0),
    mStopRequested(false),
    mExternalStopHonoured(false),
    mExternalStopTimer(wb::ID_INVALID_TIMER),
    mArmingBackoff(false),
    mStopTimer(wb::ID_INVALID_TIMER),
    mArmingTimer(wb::ID_INVALID_TIMER),
    mWatchdogTimer(wb::ID_INVALID_TIMER),
    mIndicationTimer(wb::ID_INVALID_TIMER),
    mLastRRms(0),
    mAliveTransitionsThisTick(0),
    mWildTransitionsThisTick(0),
    mBlinksLeft(0),
    mBlinkOn(false),
    mJournalCount(0),
    mJournalNext(0)
{
    memset(mJournal, 0, sizeof(mJournal));
    g_moveLoadAutoApp = this;
}

MoveLoadAutoApp::~MoveLoadAutoApp()
{
    g_moveLoadAutoApp = nullptr;
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
    stopRecordingWatchdog();
    stopTimer(mArmingTimer);
    mArmingTimer = wb::ID_INVALID_TIMER;
    stopTimer(mIndicationTimer);
    mIndicationTimer = wb::ID_INVALID_TIMER;

    asyncUnsubscribe(WB_RES::LOCAL::COMM_BLE_HRS());
    mHrsEnabled = false;
    mArming = false;
    updateHeartRateSubscription();
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
        case WB_RES::LOCAL::COMM_BLE_PEERS::LID:
        {
            // Only ever requested by releaseLinkToWatch, and only while not
            // recording — so anything connected is holding the link for a
            // reason that can wait until the next session.
            //
            // Except a phone: the HRV test streams R-R live over GSP with the
            // DataLogger deliberately stopped, so "not recording" is exactly
            // when it needs the link most. A GSP client with its notifications
            // enabled is that phone, and is never shown the door.
            if (isLogging() || GATTSensorDataClient::hasActiveClient()) return;
            const WB_RES::PeerList &peers = result.convertTo<const WB_RES::PeerList&>();
            for (size_t i = 0; i < peers.connectedPeers.size(); i++)
            {
                const WB_RES::PeerEntry &peer = peers.connectedPeers[i];
                if (peer.handle.hasValue())
                {
                    asyncDelete(WB_RES::LOCAL::COMM_BLE_PEERS_CONNHANDLE(),
                                AsyncRequestOptions::ForceAsync,
                                static_cast<int32_t>(peer.handle.getValue()));
                }
            }
            return;
        }
        case WB_RES::LOCAL::MEM_DATALOGGER_STATE::LID:
        {
            const bool wasLogging = isLogging();
            mDataLoggerState = result.convertTo<WB_RES::DataLoggerState>();
            DEBUGLOG("DataLogger state: %d", mDataLoggerState);

            if (wasLogging && !isLogging())
            {
                stopRecordingWatchdog();
                if (mStopRequested)
                {
                    mStopRequested = false;
                }
                else
                {
                    // Nobody here asked for this, so the app did. Respect it:
                    // the athlete may well still be wearing the strap with a
                    // perfectly good pulse, and re-arming would undo the tap
                    // they just made.
                    DEBUGLOG("Recording stopped from outside — not restarting for now");
                    note(NOTE_EXTERNAL_STOP);
                    mExternalStopHonoured = true;
                    abandonArming();
                    // Bounded, because the clearing condition can never come:
                    // see EXTERNAL_STOP_RESPECT_MS.
                    if (mExternalStopTimer != wb::ID_INVALID_TIMER)
                    {
                        stopTimer(mExternalStopTimer);
                    }
                    mExternalStopTimer = startTimer(EXTERNAL_STOP_RESPECT_MS, false);
                }
            }
            else if (!wasLogging && isLogging())
            {
                startRecordingWatchdog();
            }

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

            const uint16_t plausible = (uint16_t)hrData.average;

            // Count how far the interval moved. Plausibility of the average is
            // kept as a first filter, but on its own it is what a damp strap
            // satisfies all evening.
            if (hrData.rrData.size() > 0)
            {
                const uint16_t rr = hrData.rrData[hrData.rrData.size() - 1];
                if (mLastRRms != 0)
                {
                    const uint16_t delta = (rr > mLastRRms) ? (rr - mLastRRms) : (mLastRRms - rr);
                    if (delta > 0 && delta <= RR_ALIVE_MAX_DELTA_MS)
                    {
                        if (mAliveTransitionsThisTick < 255) mAliveTransitionsThisTick++;
                    }
                    else if (delta > RR_ALIVE_MAX_DELTA_MS)
                    {
                        if (mWildTransitionsThisTick < 255) mWildTransitionsThisTick++;
                    }
                }
                mLastRRms = rr;
            }

            if (plausible >= HR_MIN_BPM && plausible <= HR_MAX_BPM)
            {
                mHeartRateSeen = true;
            }

            if (mArming)
            {
                const uint16_t bpm = (uint16_t)hrData.average;
                // The same test as the watchdog, for the same reason: this gate
                // exists precisely to keep a damp strap from recording all
                // evening, and a plausible average is exactly what a damp strap
                // produces. Waiting for the intervals to move costs about five
                // beats — five seconds — against a phantom session.
                // The same guard as the one on beginArming, applied here too.
                // 1.6.0 only stopped arming from *starting* while a phone was
                // connected — but the strap goes on before the app is opened,
                // so arming was already under way and the pulse started a
                // recording in the middle of the HRV test anyway. This is the
                // moment that actually matters.
                if (bpm >= HR_MIN_BPM && bpm <= HR_MAX_BPM
                    && mAliveTransitionsThisTick >= RR_ALIVE_TRANSITIONS_NEEDED
                    && mAliveTransitionsThisTick > mWildTransitionsThisTick
                    && !GATTSensorDataClient::hasActiveClient())
                {
                    DEBUGLOG("Pulse found (%d bpm) — the strap is on someone", bpm);
                    note(NOTE_PULSE_FOUND);
                    mArming = false;
                    stopTimer(mArmingTimer);
                    mArmingTimer = wb::ID_INVALID_TIMER;
                    startLogging();
                }
            }

            if (!mHrsEnabled)
            {
                // Measured for our own sake; no watch is listening.
                break;
            }

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
        // reconsidered when its result comes back. Filed because a pending
        // flag that never clears would silence everything below it, and from
        // the outside that looks exactly like a sensor that saw nothing.
        note(NOTE_BLOCKED_BY_BUSY);
        return;
    }

    const bool strapOn = (mConnectorState == 1);
    const bool moving = (mMovementState == 1);

    if (!isLogging())
    {
        cancelStopTimer();

        if (!strapOn)
        {
            note(NOTE_STRAP_OFF);
            // Contact gone — but an arming attempt already under way is left
            // to run.
            //
            // Connector state chatters: a strap being settled on the chest
            // reports contact made and lost several times a second, and tearing
            // arming down on each loss restarted the heart rate measurement
            // every time, so it never got the continuous run it needs to lock
            // on. The pulse then never reached the gate at all — while Showcase,
            // which subscribes heart rate regardless of connector state, saw it
            // perfectly. The LED blinking without pause was this loop, visible.
            //
            // Nothing is needed to bound it: if the strap really is off, no
            // pulse arrives and the arming timer ends the attempt on its own.
            //
            // The backoff is a different matter, and clearing the flag alone
            // was a trap. The timer id is shared between two meanings — the
            // five-minute attempt and the three-minute pause after it — and
            // the branch taken when it fires is chosen by this very flag. Clear
            // the flag without stopping the timer and the next expiry is read
            // as an attempt that found no pulse: it blinks the two-blink
            // no-pulse code, sets the flag again, and starts another pause,
            // all without ever arming. Nothing subscribes the heart rate in
            // that state, so no pulse can arrive to end it. Every loss of
            // contact renewed the trap, and a strap picked up, wetted and
            // carried loses contact several times before it reaches a chest.
            //
            // Stopping it here also makes contact-after-loss arm at once
            // rather than serve out a pause whose reason — a strap left damp
            // in a bag — has visibly stopped applying.
            mArmingBackoff = false;
            if (mArmingTimer != wb::ID_INVALID_TIMER)
            {
                stopTimer(mArmingTimer);
                mArmingTimer = wb::ID_INVALID_TIMER;
            }
            forgetExternalStop();
            return;
        }

        note(NOTE_STRAP_ON);

        if (mExternalStopHonoured)
        {
            note(NOTE_BLOCKED_BY_EXTERNAL_STOP);
            return;
        }

        // Contact made — but contact is not proof of a body. Sweat and river
        // water bridge the studs just as skin does, and a wet strap left in a
        // bag would otherwise record all evening and fill the flash. Wait for
        // a pulse before committing. An unknown connector state (2) does not
        // even get that far.
        // Not while a phone is connected over GSP.
        //
        // A connected phone means someone is deliberately using the sensor —
        // running an HRV test, downloading, looking at settings — not putting a
        // strap on to go training. During the first real HRV test the firmware
        // did exactly the wrong thing: the test stopped the DataLogger, and
        // seconds later contact and a real pulse armed it and started
        // recording again, which is precisely what stopping it was for. During
        // a genuine session the phone is not connected; it is in the changing
        // room.
        if (mArming)
        {
            // Already listening; nothing to file.
        }
        else if (mArmingBackoff)
        {
            note(NOTE_BLOCKED_BY_PAUSE);
        }
        else if (GATTSensorDataClient::hasActiveClient())
        {
            note(NOTE_BLOCKED_BY_PHONE);
        }
        else
        {
            beginArming();
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
    note(NOTE_RECORDING_STARTED);
    mTransitionPending = true;
    mArmingBackoff = false;

    // The DataLogger takes over the heart rate from here.
    abandonArming();

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

    blink(BLINKS_RECORDING_STARTED);
}

void MoveLoadAutoApp::stopLogging()
{
    DEBUGLOG("stopLogging()");
    note(NOTE_RECORDING_STOPPED);
    mTransitionPending = true;
    mStopRequested = true;

    // READY is what flushes the buffered samples to flash and closes the
    // logbook entry. Reaching power-off without it loses the session.
    asyncPut(WB_RES::LOCAL::MEM_DATALOGGER_STATE(), AsyncRequestOptions::ForceAsync,
             WB_RES::DataLoggerStateValues::DATALOGGER_READY);

    blink(BLINKS_RECORDING_STOPPED);
}

void MoveLoadAutoApp::note(Note what)
{
    // Deduplicated against the last entry only. Connector state chatters
    // several times a second while a strap is being settled on a chest, and a
    // ring of sixteen would otherwise hold one second of that and nothing of
    // the morning.
    if (mJournalCount > 0)
    {
        const size_t lastIndex = (mJournalNext + JOURNAL_CAPACITY - 1) % JOURNAL_CAPACITY;
        if (mJournal[lastIndex].code == static_cast<uint8_t>(what)) return;
    }

    mJournal[mJournalNext].at = WbTimestampGet();
    mJournal[mJournalNext].code = static_cast<uint8_t>(what);
    mJournalNext = (mJournalNext + 1) % JOURNAL_CAPACITY;
    if (mJournalCount < JOURNAL_CAPACITY) mJournalCount++;
}

size_t MoveLoadAutoApp::describeCurrentState(uint8_t* out, size_t capacity)
{
    if (g_moveLoadAutoApp == nullptr)
    {
        // Answer anyway: an empty journal says "this firmware is not running",
        // which is itself worth knowing, and beats a request that times out.
        if (capacity < 2) return 0;
        out[0] = 1;
        out[1] = 0;
        return 2;
    }
    return g_moveLoadAutoApp->describeState(out, capacity);
}

/// Layout, little-endian, version 1:
///   0      format version
///   1      connector state (0 off, 1 contact, 2 unknown)
///   2      movement state
///   3      flags: 1 arming, 2 pause, 4 external stop, 8 transition pending,
///          16 recording, 32 phone connected over GSP, 64 heart rate subscribed
///   4      number of journal entries that follow
///   5..    per entry: seconds ago (uint16), code (uint8)
///
/// Seconds ago rather than a clock: the sensor's RTC resets to 2015 on every
/// power loss, and what the reader needs is "three hours ago", not a date.
size_t MoveLoadAutoApp::describeState(uint8_t* out, size_t capacity) const
{
    if (capacity < 5) return 0;
    const WbTimestamp now = WbTimestampGet();

    out[0] = 1;
    out[1] = mConnectorState;
    out[2] = mMovementState;
    out[3] = static_cast<uint8_t>(
        (mArming ? 1 : 0) | (mArmingBackoff ? 2 : 0) | (mExternalStopHonoured ? 4 : 0) |
        (mTransitionPending ? 8 : 0) | (isLogging() ? 16 : 0) |
        (GATTSensorDataClient::hasActiveClient() ? 32 : 0) |
        (mHeartRateSubscribed ? 64 : 0));

    size_t at = 5;
    uint8_t written = 0;
    // Oldest first, so the reader can print them in the order they happened.
    for (uint8_t i = 0; i < mJournalCount; i++)
    {
        const size_t index =
            (mJournalNext + JOURNAL_CAPACITY - mJournalCount + i) % JOURNAL_CAPACITY;
        if (at + 3 > capacity) break;
        int elapsedMs = WbTimestampDifferenceMs(mJournal[index].at, now);
        if (elapsedMs < 0) elapsedMs = 0;
        uint32_t seconds = static_cast<uint32_t>(elapsedMs) / 1000;
        if (seconds > 0xFFFF) seconds = 0xFFFF;   // older than 18 hours
        out[at++] = static_cast<uint8_t>(seconds & 0xFF);
        out[at++] = static_cast<uint8_t>((seconds >> 8) & 0xFF);
        out[at++] = mJournal[index].code;
        written++;
    }
    out[4] = written;
    return at;
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

void MoveLoadAutoApp::forgetExternalStop()
{
    if (mExternalStopTimer != wb::ID_INVALID_TIMER)
    {
        stopTimer(mExternalStopTimer);
        mExternalStopTimer = wb::ID_INVALID_TIMER;
    }
    mExternalStopHonoured = false;
}

void MoveLoadAutoApp::beginArming()
{
    DEBUGLOG("Contact made — waiting for a pulse before recording");
    note(NOTE_ARMING_BEGAN);
    mArming = true;
    // Tell the wearer the strap was noticed. Until this, a sensor that had
    // seen nothing and one patiently waiting for a pulse looked exactly the
    // same from the outside, which made the first hardware test unreadable.
    indicateBriefly();
    updateHeartRateSubscription();

    stopTimer(mArmingTimer);
    mArmingTimer = startTimer(ARMING_TIMEOUT_MS, false);
}

void MoveLoadAutoApp::abandonArming()
{
    if (mArmingTimer != wb::ID_INVALID_TIMER)
    {
        stopTimer(mArmingTimer);
        mArmingTimer = wb::ID_INVALID_TIMER;
    }
    mArmingBackoff = false;
    if (!mArming)
    {
        return;
    }
    mArming = false;
    updateHeartRateSubscription();
}

void MoveLoadAutoApp::startRecordingWatchdog()
{
    if (mWatchdogTimer != wb::ID_INVALID_TIMER)
    {
        return;
    }
    mHeartRateSeen = false;
    mTicksWithoutHeartRate = 0;
    mWatchdogTimer = startTimer(WATCHDOG_TICK_MS, true);
    updateHeartRateSubscription();
}

void MoveLoadAutoApp::stopRecordingWatchdog()
{
    if (mWatchdogTimer == wb::ID_INVALID_TIMER)
    {
        return;
    }
    stopTimer(mWatchdogTimer);
    mWatchdogTimer = wb::ID_INVALID_TIMER;
    updateHeartRateSubscription();
}

void MoveLoadAutoApp::hrsNotificationChanged(bool enabled)
{
    if (enabled == mHrsEnabled)
    {
        return;
    }
    mHrsEnabled = enabled;
    updateHeartRateSubscription();

    // A watch subscribing while nothing is being recorded is a watch holding
    // the only link outside a session. Give it back.
    if (enabled && !isLogging())
    {
        DEBUGLOG("Heart rate profile taken outside a session — releasing the link");
        releaseLinkToWatch();
    }
}

void MoveLoadAutoApp::releaseLinkToWatch()
{
    // Reading the peer list rather than remembering a handle: the disconnect
    // needs one, and with a single link whatever is connected here is the
    // subscriber we just heard from.
    asyncGet(WB_RES::LOCAL::COMM_BLE_PEERS());
}

void MoveLoadAutoApp::updateHeartRateSubscription()
{
    // The DataLogger subscribes /Meas/HR itself while recording, so this is
    // only about the watch and the arming gate.
    // Three reasons to measure: a watch is listening, we are waiting for a
    // pulse to start, or we are watching for one to disappear mid-recording.
    const bool wanted = mHrsEnabled || mArming || (mWatchdogTimer != wb::ID_INVALID_TIMER);

    // Never taken away from under a connected phone. The HRV test streams
    // /Meas/HR over GSP for ten minutes with the DataLogger deliberately
    // stopped and no watch listening, so `wanted` is false for the whole of
    // it — and several paths through here (arming abandoned, the watchdog
    // ending with the recording the test just stopped) would unsubscribe the
    // very measurement the test is made of. Releasing it is deferred until the
    // phone lets go and this runs again — arming beginning or giving up, a
    // watch appearing, a recording's watchdog starting or ending. Each of
    // those already calls this, so nothing is stranded.
    if (!wanted && GATTSensorDataClient::hasActiveClient())
    {
        return;
    }

    if (wanted == mHeartRateSubscribed)
    {
        return;
    }

    if (wanted)
    {
        asyncSubscribe(WB_RES::LOCAL::MEAS_HR());
    }
    else
    {
        asyncUnsubscribe(WB_RES::LOCAL::MEAS_HR());
    }
    mHeartRateSubscribed = wanted;
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

void MoveLoadAutoApp::blink(uint8_t count)
{
    mBlinksLeft = count;
    mBlinkOn = false;
    if (mIndicationTimer != wb::ID_INVALID_TIMER)
    {
        stopTimer(mIndicationTimer);
        mIndicationTimer = wb::ID_INVALID_TIMER;
    }
    blinkStep();
}

void MoveLoadAutoApp::blinkStep()
{
    if (mBlinksLeft == 0 && !mBlinkOn)
    {
        asyncPut(WB_RES::LOCAL::UI_IND_VISUAL(), AsyncRequestOptions::Empty,
                 WB_RES::VisualIndTypeValues::NO_VISUAL_INDICATIONS);
        mIndicationTimer = wb::ID_INVALID_TIMER;
        return;
    }

    mBlinkOn = !mBlinkOn;
    if (!mBlinkOn) { mBlinksLeft--; }
    asyncPut(WB_RES::LOCAL::UI_IND_VISUAL(), AsyncRequestOptions::ForceAsync,
             mBlinkOn ? WB_RES::VisualIndTypeValues::CONTINUOUS_VISUAL_INDICATION
                      : WB_RES::VisualIndTypeValues::NO_VISUAL_INDICATIONS);
    mIndicationTimer = startTimer(BLINK_STEP_MS, false);
}

void MoveLoadAutoApp::onTimer(wb::TimerId timerId)
{
    if (timerId == mIndicationTimer)
    {
        if (mBlinksLeft > 0 || mBlinkOn) { blinkStep(); return; }
        mIndicationTimer = wb::ID_INVALID_TIMER;
        asyncPut(WB_RES::LOCAL::UI_IND_VISUAL(), AsyncRequestOptions::Empty,
                 WB_RES::VisualIndTypeValues::NO_VISUAL_INDICATIONS);
        return;
    }

    if (timerId == mWatchdogTimer)
    {
        // The DataLogger state cannot be subscribed to, so this tick is also
        // how we notice the app stopping the recording behind our back.
        asyncGet(WB_RES::LOCAL::MEM_DATALOGGER_STATE());

        // A pulse counts only if the intervals moved. Without this the
        // recording never ended: the strap comes off still damp, the service
        // keeps reporting an average in range, and every tick looked like a
        // beating heart.
        // Enough heart-like changes, and more of them than wild ones. A damp
        // strap can produce either a frozen reading or a scattered one; this
        // rejects both without rejecting a resting athlete with high
        // variability.
        const bool aliveThisTick = mHeartRateSeen
            && mAliveTransitionsThisTick >= RR_ALIVE_TRANSITIONS_NEEDED
            && mAliveTransitionsThisTick > mWildTransitionsThisTick;
        mHeartRateSeen = false;
        mAliveTransitionsThisTick = 0;
        mWildTransitionsThisTick = 0;

        if (aliveThisTick)
        {
            mTicksWithoutHeartRate = 0;
            return;
        }

        mTicksWithoutHeartRate++;
        if (mTicksWithoutHeartRate >= WATCHDOG_TICKS_WITHOUT_HR && isLogging() && !mTransitionPending)
        {
            DEBUGLOG("No pulse for %d minutes — closing the recording", mTicksWithoutHeartRate);
            stopLogging();
        }
        return;
    }

    if (timerId == mExternalStopTimer)
    {
        mExternalStopTimer = wb::ID_INVALID_TIMER;
        if (mExternalStopHonoured)
        {
            DEBUGLOG("The external stop has been respected long enough — listening again");
            mExternalStopHonoured = false;
            evaluateRecordingState();
        }
        return;
    }

    if (timerId == mArmingTimer)
    {
        mArmingTimer = wb::ID_INVALID_TIMER;

        if (mArmingBackoff)
        {
            // The pause is over: listen again, in case contact has improved.
            mArmingBackoff = false;
            evaluateRecordingState();
            return;
        }

        // A phone on the line is why the gate never closed — not a missing
        // pulse. Arming cannot complete while a GSP client is connected (that
        // is the guard in the heart rate handler), so after five minutes of a
        // ten-minute HRV test this branch fired on an athlete lying still with
        // a perfectly good heartbeat, and did the two worst things it could:
        // it blinked "no pulse found", which is the signal the auto-start is
        // read by, and it dropped the heart rate measurement the phone was
        // streaming. Keep waiting instead; the strap is on someone and the
        // phone will let go when the test ends.
        if (GATTSensorDataClient::hasActiveClient())
        {
            mArmingTimer = startTimer(ARMING_TIMEOUT_MS, false);
            return;
        }

        DEBUGLOG("No pulse yet — pausing before another attempt");
        note(NOTE_ARMING_TIMED_OUT);
        blink(BLINKS_NO_PULSE_FOUND);
        mArming = false;
        mArmingBackoff = true;
        updateHeartRateSubscription();
        mArmingTimer = startTimer(ARMING_RETRY_MS, false);
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
