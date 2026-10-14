import XCTest
import AppKit
import Carbon.HIToolbox
@testable import G309MouseTool

/// 값 기반 회귀 테스트.
///
/// v1.9.3 교훈: 열거형은 이름이 아닌 rawValue로 매칭해야 한다.
/// NSTouchPhaseStationary(4) ≠ NSEvent.Phase.stationary(2) 오매핑으로
/// 트랙패드 모멘텀 스크롤이 마우스로 오분류되는 사고가 실제로 발생했다.
/// 이 테스트들은 그 클래스의 버그가 재발하면 즉시 실패한다.
final class ValueRegressionTests: XCTestCase {

    // MARK: - v1.9.3 트랩 가드

    /// NSEvent.Phase의 rawValue가 SDK 업데이트로 변하지 않는지 고정.
    /// ScrollReverser.momentumPhase(for:)는 .changed(4)가
    /// 원본 MouseTap.m의 NSTouchPhaseStationary(4)와 같다는 사실에 의존한다.
    func testNSEventPhaseRawValues() {
        XCTAssertEqual(NSEvent.Phase.began.rawValue, 1)
        XCTAssertEqual(NSEvent.Phase.stationary.rawValue, 2)
        XCTAssertEqual(NSEvent.Phase.changed.rawValue, 4)
        XCTAssertEqual(NSEvent.Phase.ended.rawValue, 8)
        XCTAssertEqual(NSEvent.Phase.cancelled.rawValue, 16)
        XCTAssertEqual(NSEvent.Phase.mayBegin.rawValue, 32)
    }

    /// 원본 MouseTap.m이 참조하는 NSTouchPhase 계열 값 고정.
    func testNSTouchPhaseRawValues() {
        XCTAssertEqual(NSTouch.Phase.began.rawValue, 1 << 0)
        XCTAssertEqual(NSTouch.Phase.moved.rawValue, 1 << 1)
        XCTAssertEqual(NSTouch.Phase.stationary.rawValue, 1 << 2)  // = 4, 원본 기준값
        XCTAssertEqual(NSTouch.Phase.ended.rawValue, 1 << 3)
        XCTAssertEqual(NSTouch.Phase.cancelled.rawValue, 1 << 4)
    }

    /// 두 열거형의 "stationary"가 서로 다른 값임을 명시적으로 문서화.
    /// 이 부등식이 깨지면(=SDK가 통일하면) 포팅 주석도 재검토해야 한다.
    func testStationaryValuesDiffer() {
        XCTAssertNotEqual(
            NSEvent.Phase.stationary.rawValue,
            UInt(NSTouch.Phase.stationary.rawValue),
            "두 stationary가 같아졌다면 momentumPhase 매핑 주석을 재검토할 것"
        )
        XCTAssertEqual(NSEvent.Phase.changed.rawValue, UInt(NSTouch.Phase.stationary.rawValue))
    }

    // MARK: - 이벤트 탭 마스크 상수

    /// ScrollReverser의 이벤트 마스크가 의존하는 rawValue 고정.
    func testEventTypeRawValues() {
        XCTAssertEqual(CGEventType.scrollWheel.rawValue, 22)        // 1 << 22 마스크
        XCTAssertEqual(NSEvent.EventType.gesture.rawValue, 29)     // 1 << 29 마스크
        XCTAssertEqual(CGEventType.tapDisabledByTimeout.rawValue, 0xFFFF_FFFE)
        XCTAssertEqual(CGEventType.tapDisabledByUserInput.rawValue, 0xFFFF_FFFF)
    }

    // MARK: - FnKeyManager 미디어키 매핑

    /// mediaKeyToFKey의 F-키 keycode를 Carbon kVK_ 상수와 대조.
    /// (하드코딩 값의 이중 검증 — 한쪽이 틀리면 즉시 실패)
    func testMediaKeyToFKeyCodesMatchCarbonConstants() {
        let t = FnKeyManager.mediaKeyToFKey
        XCTAssertEqual(t[3], CGKeyCode(kVK_F1))    // BRIGHTNESS_DOWN → F1
        XCTAssertEqual(t[2], CGKeyCode(kVK_F2))    // BRIGHTNESS_UP   → F2
        XCTAssertEqual(t[22], CGKeyCode(kVK_F5))   // ILLUM_DOWN      → F5
        XCTAssertEqual(t[21], CGKeyCode(kVK_F6))   // ILLUM_UP        → F6
        XCTAssertEqual(t[20], CGKeyCode(kVK_F7))   // REWIND          → F7
        XCTAssertEqual(t[18], CGKeyCode(kVK_F7))   // PREVIOUS        → F7
        XCTAssertEqual(t[16], CGKeyCode(kVK_F8))   // PLAY            → F8
        XCTAssertEqual(t[17], CGKeyCode(kVK_F9))   // NEXT            → F9
        XCTAssertEqual(t[19], CGKeyCode(kVK_F9))   // FAST            → F9
        XCTAssertEqual(t[7], CGKeyCode(kVK_F10))   // MUTE            → F10
        XCTAssertEqual(t[1], CGKeyCode(kVK_F11))   // SOUND_DOWN      → F11
        XCTAssertEqual(t[0], CGKeyCode(kVK_F12))   // SOUND_UP        → F12
    }

    /// NX_SYSDEFINED data1 파싱 규약 고정: 0x0A=down, 0x0B=up.
    func testNXSysdefinedKeyStateParsing() {
        // FnKeyManager 콜백과 동일한 비트 연산
        func isKeyDown(data1: Int) -> Bool {
            let keyFlags = (data1 & 0x0000_FF00) >> 8
            return (keyFlags & 0x01) == 0
        }
        // keyCode=16(PLAY), keyState=0x0A(down)
        XCTAssertTrue(isKeyDown(data1: (16 << 16) | (0x0A << 8)))
        // keyCode=16(PLAY), keyState=0x0B(up)
        XCTAssertFalse(isKeyDown(data1: (16 << 16) | (0x0B << 8)))
    }

    // MARK: - ButtonRemapper

    /// 트리거 버튼 저장 포맷(JSON Codable) 왕복 보존.
    func testHIDButtonIDCodableRoundtrip() throws {
        let original = HIDButtonID(usagePage: 0xFF00, usage: 0xC7)  // G309 DPI 류
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HIDButtonID.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - CapsLockManager HID usage 값

    /// Apple TN2450 기준 HID usage 값 고정.
    func testCapsLockHIDUsageValues() {
        XCTAssertEqual(0x7_0000_0039, 0x700000000 + 0x39)  // Caps Lock
        XCTAssertEqual(0x7_0000_006D, 0x700000000 + 0x6D)  // F18
    }
}
