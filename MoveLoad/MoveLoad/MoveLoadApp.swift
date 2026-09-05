//
//  MoveLoadApp.swift
//  MoveLoad
//
//  Created by Benoît PESCHIER on 30/07/2026.
//

import SwiftUI
import SensorKit
import SwiftData

@main
struct MoveLoadApp: App {
    @State private var appEnvironment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appEnvironment)
                // Without this, every `@Query` in the app reads a container
                // that is not the one the app writes to, and returns nothing —
                // for ever, whatever accumulates. It cost the HRV history, the
                // calendar's heart pills, and the fatigue verdict, which is
                // gated on the query being non-empty and so had never once
                // been shown. Nothing crashed and nothing was logged: the
                // screens simply said there was no data.
                .modelContainer(appEnvironment.modelContainer)
                .task {
                    try? appEnvironment.bootstrap()
                }
                // Hand the sensor back when the app stops being looked at.
                //
                // The firmware refuses to arm, and refuses to start recording,
                // while a phone is connected over GSP — deliberately, so that
                // an HRV test or a download is not interrupted by a recording
                // starting underneath it. That rests on the phone letting go
                // when it is done, and it never did: there is no Bluetooth
                // background mode here, so iOS suspends the app while leaving
                // the link established, and the sensor goes on seeing a client
                // that is not looking. A strap handed to an athlete with the
                // phone still connected therefore never starts a session, and
                // says nothing about why.
                //
                // One exception, and it was written here as "unconditional on
                // purpose": the HRV test. A transfer cannot outlive suspension,
                // which is what made the rule look safe — but a ten-minute
                // measurement can, and the athlete lying still with the screen
                // off is the normal way to take it. Hanging up there does not
                // merely fail to help, it guarantees the loss: the link is gone
                // when the app comes back, so the second position collects
                // nothing at all. The exception cannot strand the link, because
                // the test hands the sensor back itself when it ends.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .background, !appEnvironment.hrvTestInProgress else { return }
                    Task { await appEnvironment.sensorService.disconnect() }
                }
        }
    }
}
