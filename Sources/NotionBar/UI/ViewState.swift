import SwiftUI

/// Use `@ViewState` wherever you would write `@State`.
///
/// On the macOS 27 SDK, `@State` is a macro, and the compiler plugin behind it only ships inside
/// Xcode. Naming the property wrapper through this alias picks the plain `State` struct instead,
/// so the app also builds with just the Command Line Tools (`./build.sh`). It behaves exactly the same.
typealias ViewState<Value> = SwiftUI.State<Value>
