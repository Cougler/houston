import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// `.regular` (was `.accessory`): Houston now has a real desktop window, which
// needs a Dock presence, normal key-window activation, and — most importantly
// for the embedded terminal — a main menu, since ⌘C/⌘V inside the terminal are
// dispatched through the Edit menu. The menubar status item is unaffected.
app.setActivationPolicy(.regular)
// System / Light / Dark, from settings (nil follows the system). All chrome
// colors are dynamic (`Theme`), so the override restyles everything.
app.appearance = HoustonSettings.read().nsAppearance
MainMenu.install(into: app)
app.run()
