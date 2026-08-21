#pragma once

#include <whiteboard/LaunchableModule.h>
#include <whiteboard/ResourceClient.h>

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
    void cancelStopTimer();
    void startRecordingWatchdog();
    void stopRecordingWatchdog();
    void indicateBriefly();

    /// Mirrors the standard HR profile's notification switch: only measure
    /// heart rate while a watch is actually listening for it.
    void hrsNotificationChanged(bool enabled);

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
};
