import Testing
@testable import LiquidGlassDemo

@Suite struct TrackpadPagingGestureTests {
    @Test func accumulatesHorizontalMovementForInteractivePaging() {
        var gesture = TrackpadPagingGestureState()
        gesture.begin()

        #expect(gesture.consume(deltaX: -24, deltaY: 2) == -24)
        #expect(gesture.consume(deltaX: -40, deltaY: 3) == -64)

        gesture.begin()
        #expect(gesture.consume(deltaX: 61, deltaY: 4) == 61)
    }

    @Test func ignoresPredominantlyVerticalMovement() {
        var gesture = TrackpadPagingGestureState()
        gesture.begin()

        #expect(gesture.consume(deltaX: 70, deltaY: 90) == nil)
        #expect(gesture.accumulatedX == 0)
    }
}
