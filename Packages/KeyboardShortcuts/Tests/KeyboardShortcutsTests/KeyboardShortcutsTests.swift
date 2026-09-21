import Testing
import Foundation
import AppKit
import Carbon.HIToolbox
@testable import KeyboardShortcuts

@Suite("KeyboardShortcuts Tests", .serialized)
struct KeyboardShortcutsTests {
	init() {
		UserDefaults.standard.removeAllKeyboardShortcuts()
	}

	@Test("Event handler installation failure rolls back registered hot key")
	func eventHandlerInstallationFailureRollsBackRegisteredHotKey() throws {
		let failureStatus: OSStatus = -9875
		let previousRegistrar = CarbonKeyboardShortcuts.hotKeyRegistrar
		let previousInstaller = CarbonKeyboardShortcuts.eventHandlerInstaller
		let registrar = CapturingSystemCarbonHotKeyRegistrar()
		CarbonKeyboardShortcuts.hotKeyRegistrar = registrar
		CarbonKeyboardShortcuts.eventHandlerInstaller = FailingCarbonEventHandlerInstaller(
			status: failureStatus
		)

		let name = KeyboardShortcuts.Name("eventHandlerInstallationFailure")
		let shortcut = KeyboardShortcuts.Shortcut(
			.f13,
			modifiers: [.command, .option, .control, .shift]
		)
		KeyboardShortcuts.onKeyUp(for: name) {}
		defer {
			KeyboardShortcuts.removeHandler(for: name)
			KeyboardShortcuts.setShortcut(nil, for: name)
			CarbonKeyboardShortcuts.hotKeyRegistrar = previousRegistrar
			CarbonKeyboardShortcuts.eventHandlerInstaller = previousInstaller
		}

		KeyboardShortcuts.setShortcut(shortcut, for: name)

		#expect(KeyboardShortcuts.registrationResult(for: name) == .failed(status: failureStatus))
		#expect(!KeyboardShortcuts.isEnabled(for: name))
		#expect(try registrar.dispatchKeyUp(for: shortcut) == OSStatus(eventNotHandledErr))
	}

	@Test("Registration result preserves underlying Carbon failure")
	func registrationResultPreservesUnderlyingCarbonFailure() {
		let status: OSStatus = -9876
		let previousRegistrar = CarbonKeyboardShortcuts.hotKeyRegistrar
		let registrar = FailingCarbonHotKeyRegistrar(status: status)
		CarbonKeyboardShortcuts.hotKeyRegistrar = registrar
		defer { CarbonKeyboardShortcuts.hotKeyRegistrar = previousRegistrar }

		let name = KeyboardShortcuts.Name("registrationResultPreservesUnderlyingCarbonFailure")
		let candidate = KeyboardShortcuts.Shortcut(.f20, modifiers: [.command, .option])
		let previous = KeyboardShortcuts.Shortcut(.f19, modifiers: [.command, .option])
		KeyboardShortcuts.onKeyUp(for: name) {}
		KeyboardShortcuts.setShortcut(candidate, for: name)

		#expect(KeyboardShortcuts.getShortcut(for: name) == candidate)
		#expect(KeyboardShortcuts.registrationResult(for: name) == .failed(status: status))
		#expect(!KeyboardShortcuts.isEnabled(for: name))

		KeyboardShortcuts.setShortcut(previous, for: name)
		#expect(KeyboardShortcuts.getShortcut(for: name) == previous)
		#expect(registrar.attemptCount == 2, "rollback must make a fresh registration attempt")
	}

