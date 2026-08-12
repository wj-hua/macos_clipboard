import AppKit
import XCTest
@testable import CommonClipboard

final class ScrollWheelNavigationRecognizerTests: XCTestCase {
    func testDiscreteVerticalWheelMovesItemSelectionInBothDirections() {
        var recognizer = ScrollWheelNavigationRecognizer()

        let upward = recognizer.update(
            horizontalDelta: 0,
            verticalDelta: 1,
            hasPreciseScrollingDeltas: false,
            timestamp: 1
        )
        XCTAssertEqual(upward?.axis, .items)
        XCTAssertEqual(upward?.offset, -1)

        let downward = recognizer.update(
            horizontalDelta: 0,
            verticalDelta: -1,
            hasPreciseScrollingDeltas: false,
            timestamp: 1.3
        )
        XCTAssertEqual(downward?.axis, .items)
        XCTAssertEqual(downward?.offset, 1)
    }

    func testDiscreteHorizontalWheelMovesTagSelectionInBothDirections() {
        var recognizer = ScrollWheelNavigationRecognizer()

        let leftward = recognizer.update(
            horizontalDelta: 1,
            verticalDelta: 0,
            hasPreciseScrollingDeltas: false,
            timestamp: 1
        )
        XCTAssertEqual(leftward?.axis, .tags)
        XCTAssertEqual(leftward?.offset, 1)

        let rightward = recognizer.update(
            horizontalDelta: -1,
            verticalDelta: 0,
            hasPreciseScrollingDeltas: false,
            timestamp: 1.3
        )
        XCTAssertEqual(rightward?.axis, .tags)
        XCTAssertEqual(rightward?.offset, -1)
    }

    func testDominantDeltaChoosesOnlyOneAxis() {
        var recognizer = ScrollWheelNavigationRecognizer()

        let mostlyHorizontal = recognizer.update(
            horizontalDelta: -3,
            verticalDelta: 1,
            hasPreciseScrollingDeltas: false,
            timestamp: 1
        )
        XCTAssertEqual(mostlyHorizontal?.axis, .tags)

        let mostlyVertical = recognizer.update(
            horizontalDelta: 1,
            verticalDelta: -3,
            hasPreciseScrollingDeltas: false,
            timestamp: 1.3
        )
        XCTAssertEqual(mostlyVertical?.axis, .items)
    }

    func testPreciseScrollingAccumulatesBeforeMovingSelection() {
        var recognizer = ScrollWheelNavigationRecognizer()
        let halfStep = ScrollWheelNavigationRecognizer.preciseStepThreshold / 2

        XCTAssertNil(
            recognizer.update(
                horizontalDelta: 0,
                verticalDelta: -halfStep,
                hasPreciseScrollingDeltas: true,
                phase: .began,
                timestamp: 1
            )
        )

        let navigation = recognizer.update(
            horizontalDelta: 0,
            verticalDelta: -halfStep,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            timestamp: 1.01
        )
        XCTAssertEqual(navigation?.axis, .items)
        XCTAssertEqual(navigation?.offset, 1)
    }

    func testPreciseGestureLocksItsInitialAxis() {
        var recognizer = ScrollWheelNavigationRecognizer()

        _ = recognizer.update(
            horizontalDelta: 0,
            verticalDelta: -6,
            hasPreciseScrollingDeltas: true,
            phase: .began,
            timestamp: 1
        )
        let navigation = recognizer.update(
            horizontalDelta: -30,
            verticalDelta: -6,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            timestamp: 1.01
        )

        XCTAssertEqual(navigation?.axis, .items)
        XCTAssertEqual(navigation?.offset, 1)
    }

    func testMomentumDoesNotMoveSelection() {
        var recognizer = ScrollWheelNavigationRecognizer()

        let navigation = recognizer.update(
            horizontalDelta: 0,
            verticalDelta: -50,
            hasPreciseScrollingDeltas: true,
            momentumPhase: .began,
            timestamp: 1
        )

        XCTAssertNil(navigation)
    }

    func testRapidWheelEventsAreRateLimitedWithoutQueuedMovement() {
        var recognizer = ScrollWheelNavigationRecognizer()

        XCTAssertNotNil(
            recognizer.update(
                horizontalDelta: 0,
                verticalDelta: -1,
                hasPreciseScrollingDeltas: false,
                timestamp: 1
            )
        )
        XCTAssertNil(
            recognizer.update(
                horizontalDelta: 0,
                verticalDelta: -1,
                hasPreciseScrollingDeltas: false,
                timestamp: 1.05
            )
        )

        let nextAllowedStep = recognizer.update(
            horizontalDelta: 0,
            verticalDelta: -1,
            hasPreciseScrollingDeltas: false,
            timestamp: 1 + ScrollWheelNavigationRecognizer.minimumStepInterval + 0.001
        )
        XCTAssertEqual(nextAllowedStep?.offset, 1)
    }

    func testLargePreciseDeltaMovesOnlyOneStep() {
        var recognizer = ScrollWheelNavigationRecognizer()

        let navigation = recognizer.update(
            horizontalDelta: 0,
            verticalDelta: -ScrollWheelNavigationRecognizer.preciseStepThreshold * 5,
            hasPreciseScrollingDeltas: true,
            phase: .began,
            timestamp: 1
        )

        XCTAssertEqual(navigation?.axis, .items)
        XCTAssertEqual(navigation?.offset, 1)
    }
}
