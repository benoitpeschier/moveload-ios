#pragma once

#include <whiteboard/LaunchableModule.h>
#include <whiteboard/ResourceClient.h>
#include <whiteboard/integration/bsp/timestamp.h>

/// Records a session without anyone touching anything: putting the strap on
/// starts the DataLogger, leaving the sensor still and off the body stops it.
/// MoveLoad then connects afterwards to download, and can still stop a
/// recording by hand if the automatic stop did not fire.
///
/// It also serves the standard heart rate profile, so a Garmin/Suunto/Coros
/// watch can display the cardio live and carry it into its own platform. The
/// dual-peripheral BLE configuration in App.cpp lets the watch and the phone
/// be connected at once.
///
/// Replaces moveload_logger_app, which needed a double-tap to toggle.
class MoveLoadAutoApp FINAL : private wb::ResourceClient, public wb::LaunchableModule
{
public:
    static const char* const LAUNCHABLE_NAME;

    MoveLoadAutoApp();
    ~MoveLoadAutoApp();

    /// One decision, kept so that a morning which recorded nothing can say
    /// why instead of being reconstructed afterwards from an empty logbook.
    ///
    /// Three faults in a row have had the same shape — a state machine that
    /// could no longer be entered — and each cost a day of field testing to
    /// find, because from the outside every one of them looks identical: no
    /// LED, no session, no clue.
    enum Note : uint8_t
    {
        NOTE_STRAP_ON = 1,
        NOTE_STRAP_OFF,
        NOTE_ARMING_BEGAN,
        NOTE_PULSE_FOUND,
        NOTE_ARMING_TIMED_OUT,
        NOTE_BLOCKED_BY_PHONE,
        NOTE_BLOCKED_BY_EXTERNAL_STOP,
        NOTE_BLOCKED_BY_PAUSE,
        NOTE_BLOCKED_BY_BUSY,
        NOTE_RECORDING_STARTED,
        NOTE_RECORDING_STOPPED,
        NOTE_EXTERNAL_STOP,
    };

    /// Writes the current state and the journal into `out`, for the GSP GET on
    /// /MoveLoad/State. Returns the number of bytes written, always ≤ capacity.
    /// Answers even when no instance is running, so the phone gets an empty
    /// journal rather than a timeout.
    static size_t describeCurrentState(uint8_t* out, size_t capacity);

private:
    virtual bool initModule() OVERRIDE;
    virtual void deinitModule() OVERRIDE;
    virtual bool startModule() OVERRIDE;
    virtual void stopModule() OVERRIDE;

    virtual void onNotify(wb::ResourceId resourceId,
                          const wb::Value& value,
                          const wb::ParameterList& parameters) OVERRIDE;

    virtual void onGetResult(whiteboard::RequestId requestId,
                             whiteboard::ResourceId resourceId,
                             whiteboard::Result resultCode,
                             const whiteboard::Value& result) OVERRIDE;

    virtual void onPutResult(whiteboard::RequestId requestId,
                             whiteboard::ResourceId resourceId,
                             whiteboard::Result resultCode,
                             const whiteboard::Value& result) OVERRIDE;

    virtual void onTimer(wb::TimerId timerId) OVERRIDE;

    /// Applies the start/stop rule to the current strap and movement state.
    /// Called after every state change rather than deciding inside each
    /// handler, so the rule lives in exactly one place.
    void evaluateRecordingState();

    /// Contact alone is not proof the sensor is on a body: a wet strap
    /// conducts across the studs just as skin does. Arming subscribes to the
    /// heart rate and waits for a real pulse before committing to record.
    void beginArming();
    void abandonArming();
    void startLogging();
    void stopLogging();
    void armStopTimer();
    /// Files a decision, unless it repeats the one just filed. Contact
    /// chatters several times a second while a strap is being settled, and an
    /// undeduplicated journal would hold nothing but that.
    void note(Note what);
    size_t describeState(uint8_t* out, size_t capacity) const;
    /// Clears the external-stop inhibition and its timer together, so the two
    /// cannot disagree.
    void forgetExternalStop();
    void cancelStopTimer();
    void startRecordingWatchdog();
    void stopRecordingWatchdog();
    void indicateBriefly();