	@Test("Conflict rollback preserves every shortcut owner and dispatch path")
	func conflictRollbackPreservesEveryShortcutOwnerAndDispatchPath() throws {
		let previousRegistrar = CarbonKeyboardShortcuts.hotKeyRegistrar
		let registrar = CapturingSystemCarbonHotKeyRegistrar()
		CarbonKeyboardShortcuts.hotKeyRegistrar = registrar

		let firstName = KeyboardShortcuts.Name("conflictRollbackPreservesFirstOwner")
		let secondName = KeyboardShortcuts.Name("conflictRollbackPreservesSecondOwner")
		let firstShortcut = KeyboardShortcuts.Shortcut(
			.f16,
			modifiers: [.command, .option, .control, .shift]
		)
		let secondShortcut = KeyboardShortcuts.Shortcut(
			.f17,
			modifiers: [.command, .option, .control, .shift]
		)
		var firstDispatchCount = 0
		var secondDispatchCount = 0

		KeyboardShortcuts.onKeyUp(for: firstName) {
			firstDispatchCount += 1
		}
		KeyboardShortcuts.onKeyUp(for: secondName) {
			secondDispatchCount += 1
		}
		defer {
			KeyboardShortcuts.removeHandler(for: firstName)
			KeyboardShortcuts.removeHandler(for: secondName)
			KeyboardShortcuts.setShortcut(nil, for: firstName)
			KeyboardShortcuts.setShortcut(nil, for: secondName)
			CarbonKeyboardShortcuts.hotKeyRegistrar = previousRegistrar
		}

		KeyboardShortcuts.setShortcut(firstShortcut, for: firstName)
		KeyboardShortcuts.setShortcut(secondShortcut, for: secondName)

		for expectedDispatchCount in 1...2 {
			// Mirrors Recorder's transient canonical write followed by app rollback.
			KeyboardShortcuts.setShortcut(secondShortcut, for: firstName)
			KeyboardShortcuts.setShortcut(firstShortcut, for: firstName)

			#expect(KeyboardShortcuts.isEnabled(for: firstName))
			#expect(KeyboardShortcuts.isEnabled(for: secondName))
			#expect(KeyboardShortcuts.registrationResult(for: firstName) == .registered)
			#expect(KeyboardShortcuts.registrationResult(for: secondName) == .registered)

			#expect(try registrar.dispatchKeyUp(for: firstShortcut) == noErr)
			#expect(try registrar.dispatchKeyUp(for: secondShortcut) == noErr)
			#expect(firstDispatchCount == expectedDispatchCount)
			#expect(secondDispatchCount == expectedDispatchCount)
		}

		KeyboardShortcuts.setShortcut(nil, for: firstName)
		#expect(!KeyboardShortcuts.isEnabled(for: firstName))
		#expect(KeyboardShortcuts.isEnabled(for: secondName))
		#expect(try registrar.dispatchKeyUp(for: secondShortcut) == noErr)
		#expect(secondDispatchCount == 3)
	}

	@Test("Soft registration failure disables dispatch and later retry recovers")
	func softRegistrationFailureDisablesDispatchAndLaterRetryRecovers() throws {
		let failureStatus: OSStatus = -9876
		let previousRegistrar = CarbonKeyboardShortcuts.hotKeyRegistrar
		let registrar = CapturingSystemCarbonHotKeyRegistrar()
		CarbonKeyboardShortcuts.hotKeyRegistrar = registrar

		let name = KeyboardShortcuts.Name("softRegistrationFailureRecovers")
		let shortcut = KeyboardShortcuts.Shortcut(
			.f15,
			modifiers: [.command, .option, .control, .shift]
		)
		var dispatchCount = 0
		KeyboardShortcuts.onKeyUp(for: name) {
			dispatchCount += 1
		}
		defer {
			KeyboardShortcuts.isEnabled = true
			KeyboardShortcuts.removeHandler(for: name)
			KeyboardShortcuts.setShortcut(nil, for: name)
			CarbonKeyboardShortcuts.hotKeyRegistrar = previousRegistrar
		}

		KeyboardShortcuts.setShortcut(shortcut, for: name)
		#expect(KeyboardShortcuts.isEnabled(for: name))
		#expect(try registrar.dispatchKeyUp(for: shortcut) == noErr)
		#expect(dispatchCount == 1)

		KeyboardShortcuts.isEnabled = false
		registrar.failNextRegistration(with: failureStatus)
		KeyboardShortcuts.isEnabled = true

		#expect(!KeyboardShortcuts.isEnabled(for: name))
		#expect(KeyboardShortcuts.registrationResult(for: name) == .failed(status: failureStatus))
		#expect(try registrar.dispatchKeyUp(for: shortcut) == OSStatus(eventNotHandledErr))
		#expect(dispatchCount == 1)

		KeyboardShortcuts.isEnabled = false
		KeyboardShortcuts.isEnabled = true

		#expect(KeyboardShortcuts.isEnabled(for: name))
		#expect(KeyboardShortcuts.registrationResult(for: name) == .registered)
		#expect(try registrar.dispatchKeyUp(for: shortcut) == noErr)
		#expect(dispatchCount == 2)
		#expect(registrar.registrationAttemptCount(for: shortcut) == 3)
	}

