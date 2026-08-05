import CoreGraphics
import XCTest
@testable import CommonClipboard

final class WindowDragRecognizerTests: XCTestCase {
    private let startFrame = CGRect(x: 100, y: 200, width: 500, height: 400)
    private let pressPoint = CGPoint(x: 300, y: 400)

    func testHoldingLongEnoughMovesTheWindowByThePointerOffset() {
        var recognizer = WindowDragRecognizer(minimumPressDuration: 0.4, movementTolerance: 5)

        XCTAssertNil(
            recognizer.update(pointerLocation: pressPoint, timestamp: 0, windowFrame: startFrame)
        )
        XCTAssertFalse(recognizer.isDragging)

        let origin = recognizer.update(
            pointerLocation: CGPoint(x: pressPoint.x + 30, y: pressPoint.y - 20),
            timestamp: 0.5,
            windowFrame: startFrame
        )

        XCTAssertEqual(origin, CGPoint(x: 130, y: 180))
        XCTAssertTrue(recognizer.isDragging)
    }

    /// 回归：位移必须锚定在按下时的窗口位置和鼠标屏幕位置上。
    /// 若改用窗口坐标系的 translation，窗口移动后同一鼠标位置算出的位移会缩回去，
    /// 窗口就会在两个位置之间逐帧抖动。
    func testDraggingStaysStableWhileTheWindowKeepsMovingUnderTheCursor() throws {
        var recognizer = WindowDragRecognizer(minimumPressDuration: 0.4, movementTolerance: 5)

        _ = recognizer.update(pointerLocation: pressPoint, timestamp: 0, windowFrame: startFrame)

        var windowFrame = startFrame
        var origins: [CGPoint] = []

        // 鼠标持续右移，每个事件之后窗口都真的被移动过。
        for step in 1...4 {
            let pointer = CGPoint(x: pressPoint.x + CGFloat(step) * 10, y: pressPoint.y)
            let origin = try XCTUnwrap(
                recognizer.update(
                    pointerLocation: pointer,
                    timestamp: 0.5 + Double(step) * 0.05,
                    windowFrame: windowFrame
                )
            )
            origins.append(origin)
            windowFrame.origin = origin
        }

        XCTAssertEqual(origins.map(\.x), [110, 120, 130, 140])
        XCTAssertEqual(origins.map(\.y), [200, 200, 200, 200])

        // 鼠标停住不动时，窗口必须停在原地，而不是弹回按下时的位置。
        let held = recognizer.update(
            pointerLocation: CGPoint(x: pressPoint.x + 40, y: pressPoint.y),
            timestamp: 0.8,
            windowFrame: windowFrame
        )
        XCTAssertEqual(held, CGPoint(x: 140, y: 200))
    }

    func testMovingBeforeTheLongPressCompletesCancelsTheWholePress() {
        var recognizer = WindowDragRecognizer(minimumPressDuration: 0.4, movementTolerance: 5)

        XCTAssertNil(
            recognizer.update(pointerLocation: pressPoint, timestamp: 0, windowFrame: startFrame)
        )
        XCTAssertNil(
            recognizer.update(
                pointerLocation: CGPoint(x: pressPoint.x + 20, y: pressPoint.y),
                timestamp: 0.1,
                windowFrame: startFrame
            )
        )

        // 一旦被判定成快速拖拽，后续即使超过长按时长也不再接管窗口。
        XCTAssertNil(
            recognizer.update(
                pointerLocation: CGPoint(x: pressPoint.x + 60, y: pressPoint.y),
                timestamp: 0.9,
                windowFrame: startFrame
            )
        )
        XCTAssertFalse(recognizer.isDragging)
    }

    func testJitterWithinToleranceKeepsTheLongPressAlive() {
        var recognizer = WindowDragRecognizer(minimumPressDuration: 0.4, movementTolerance: 5)

        XCTAssertNil(
            recognizer.update(pointerLocation: pressPoint, timestamp: 0, windowFrame: startFrame)
        )
        XCTAssertNil(
            recognizer.update(
                pointerLocation: CGPoint(x: pressPoint.x + 3, y: pressPoint.y),
                timestamp: 0.1,
                windowFrame: startFrame
            )
        )

        let origin = recognizer.update(
            pointerLocation: CGPoint(x: pressPoint.x + 3, y: pressPoint.y),
            timestamp: 0.45,
            windowFrame: startFrame
        )

        XCTAssertEqual(origin, CGPoint(x: 103, y: 200))
    }

    func testEndingThePressAllowsANewLongPressToStart() {
        var recognizer = WindowDragRecognizer(minimumPressDuration: 0.4, movementTolerance: 5)

        _ = recognizer.update(pointerLocation: pressPoint, timestamp: 0, windowFrame: startFrame)
        _ = recognizer.update(
            pointerLocation: CGPoint(x: pressPoint.x + 20, y: pressPoint.y),
            timestamp: 0.1,
            windowFrame: startFrame
        )
        recognizer.end()

        XCTAssertFalse(recognizer.isDragging)
        XCTAssertNil(
            recognizer.update(pointerLocation: pressPoint, timestamp: 5, windowFrame: startFrame)
        )

        let origin = recognizer.update(
            pointerLocation: CGPoint(x: pressPoint.x, y: pressPoint.y - 25),
            timestamp: 5.6,
            windowFrame: startFrame
        )

        XCTAssertEqual(origin, CGPoint(x: 100, y: 175))
    }
}
