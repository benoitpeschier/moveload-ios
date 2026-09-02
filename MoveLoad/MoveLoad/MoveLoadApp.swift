//
//  MoveLoadApp.swift
//  MoveLoad
//
//  Created by Benoît PESCHIER on 30/07/2026.
//

import SwiftUI
import SensorKit

@main
struct MoveLoadApp: App {
    @State private var appEnvironment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appEnvironment)
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
                // Unconditional on purpose. A transfer cannot outlive
                // suspension anyway without a background mode, so there is
                // nothing here to protect — and a rule with an exception is a
                // rule that will have the exception hold the link one day.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .background else { return }
                    Task { await appEnvironment.sensorService.disconnect() }
                }
        }
    }
}
