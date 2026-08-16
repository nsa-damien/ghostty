@testable import Ghostty
import Testing

struct SurfaceViewAppKitTests {
    @Test(arguments: [
        ("\u{0008}", true),
        ("\u{001F}", true),
        ("\u{007F}", false),
        (" ", false),
        ("h", false),
        ("", false),
        ("\u{0009}x", false),
        ("\u{0009}\u{0009}", false),
    ])
    func suppressesOnlySingleC0ControlTextWhileComposing(
        text: String,
        expected: Bool
    ) {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                text,
                composing: true
            ) == expected
        )
    }

    @Test func doesNotSuppressControlTextWhenNotComposing() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                "\u{0008}",
                composing: false
            ) == false
        )
    }

    @Test func doesNotSuppressMissingText() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                nil,
                composing: true
            ) == false
        )
    }

    @Test(arguments: [
        (true, true, false, true),
        (false, true, false, false),
        (true, false, false, false),
        (true, true, true, false),
    ])
    func synchronizesOwningControllerOnlyForNewFirstResponder(
        ownsSurface: Bool,
        isFirstResponder: Bool,
        isAlreadyFocused: Bool,
        expected: Bool
    ) {
        #expect(
            Ghostty.SurfaceView.shouldSynchronizeOwningControllerFocus(
                ownsSurface: ownsSurface,
                isFirstResponder: isFirstResponder,
                isAlreadyFocused: isAlreadyFocused
            ) == expected
        )
    }

    @Test(arguments: [
        (true, false, true, false, true),
        (false, false, true, false, false),
        (true, true, true, false, false),
        (true, false, false, false, false),
        (true, false, true, true, false),
    ])
    func followsMouseOnlyForEligibleOwningController(
        ownsSurface: Bool,
        commandPaletteIsShowing: Bool,
        isKeyWindow: Bool,
        isFocused: Bool,
        expected: Bool
    ) {
        #expect(
            Ghostty.SurfaceView.shouldFocusOnMouseMove(
                ownsSurface: ownsSurface,
                commandPaletteIsShowing: commandPaletteIsShowing,
                isKeyWindow: isKeyWindow,
                isFocused: isFocused,
                focusFollowsMouse: true
            ) == expected
        )
    }
}