	@Test("Raw menu dispatch follows authoritative soft registration state")
	func rawMenuDispatchFollowsAuthoritativeSoftRegistrationState() throws {
		let failureStatus: OSStatus = -9876
		let previousRegistrar = CarbonKeyboardShortcuts.hotKeyRegistrar
		let registrar = CapturingSystemCarbonHotKeyRegistrar()
		CarbonKeyboardShortcuts.hotKeyRegistrar = registrar

		let name = KeyboardShortcuts.Name("rawMenuDispatchFollowsRegistrationState")
		let shortcut = KeyboardShortcuts.Shortcut(
			.f14,
			modifiers: [.command, .option, .control, .shift]
		)
		var dispatchCount = 0
		KeyboardShortcuts.onKeyUp(for: name) {
			dispatchCount += 1
		}
		defer {
			NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
			KeyboardShortcuts.removeHandler(for: name)
			KeyboardShortcuts.setShortcut(nil, for: name)
			CarbonKeyboardShortcuts.hotKeyRegistrar = previousRegistrar
		}

		KeyboardShortcuts.setShortcut(shortcut, for: name)
		NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)
		#expect(try dispatchRawMenuKeyUp(for: shortcut) == noErr)
		#expect(dispatchCount == 1)

		registrar.failNextRegistration(with: failureStatus)
		NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
		#expect(!KeyboardShortcuts.isEnabled(for: name))
		#expect(KeyboardShortcuts.registrationResult(for: name) == .failed(status: failureStatus))

		NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)
		#expect(try dispatchRawMenuKeyUp(for: shortcut) == OSStatus(eventNotHandledErr))
		#expect(dispatchCount == 1)

		NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
		#expect(KeyboardShortcuts.isEnabled(for: name))
		#expect(KeyboardShortcuts.registrationResult(for: name) == .registered)

		NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)
		#expect(try dispatchRawMenuKeyUp(for: shortcut) == noErr)
		#expect(dispatchCount == 2)
		#expect(registrar.registrationAttemptCount(for: shortcut) == 3)
	}

	@Test("Set shortcut and reset")
	func testSetShortcutAndReset() throws {
		let defaultShortcut = KeyboardShortcuts.Shortcut(.c)
		let shortcut1 = KeyboardShortcuts.Shortcut(.a)
		let shortcut2 = KeyboardShortcuts.Shortcut(.b)

		let shortcutName1 = KeyboardShortcuts.Name("testSetShortcutAndReset1")
		let shortcutName2 = KeyboardShortcuts.Name("testSetShortcutAndReset2", default: defaultShortcut)

		KeyboardShortcuts.setShortcut(shortcut1, for: shortcutName1)
		KeyboardShortcuts.setShortcut(shortcut2, for: shortcutName2)

		#expect(KeyboardShortcuts.getShortcut(for: shortcutName1) == shortcut1)
		#expect(KeyboardShortcuts.getShortcut(for: shortcutName2) == shortcut2)

		KeyboardShortcuts.reset(shortcutName1, shortcutName2)

		#expect(KeyboardShortcuts.getShortcut(for: shortcutName1) == nil)
		#expect(KeyboardShortcuts.getShortcut(for: shortcutName2) == defaultShortcut)
	}

	@Test("Shortcut creation")
	func testShortcutCreation() throws {
		let shortcut1 = KeyboardShortcuts.Shortcut(.a)
		let shortcut2 = KeyboardShortcuts.Shortcut(.a, modifiers: [.command])
		let shortcut3 = KeyboardShortcuts.Shortcut(.a, modifiers: [.command, .shift])

		#expect(shortcut1.key == .a)
		#expect(shortcut1.modifiers == [])

		#expect(shortcut2.key == .a)
		#expect(shortcut2.modifiers == [.command])

		#expect(shortcut3.key == .a)
		#expect(shortcut3.modifiers == [.command, .shift])
	}

	@Test("Shortcut equality")
	func testShortcutEquality() throws {
		let shortcut1 = KeyboardShortcuts.Shortcut(.a, modifiers: [.command])
		let shortcut2 = KeyboardShortcuts.Shortcut(.a, modifiers: [.command])
		let shortcut3 = KeyboardShortcuts.Shortcut(.b, modifiers: [.command])
		let shortcut4 = KeyboardShortcuts.Shortcut(.a, modifiers: [.option])

		#expect(shortcut1 == shortcut2)
		#expect(shortcut1 != shortcut3)
		#expect(shortcut1 != shortcut4)

		// Test hashability
		let set = Set([shortcut1, shortcut2, shortcut3, shortcut4])
		#expect(set.count == 3) // shortcut1 and shortcut2 are equal
	}

	@Test("Name equality")
	func testNameEquality() throws {
		let name1 = KeyboardShortcuts.Name("test")
		let name2 = KeyboardShortcuts.Name("test")
		let name3 = KeyboardShortcuts.Name("different")

		#expect(name1 == name2)
		#expect(name1 != name3)
	}

	@Test("Name with default")
	func testNameWithDefault() throws {
		let defaultShortcut = KeyboardShortcuts.Shortcut(.space)
		let name = KeyboardShortcuts.Name("testDefault", default: defaultShortcut)

		// Should return default when no value is set
		#expect(KeyboardShortcuts.getShortcut(for: name) == defaultShortcut)

		// Setting a value should override the default
		let customShortcut = KeyboardShortcuts.Shortcut(.tab)
		KeyboardShortcuts.setShortcut(customShortcut, for: name)
		#expect(KeyboardShortcuts.getShortcut(for: name) == customShortcut)

		// Resetting should restore the default
		KeyboardShortcuts.reset(name)
		#expect(KeyboardShortcuts.getShortcut(for: name) == defaultShortcut)
	}

	@Test("Shortcut persistence")
	func testShortcutPersistence() throws {
		let name = KeyboardShortcuts.Name("persistenceTest")
		let shortcut = KeyboardShortcuts.Shortcut(.f1, modifiers: [.command, .option])

		KeyboardShortcuts.setShortcut(shortcut, for: name)
		#expect(KeyboardShortcuts.getShortcut(for: name) == shortcut)

		// Simulate app restart by creating new name with same identifier
		let sameName = KeyboardShortcuts.Name("persistenceTest")
		#expect(KeyboardShortcuts.getShortcut(for: sameName) == shortcut)
	}

	@Test("Multiple shortcuts")
	func testMultipleShortcuts() throws {
		let name1 = KeyboardShortcuts.Name("multi1")
		let name2 = KeyboardShortcuts.Name("multi2")
		let name3 = KeyboardShortcuts.Name("multi3")

		let shortcut1 = KeyboardShortcuts.Shortcut(.a, modifiers: [.command])
		let shortcut2 = KeyboardShortcuts.Shortcut(.b, modifiers: [.option])
		let shortcut3 = KeyboardShortcuts.Shortcut(.c, modifiers: [.shift])

		KeyboardShortcuts.setShortcut(shortcut1, for: name1)
		KeyboardShortcuts.setShortcut(shortcut2, for: name2)
		KeyboardShortcuts.setShortcut(shortcut3, for: name3)

		#expect(KeyboardShortcuts.getShortcut(for: name1) == shortcut1)
		#expect(KeyboardShortcuts.getShortcut(for: name2) == shortcut2)
		#expect(KeyboardShortcuts.getShortcut(for: name3) == shortcut3)
	}

	@Test("Removing shortcuts")
	func testRemovingShortcuts() throws {
		let name = KeyboardShortcuts.Name("removeTest")
		let shortcut = KeyboardShortcuts.Shortcut(.delete, modifiers: [.command])

		KeyboardShortcuts.setShortcut(shortcut, for: name)
		#expect(KeyboardShortcuts.getShortcut(for: name) == shortcut)

		KeyboardShortcuts.setShortcut(nil, for: name)
		#expect(KeyboardShortcuts.getShortcut(for: name) == nil)
	}

	@Test("Empty modifiers")
	func testEmptyModifiers() throws {
		let shortcut = KeyboardShortcuts.Shortcut(.a, modifiers: [])
		#expect(shortcut.modifiers.isEmpty)
		#expect(shortcut.modifiers.ks_symbolicRepresentation == "")
	}

	@Test("Function keys")
	func testFunctionKeys() throws {
		let f1 = KeyboardShortcuts.Shortcut(.f1)
		let f12 = KeyboardShortcuts.Shortcut(.f12)
		let f20 = KeyboardShortcuts.Shortcut(.f20)

		#expect(f1.key == .f1)
		#expect(f12.key == .f12)
		#expect(f20.key == .f20)
	}

	@Test("Special keys")
	func testSpecialKeys() throws {
		let space = KeyboardShortcuts.Shortcut(.space)
		let tab = KeyboardShortcuts.Shortcut(.tab)
		let escape = KeyboardShortcuts.Shortcut(.escape)
		let delete = KeyboardShortcuts.Shortcut(.delete)
		let returnKey = KeyboardShortcuts.Shortcut(.return)

		#expect(space.key == .space)
		#expect(tab.key == .tab)
		#expect(escape.key == .escape)
		#expect(delete.key == .delete)
		#expect(returnKey.key == .return)
	}

	@Test("Keypad keys")
	func testKeypadKeys() throws {
		let keypad0 = KeyboardShortcuts.Shortcut(.keypad0)
		let keypad9 = KeyboardShortcuts.Shortcut(.keypad9)
		let keypadPlus = KeyboardShortcuts.Shortcut(.keypadPlus)
		let keypadEnter = KeyboardShortcuts.Shortcut(.keypadEnter)

		#expect(keypad0.key == .keypad0)
		#expect(keypad9.key == .keypad9)
		#expect(keypadPlus.key == .keypadPlus)
		#expect(keypadEnter.key == .keypadEnter)
	}

	@Test("Arrow keys")
	func testArrowKeys() throws {
		let up = KeyboardShortcuts.Shortcut(.upArrow, modifiers: [.command])
		let down = KeyboardShortcuts.Shortcut(.downArrow, modifiers: [.command])
		let left = KeyboardShortcuts.Shortcut(.leftArrow, modifiers: [.command])
		let right = KeyboardShortcuts.Shortcut(.rightArrow, modifiers: [.command])

		#expect(up.key == .upArrow)
		#expect(down.key == .downArrow)
		#expect(left.key == .leftArrow)
		#expect(right.key == .rightArrow)
		#expect(up.modifiers == [.command])
	}

	@Test("Name identity")
	func testNameIdentity() throws {
		let name1 = KeyboardShortcuts.Name("sameName")
		let name2 = KeyboardShortcuts.Name("sameName")
		#expect(name1 == name2)
		#expect(name1.hashValue == name2.hashValue)
	}

	@Test("Default values")
	func testDefaultValues() throws {
		let defaultShortcut = KeyboardShortcuts.Shortcut(.d, modifiers: [.command])
		let nameWithDefault = KeyboardShortcuts.Name("withDefault", default: defaultShortcut)
		let nameWithoutDefault = KeyboardShortcuts.Name("withoutDefault")

		#expect(KeyboardShortcuts.getShortcut(for: nameWithDefault) == defaultShortcut)
		#expect(KeyboardShortcuts.getShortcut(for: nameWithoutDefault) == nil)
	}

	@Test("Overriding defaults")
	func testOverridingDefaults() throws {
		let defaultShortcut = KeyboardShortcuts.Shortcut(.x, modifiers: [.control])
		let name = KeyboardShortcuts.Name("override", default: defaultShortcut)

		let newShortcut = KeyboardShortcuts.Shortcut(.y, modifiers: [.option])
		KeyboardShortcuts.setShortcut(newShortcut, for: name)

		#expect(KeyboardShortcuts.getShortcut(for: name) == newShortcut)

		// Reset should restore default
		KeyboardShortcuts.reset(name)
		#expect(KeyboardShortcuts.getShortcut(for: name) == defaultShortcut)
	}

	@Test("Batch reset")
	func testBatchReset() throws {
		let name1 = KeyboardShortcuts.Name("batch1", default: .init(.a))
		let name2 = KeyboardShortcuts.Name("batch2", default: .init(.b))
		let name3 = KeyboardShortcuts.Name("batch3")

		KeyboardShortcuts.setShortcut(.init(.x), for: name1)
		KeyboardShortcuts.setShortcut(.init(.y), for: name2)
		KeyboardShortcuts.setShortcut(.init(.z), for: name3)

		KeyboardShortcuts.reset(name1, name2, name3)

		#expect(KeyboardShortcuts.getShortcut(for: name1) == .init(.a))
		#expect(KeyboardShortcuts.getShortcut(for: name2) == .init(.b))
		#expect(KeyboardShortcuts.getShortcut(for: name3) == nil)
	}
}

