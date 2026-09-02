#pragma once

#include <whiteboard/LaunchableModule.h>
#include <whiteboard/ResourceClient.h>

class GATTSensorDataClient FINAL : private wb::ResourceClient, public wb::LaunchableModule
{
public:
    /** Name of this class. Used in StartupProvider list. */
    static const char* const LAUNCHABLE_NAME;

    /// Whether a phone is connected over GSP with its notifications enabled.
    /// Read by MoveLoadAutoApp before it hands the single BLE link back to
    /// whoever asked for the heart rate profile: a phone streaming R-R for an
    /// HRV test does so with the DataLogger stopped, so "not recording" is
    /// exactly when it must not be disconnected.
    static bool hasActiveClient();
    GATTSensorDataClient();
    ~GATTSensorDataClient();

private:
    /** @see whiteboard::ILaunchableModule::initModule */
    virtual bool initModule() OVERRIDE;
    /** @see whiteboard::ILaunchableModule::deinitModule */
    virtual void deinitModule() OVERRIDE;
    /** @see whiteboard::ILaunchableModule::startModule */
    virtual bool startModule() OVERRIDE;
    /** @see whiteboard::ILaunchableModule::stopModule */
    virtual void stopModule() OVERRIDE;

    /** @see whiteboard::ResourceClient::onPostResult */
    virtual void onPostResult(wb::RequestId requestId,
                              wb::ResourceId resourceId,
                              wb::Result resultCode,
                              const wb::Value& rResultData) OVERRIDE;

    /** @see whiteboard::ResourceClient::onPutResult */
    virtual void onPutResult(wb::RequestId requestId,
                             wb::ResourceId resourceId,
                             wb::Result resultCode,
                             const wb::Value& rResultData) OVERRIDE;

    /** @see whiteboard::ResourceClient::onDeleteResult */
    virtual void onDeleteResult(wb::RequestId requestId,
                                wb::ResourceId resourceId,
                                wb::Result resultCode,
                                const wb::Value& rResultData) OVERRIDE;

    /** @see whiteboard::ResourceClient::onGetResult */
    virtual void onGetResult(wb::RequestId requestId,
                             wb::ResourceId resourceId,
                             wb::Result resultCode,
                             const wb::Value& rResultData);

    /** @see whiteboard::ResourceClient::onGetResult */
    virtual void onSubscribeResult(wb::RequestId requestId,
                                   wb::ResourceId resourceId,
                                   wb::Result resultCode,
                                   const wb::Value& rResultData);

    /** @see whiteboard::ResourceClient::onNotify */
    virtual void onNotify(wb::ResourceId resourceId,
                          const wb::Value& rValue,
                          const wb::ParameterList& rParameters);

private:
    void configGattSvc();
    void unsubscribeAllStreams();

    wb::ResourceId mCommandCharResource;
    wb::ResourceId mDataCharResource;
    wb::TimerId mMeasurementTimer;

    int32_t mSensorSvcHandle;
    int32_t mCommandCharHandle;
    int32_t mDataCharHandle;

    bool mNotificationsEnabled;

    uint32_t mLogIdToFetch;
    uint32_t mLogFetchOffset;
    uint8_t mLogFetchReference;
    /// FETCH_LOG owes the app one acknowledgement, and exactly one: the
    /// transfer arrives as CONTINUE chunks, each of which lands here again.
    bool mLogFetchAcked;
    // Data subscriptions

    struct DataSub {
        wb::ResourceId resourceId;
        uint8_t clientReference;
        bool subStarted;
        bool subCompleted;
    };
    static constexpr size_t MAX_DATASUB_COUNT = 4;
    DataSub mDataSubs[MAX_DATASUB_COUNT];

    DataSub *getFreeDataSubSlot();

    // Buffer for outgoing data messages (MTU -3)
    uint8_t mDataMsgBuffer[158];

    DataSub* findDataSub(const wb::ResourceId resourceId);
    DataSub* findDataSub(const wb::LocalResourceId localResourceId);
    DataSub* findDataSubByRef(const uint8_t clientReference);

    void handleIncomingCommand(const wb::Array<uint8> &commandData);
    void handleSendingLogbookData(const uint8_t *pData, uint32_t length);

    /// Sends `[COMMAND_RESULT, reference, status(2, little endian)]`, the shape
    /// the app expects from every command that returns a bare status.
    void sendCommandStatus(uint8_t reference, uint16_t status);
    /// Sends `[COMMAND_RESULT, reference, payload…]` for commands that carry
    /// data back.
    void sendCommandBytes(uint8_t reference, const uint8_t* pPayload, size_t length);

    /// The app issues one command at a time and awaits each, so a single slot
    /// is enough to remember who to answer when the whiteboard replies.
    /// `kNoReference` means nothing is outstanding.
    static constexpr uint8_t kNoReference = 0xFF;
    uint8_t mPendingPutReference;

    /// GET (command 4) carries a resource path, and the answer has to be
    /// serialised in the exact byte layout the app decodes. Rather than write a
    /// general whiteboard serialiser, the four paths the app actually asks for
    /// are dispatched by name and each builds its own reply.
    enum class PendingGet : uint8_t { None, DataLoggerState, LogbookIsFull, BatteryLevel, LogbookEntries };
    uint8_t mPendingGetReference;
    PendingGet mPendingGet;

    /// Cached from /Info and /Info/App at startup, because HELLO has to answer
    /// synchronously with the serial the app pairs on and the app name it
    /// checks before skipping the reboot on stop.
    char mSerial[20];
    char mProductName[28];
    char mSwVersion[20];
    char mAppName[28];
    char mAppVersion[20];
};
