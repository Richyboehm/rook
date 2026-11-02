import AppKit

/// Inoffizielle Funktionen aus Apples privatem SkyLight-Framework (dem Fenstersystem).
/// Damit legen wir das Fenster in einen eigenen Space mit sehr hoher Ebene, der auch
/// über dem Sperrbildschirm gezeichnet wird. Nicht dokumentiert, kann sich mit jedem
/// macOS-Update ändern. Fehlen die Funktionen, passiert einfach nichts.
enum SkyLight {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias SpaceAddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    nonisolated(unsafe) private static var space: Int32?

    private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// Ebenen der Spaces im Fenstersystem (aus SkyLight):
    /// 100 Einrichtungsassistent, 200 Passwortabfragen, 300 Sperrbildschirm,
    /// 400 Mitteilungen über dem Sperrbildschirm.
    static let aboveLockScreenLevel: Int32 = 400

    /// Verschiebt das Fenster in den Space über dem Sperrbildschirm.
    /// Das Fenster muss dafür bereits auf dem Bildschirm sein (eine windowNumber haben).
    @discardableResult
    static func moveAboveLockScreen(_ window: NSWindow, level: Int32 = aboveLockScreenLevel) -> Bool {
        guard let mainConnection = symbol("SLSMainConnectionID", as: MainConnectionID.self),
              let create = symbol("SLSSpaceCreate", as: SpaceCreate.self),
              let setLevel = symbol("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self),
              let show = symbol("SLSShowSpaces", as: ShowSpaces.self),
              let add = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", as: SpaceAddWindowsAndRemoveFromSpaces.self)
        else {
            Log.write("SkyLight-Funktionen nicht gefunden")
            return false
        }
        let connection = mainConnection()
        if space == nil {
            let newSpace = create(connection, 1, 0)
            _ = setLevel(connection, newSpace, level)
            _ = show(connection, [newSpace] as CFArray)
            space = newSpace
        }
        let result = add(connection, space!, [window.windowNumber] as CFArray, 7)
        Log.write("SkyLight: Fenster \(window.windowNumber) in Space \(space!) verschoben (Ergebnis \(result))")
        return true
    }
}