private final class FailingCarbonHotKeyRegistrar: CarbonHotKeyRegistering {
	let status: OSStatus
	private(set) var attemptCount = 0

	init(status: OSStatus) {
		self.status = status
	}

	func register(
		keyCode: UInt32,
		modifiers: UInt32,
		identifier: EventHotKeyID
	) -> CarbonHotKeyRegistration {
		attemptCount += 1
		return .init(status: status, hotKey: nil)
	}
}

private struct FailingCarbonEventHandlerInstaller: CarbonEventHandlerInstalling {
	let status: OSStatus

	func install(on target: EventTargetRef) -> CarbonEventHandlerInstallation {
		.init(status: status, handler: nil)
	}
}

private final class CapturingSystemCarbonHotKeyRegistrar: CarbonHotKeyRegistering {
	private struct Chord: Hashable {
		let keyCode: UInt32
		let modifiers: UInt32
	}

	private let systemRegistrar = SystemCarbonHotKeyRegistrar()
	private var identifiers: [Chord: EventHotKeyID] = [:]
	private var registrationAttempts: [Chord: Int] = [:]
	private var nextFailureStatus: OSStatus?

	func register(
		keyCode: UInt32,
		modifiers: UInt32,
		identifier: EventHotKeyID
	) -> CarbonHotKeyRegistration {
		let chord = Chord(keyCode: keyCode, modifiers: modifiers)
		registrationAttempts[chord, default: 0] += 1
		if let nextFailureStatus {
			self.nextFailureStatus = nil
			return .init(status: nextFailureStatus, hotKey: nil)
		}

		let registration = systemRegistrar.register(
			keyCode: keyCode,
			modifiers: modifiers,
			identifier: identifier
		)
		if registration.status == noErr {
			identifiers[chord] = identifier
		}
		return registration
	}

