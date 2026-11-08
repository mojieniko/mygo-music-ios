// MyGoMusicApp.swift
// MyGo Music iOS 版应用入口

#if canImport(MyGoMusicCore)
import MyGoMusicCore
#endif
#if canImport(MyGoMusicUI)
import MyGoMusicUI
#endif
import SwiftUI

@main
struct MyGoMusicApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appModel)
        }
    }
}