    /// Blinks `count` times, so the sensor can say *which* thing happened
    /// rather than only that something did. There is one LED and no screen, so
    /// the count is the whole vocabulary — and it doubles as the only way to
    /// observe the automatic stop from outside.
    void blink(uint8_t count);
    void blinkStep();

    /// A damp strap conducts across the studs and the heart rate service goes
    /// on emitting a plausible average from it, so "the average is between 30
    /// and 220 bpm" is not evidence of a body. What a wet strap cannot fake is
    /// **variation**: real R-R intervals move by tens of milliseconds from beat
    /// to beat, an artefact repeats itself. These count the changes.
    uint16_t mLastRRms;
    /// Beat-to-beat changes that look like a heart: moved, but not by more
    /// than a heart can move. Counted against those that do not.
    uint8_t mAliveTransitionsThisTick;
    uint8_t mWildTransitionsThisTick;

    uint8_t mBlinksLeft;
    bool mBlinkOn;

    /// Mirrors the standard HR profile's notification switch: only measure
    /// heart rate while a watch is actually listening for it.
    void hrsNotificationChanged(bool enabled);

    /// Hands the single BLE link back when a watch takes it outside a session.
    ///
    /// The sensor has one peripheral link (see App.cpp), and a link that is
    /// held is a sensor that stops advertising entirely — so a watch still
    /// paired after the session makes the phone unable to find the sensor at
    /// all, which is exactly when the athlete wants to download. Serving the
    /// heart rate profile only while recording keeps both uses without either
    /// standing on the other: the watch during the session, the phone after.
    void releaseLinkToWatch();

    /// Heart rate is wanted by the watch, by the arming gate, or by neither.
    /// Subscribing twice and unsubscribing once would leave it running, so
    /// the two reasons are tracked apart and reconciled here.
    void updateHeartRateSubscription();

    bool isLogging() const;

    uint8_t mDataLoggerState;
    /// Strap contact, from /System/States/2. Starts UNKNOWN so a strap
    /// already worn at boot is picked up by the initial GET.
    uint8_t mConnectorState;
    /// Movement, from /System/States/0.
    uint8_t mMovementState;
    /// True between a DataLogger PUT and its result, so a burst of state
    /// changes cannot fire two starts.
    bool mTransitionPending;
    /// A watch has switched heart rate notifications on.
    bool mHrsEnabled;
    /// Waiting to see a pulse before starting to record.
    bool mArming;
    /// Whether /Meas/HR is currently subscribed on our behalf.
    bool mHeartRateSubscribed;
    /// A pulse arrived since the last watchdog tick.
    bool mHeartRateSeen;
    /// Consecutive watchdog ticks with no pulse at all.
    uint8_t mTicksWithoutHeartRate;
    /// True from our own stop request until we see it take effect, so a stop
    /// the app made can be told apart from one we made ourselves.
    bool mStopRequested;
    /// Set when the recording ended without us asking — the app stopped it.
    /// Blocks restarting until the strap comes off, so tapping "stop" while
    /// still wearing it is not immediately undone.
    bool mExternalStopHonoured;
    /// Set while waiting out the pause between two attempts to find a pulse.
    bool mArmingBackoff;

    /// Runs while the stop conditions hold; stopping happens only when it
    /// expires, never on the state change itself.
    wb::TimerId mStopTimer;
    /// Bounds one attempt to find a pulse, then the pause before the next.
    wb::TimerId mArmingTimer;
    /// Ticks throughout a recording: watches for the heart rate going away,
    /// and re-reads the DataLogger state, which cannot be subscribed to.
    wb::TimerId mWatchdogTimer;
    wb::TimerId mIndicationTimer;
    /// Bounds mExternalStopHonoured. Without it the flag outlived its purpose
    /// by a whole day — see EXTERNAL_STOP_RESPECT_MS.
    wb::TimerId mExternalStopTimer;

    struct JournalEntry
    {
        WbTimestamp at;
        uint8_t code;
    };
    /// Sixteen decisions is about a morning: the strap going on, an attempt,
    /// its outcome, and whatever refused it. Older ones fall off the end,
    /// which is the right end to lose — the question is always what happened
    /// last.
    static const size_t JOURNAL_CAPACITY = 16;
    JournalEntry mJournal[JOURNAL_CAPACITY];
    /// How many entries the ring holds, saturating at its capacity.
    uint8_t mJournalCount;
    /// Where the next entry goes.
    uint8_t mJournalNext;
};
