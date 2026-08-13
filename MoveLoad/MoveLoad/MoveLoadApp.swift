//
//  MoveLoadApp.swift
//  MoveLoad
//
//  Created by Benoît PESCHIER on 30/07/2026.
//

import SwiftUI

@main
struct MoveLoadApp: App {
    @State private var appEnvironment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appEnvironment)
                .task {
                    try? appEnvironment.bootstrap()
                }
        }
    }
}