	func failNextRegistration(with status: OSStatus) {
		nextFailureStatus = status
	}

	func registrationAttemptCount(for shortcut: KeyboardShortcuts.Shortcut) -> Int {
		registrationAttempts[chord(for: shortcut), default: 0]
	}

	func dispatchKeyUp(for shortcut: KeyboardShortcuts.Shortcut) throws -> OSStatus {
		let identifier = try #require(identifiers[chord(for: shortcut)])
		var event: EventRef?
		#expect(
			CreateEvent(
				nil,
				UInt32(kEventClassKeyboard),
				UInt32(kEventHotKeyReleased),
				GetCurrentEventTime(),
				0,
				&event
			) == noErr
		)
		let createdEvent = try #require(event)
		defer { ReleaseEvent(createdEvent) }

		var mutableIdentifier = identifier
		#expect(
			SetEventParameter(
				createdEvent,
				UInt32(kEventParamDirectObject),
				UInt32(typeEventHotKeyID),
				MemoryLayout<EventHotKeyID>.size,
				&mutableIdentifier
			) == noErr
		)
		return SendEventToEventTarget(createdEvent, GetEventDispatcherTarget())
	}

	private func chord(for shortcut: KeyboardShortcuts.Shortcut) -> Chord {
		Chord(
			keyCode: UInt32(shortcut.carbonKeyCode),
			modifiers: UInt32(shortcut.carbonModifiers)
		)
	}
}

private func dispatchRawMenuKeyUp(
	for shortcut: KeyboardShortcuts.Shortcut
) throws -> OSStatus {
	var event: EventRef?
	#expect(
		CreateEvent(
			nil,
			UInt32(kEventClassKeyboard),
			UInt32(kEventRawKeyUp),
			GetCurrentEventTime(),
			0,
			&event
		) == noErr
	)
	let createdEvent = try #require(event)
	defer { ReleaseEvent(createdEvent) }

	var keyCode = UInt32(shortcut.carbonKeyCode)
	#expect(
		SetEventParameter(
			createdEvent,
			UInt32(kEventParamKeyCode),
			typeUInt32,
			MemoryLayout<UInt32>.size,
			&keyCode
		) == noErr
	)
	var modifiers = UInt32(shortcut.carbonModifiers)
	#expect(
		SetEventParameter(
			createdEvent,
			UInt32(kEventParamKeyModifiers),
			typeUInt32,
			MemoryLayout<UInt32>.size,
			&modifiers
		) == noErr
	)
	return CarbonKeyboardShortcuts.handleEvent(createdEvent)
}

// MARK: - Modifier Symbol Tests

@Suite("Modifier Symbol Tests", .serialized)
struct ModifierSymbolTests {
	@Test("Individual modifier symbols")
	func testIndividualModifierSymbols() {
		#expect(NSEvent.ModifierFlags.control.ks_symbolicRepresentation == "⌃")
		#expect(NSEvent.ModifierFlags.option.ks_symbolicRepresentation == "⌥")
		#expect(NSEvent.ModifierFlags.shift.ks_symbolicRepresentation == "⇧")
		#expect(NSEvent.ModifierFlags.command.ks_symbolicRepresentation == "⌘")
		#expect(NSEvent.ModifierFlags([]).ks_symbolicRepresentation == "")
	}

	@Test("Combined modifier symbols")
	func testCombinedModifierSymbols() {
		// macOS standard order: Control, Option, Shift, Command
		// Two modifiers
		#expect(NSEvent.ModifierFlags([.control, .option]).ks_symbolicRepresentation == "⌃⌥")
		#expect(NSEvent.ModifierFlags([.command, .shift]).ks_symbolicRepresentation == "⇧⌘")
		#expect(NSEvent.ModifierFlags([.option, .command]).ks_symbolicRepresentation == "⌥⌘")

		// Three modifiers
		#expect(NSEvent.ModifierFlags([.control, .option, .shift]).ks_symbolicRepresentation == "⌃⌥⇧")
		#expect(NSEvent.ModifierFlags([.control, .shift, .command]).ks_symbolicRepresentation == "⌃⇧⌘")

		// All four main modifiers
		#expect(NSEvent.ModifierFlags([.control, .option, .shift, .command]).ks_symbolicRepresentation == "⌃⌥⇧⌘")
	}

	@Test("Modifier symbols via shortcut")
	func testModifierSymbolsViaShortcut() {
		let shortcut = KeyboardShortcuts.Shortcut(.a, modifiers: [.command, .shift])
		#expect(shortcut.modifiers.ks_symbolicRepresentation == "⇧⌘")

		let complexShortcut = KeyboardShortcuts.Shortcut(.space, modifiers: [.control, .option, .command])
		#expect(complexShortcut.modifiers.ks_symbolicRepresentation == "⌃⌥⌘")
	}

	@Test("Modifier order independence")
	func testModifierOrderIndependence() {
		// No matter the input order, output should be consistent
		#expect(NSEvent.ModifierFlags([.command, .shift, .option, .control]).ks_symbolicRepresentation == "⌃⌥⇧⌘")
		#expect(NSEvent.ModifierFlags([.shift, .control, .command, .option]).ks_symbolicRepresentation == "⌃⌥⇧⌘")
		#expect(NSEvent.ModifierFlags([.option, .command, .control, .shift]).ks_symbolicRepresentation == "⌃⌥⇧⌘")
	}

	@Test("Special modifiers and edge cases")
	func testSpecialModifiersAndEdgeCases() {
		// Function key modifier
		#expect(NSEvent.ModifierFlags.function.ks_symbolicRepresentation == "🌐︎")
		#expect(NSEvent.ModifierFlags([.function, .command]).ks_symbolicRepresentation == "⌘🌐︎")

		// All modifiers combined
		let allModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command, .function]
		#expect(allModifiers.ks_symbolicRepresentation == "⌃⌥⇧⌘🌐︎")

		// Empty modifiers
		#expect(NSEvent.ModifierFlags().ks_symbolicRepresentation == "")
	}
}

// MARK: - UserDefaults Extension for Testing

extension UserDefaults {
	func removeAllKeyboardShortcuts() {
		dictionaryRepresentation().keys.forEach { key in
			if key.hasPrefix("KeyboardShortcuts_") {
				removeObject(forKey: key)
			}
		}
	}
}
