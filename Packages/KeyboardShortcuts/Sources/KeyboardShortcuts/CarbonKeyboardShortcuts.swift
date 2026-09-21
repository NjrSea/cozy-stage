#if os(macOS)
import Carbon.HIToolbox

private func carbonKeyboardShortcutsEventHandler(eventHandlerCall: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
	CarbonKeyboardShortcuts.handleEvent(event)
}

struct CarbonHotKeyRegistration {
	let status: OSStatus
	let hotKey: EventHotKeyRef?
}

struct CarbonEventHandlerInstallation {
	let status: OSStatus
	let handler: EventHandlerRef?
}

protocol CarbonEventHandlerInstalling {
	func install(on target: EventTargetRef) -> CarbonEventHandlerInstallation
}

struct SystemCarbonEventHandlerInstaller: CarbonEventHandlerInstalling {
	func install(on target: EventTargetRef) -> CarbonEventHandlerInstallation {
		var handler: EventHandlerRef?
		let status = InstallEventHandler(
			target,
			carbonKeyboardShortcutsEventHandler,
			0,
			nil,
			nil,
			&handler
		)
		return .init(status: status, handler: handler)
	}
}

protocol CarbonHotKeyRegistering {
	func register(
		keyCode: UInt32,
		modifiers: UInt32,
		identifier: EventHotKeyID
	) -> CarbonHotKeyRegistration
}

struct SystemCarbonHotKeyRegistrar: CarbonHotKeyRegistering {
	func register(
		keyCode: UInt32,
		modifiers: UInt32,
		identifier: EventHotKeyID
	) -> CarbonHotKeyRegistration {
		var hotKey: EventHotKeyRef?
		let status = RegisterEventHotKey(
			keyCode,
			modifiers,
			identifier,
			GetEventDispatcherTarget(),
			0,
			&hotKey
		)
		return .init(status: status, hotKey: hotKey)
	}
}

enum CarbonKeyboardShortcuts {
	static var hotKeyRegistrar: any CarbonHotKeyRegistering = SystemCarbonHotKeyRegistrar()
	static var eventHandlerInstaller: any CarbonEventHandlerInstalling = SystemCarbonEventHandlerInstaller()
	private final class HotKey {
		let shortcut: KeyboardShortcuts.Shortcut
		let carbonHotKeyId: Int
		var carbonHotKey: EventHotKeyRef?
		let onKeyDown: (KeyboardShortcuts.Shortcut) -> Void
		let onKeyUp: (KeyboardShortcuts.Shortcut) -> Void

		init(
			shortcut: KeyboardShortcuts.Shortcut,
			carbonHotKeyID: Int,
			carbonHotKey: EventHotKeyRef,
			onKeyDown: @escaping (KeyboardShortcuts.Shortcut) -> Void,
			onKeyUp: @escaping (KeyboardShortcuts.Shortcut) -> Void
		) {
			self.shortcut = shortcut
			self.carbonHotKeyId = carbonHotKeyID
			self.carbonHotKey = carbonHotKey
			self.onKeyDown = onKeyDown
			self.onKeyUp = onKeyUp
		}
	}

	private static var hotKeys = [Int: HotKey]()

	// `SSKS` is just short for `Sindre Sorhus Keyboard Shortcuts`.
	// Using an integer now that `UTGetOSTypeFromString("SSKS" as CFString)` is deprecated.
	// swiftlint:disable:next number_separator
	private static let hotKeySignature: UInt32 = 1397967699 // OSType => "SSKS"

	private static var hotKeyId = 0
	private static var eventHandler: EventHandlerRef?

	private static let hotKeyEventTypes = [
		EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
		EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
	]
	private static let rawKeyEventTypes = [
		EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventRawKeyDown)),
		EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventRawKeyUp))
	]

	private static let keyEventMonitor = RunLoopLocalEventMonitor(events: [.keyDown, .keyUp], runLoopMode: .eventTracking) { event in
		guard
			let eventRef = OpaquePointer(event.eventRef),
			handleRawKeyEvent(eventRef) == noErr
		else {
			return event
		}

		return nil
	}

	private static func setUpEventHandlerIfNeeded() -> OSStatus {
		guard eventHandler == nil else {
			return noErr
		}
		guard let dispatcher = GetEventDispatcherTarget() else {
			return OSStatus(paramErr)
		}

		let installation = eventHandlerInstaller.install(on: dispatcher)
		guard installation.status == noErr else {
			return installation.status
		}
		guard let handler = installation.handler else {
			return OSStatus(paramErr)
		}

		eventHandler = handler

		updateEventHandler()
		return noErr
	}

	static func updateEventHandler() {
		guard eventHandler != nil else {
			return
		}

		if KeyboardShortcuts.isEnabled {
			if KeyboardShortcuts.isMenuOpen {
				softUnregisterAll()
				RemoveEventTypesFromHandler(eventHandler, hotKeyEventTypes.count, hotKeyEventTypes)

				if #available(macOS 14, *) {
					keyEventMonitor.start()
				} else {
					AddEventTypesToHandler(eventHandler, rawKeyEventTypes.count, rawKeyEventTypes)
				}
			} else {
				softRegisterAll()

				if #available(macOS 14, *) {
					keyEventMonitor.stop()
				} else {
					RemoveEventTypesFromHandler(eventHandler, rawKeyEventTypes.count, rawKeyEventTypes)
				}

				AddEventTypesToHandler(eventHandler, hotKeyEventTypes.count, hotKeyEventTypes)
			}
		} else {
			softUnregisterAll()
			RemoveEventTypesFromHandler(eventHandler, hotKeyEventTypes.count, hotKeyEventTypes)

			if #available(macOS 14, *) {
				keyEventMonitor.stop()
			} else {
				RemoveEventTypesFromHandler(eventHandler, rawKeyEventTypes.count, rawKeyEventTypes)
			}
		}
	}

	static func register(
		_ shortcut: KeyboardShortcuts.Shortcut,
		onKeyDown: @escaping (KeyboardShortcuts.Shortcut) -> Void,
		onKeyUp: @escaping (KeyboardShortcuts.Shortcut) -> Void
	) -> OSStatus {
		if let existingHotKey = hotKeys.values.first(where: { $0.shortcut == shortcut }) {
			guard existingHotKey.carbonHotKey == nil else {
				return noErr
			}

			return register(existingHotKey)
		}

		hotKeyId += 1

		let registration = hotKeyRegistrar.register(
			keyCode: UInt32(shortcut.carbonKeyCode),
			modifiers: UInt32(shortcut.carbonModifiers),
			identifier: EventHotKeyID(signature: hotKeySignature, id: UInt32(hotKeyId))
		)
		let registerError = registration.status

		guard registerError == noErr else {
			print("Error registering hotkey \(shortcut):", registerError)
			return registerError
		}

		guard let carbonHotKey = registration.hotKey else {
			return OSStatus(paramErr)
		}

		hotKeys[hotKeyId] = HotKey(
			shortcut: shortcut,
			carbonHotKeyID: hotKeyId,
			carbonHotKey: carbonHotKey,
			onKeyDown: onKeyDown,
			onKeyUp: onKeyUp
		)

		let handlerStatus = setUpEventHandlerIfNeeded()
		guard handlerStatus == noErr else {
			unregisterHotKey(hotKeys[hotKeyId]!)
			return handlerStatus
		}
		return noErr
	}

	private static func register(_ hotKey: HotKey) -> OSStatus {
		let registration = hotKeyRegistrar.register(
			keyCode: UInt32(hotKey.shortcut.carbonKeyCode),
			modifiers: UInt32(hotKey.shortcut.carbonModifiers),
			identifier: EventHotKeyID(
				signature: hotKeySignature,
				id: UInt32(hotKey.carbonHotKeyId)
			)
		)

		guard registration.status == noErr else {
			print("Error registering hotkey \(hotKey.shortcut):", registration.status)
			return registration.status
		}

		guard let eventHotKey = registration.hotKey else {
			return OSStatus(paramErr)
		}

		hotKey.carbonHotKey = eventHotKey
		return noErr
	}

	private static func softRegisterAll() {
		for hotKey in hotKeys.values {
			guard hotKey.carbonHotKey == nil else {
				continue
			}

			let status = register(hotKey)
			KeyboardShortcuts.synchronizeRegistrationResult(
				for: hotKey.shortcut,
				status: status
			)
		}
	}

	private static func unregisterHotKey(_ hotKey: HotKey) {
		if let carbonHotKey = hotKey.carbonHotKey {
			UnregisterEventHotKey(carbonHotKey)
		}
		hotKeys.removeValue(forKey: hotKey.carbonHotKeyId)
	}

	static func unregister(_ shortcut: KeyboardShortcuts.Shortcut) {
		for hotKey in hotKeys.values where hotKey.shortcut == shortcut {
			unregisterHotKey(hotKey)
		}
	}

	static func unregisterAll() {
		for hotKey in hotKeys.values {
			unregisterHotKey(hotKey)
		}
	}

	private static func softUnregisterAll() {
		for hotKey in hotKeys.values {
			if let carbonHotKey = hotKey.carbonHotKey {
				UnregisterEventHotKey(carbonHotKey)
			}
			hotKey.carbonHotKey = nil
		}
	}

	static func handleEvent(_ event: EventRef?) -> OSStatus {
		guard let event else {
			return OSStatus(eventNotHandledErr)
		}

		switch Int(GetEventKind(event)) {
		case kEventHotKeyPressed, kEventHotKeyReleased:
			return handleHotKeyEvent(event)
		case kEventRawKeyDown, kEventRawKeyUp:
			return handleRawKeyEvent(event)
		default:
			break
		}

		return OSStatus(eventNotHandledErr)
	}

	private static func handleHotKeyEvent(_ event: EventRef) -> OSStatus {
		var eventHotKeyId = EventHotKeyID()
		let error = GetEventParameter(
			event,
			UInt32(kEventParamDirectObject),
			UInt32(typeEventHotKeyID),
			nil,
			MemoryLayout<EventHotKeyID>.size,
			nil,
			&eventHotKeyId
		)

		guard error == noErr else {
			return error
		}

		guard
			eventHotKeyId.signature == hotKeySignature,
			let hotKey = hotKeys[Int(eventHotKeyId.id)],
			hotKey.carbonHotKey != nil,
			KeyboardShortcuts.isDispatchEligible(hotKey.shortcut)
		else {
			return OSStatus(eventNotHandledErr)
		}

		switch Int(GetEventKind(event)) {
		case kEventHotKeyPressed:
			hotKey.onKeyDown(hotKey.shortcut)
			return noErr
		case kEventHotKeyReleased:
			hotKey.onKeyUp(hotKey.shortcut)
			return noErr
		default:
			break
		}

		return OSStatus(eventNotHandledErr)
	}

	private static func handleRawKeyEvent(_ event: EventRef) -> OSStatus {
		var eventKeyCode = UInt32()
		let keyCodeError = GetEventParameter(
			event,
			UInt32(kEventParamKeyCode),
			typeUInt32,
			nil,
			MemoryLayout<UInt32>.size,
			nil,
			&eventKeyCode
		)

		guard keyCodeError == noErr else {
			return keyCodeError
		}

		var eventKeyModifiers = UInt32()
		let keyModifiersError = GetEventParameter(
			event,
			UInt32(kEventParamKeyModifiers),
			typeUInt32,
			nil,
			MemoryLayout<UInt32>.size,
			nil,
			&eventKeyModifiers
		)

		guard keyModifiersError == noErr else {
			return keyModifiersError
		}

		let shortcut = KeyboardShortcuts.Shortcut(carbonKeyCode: Int(eventKeyCode), carbonModifiers: Int(eventKeyModifiers))

		guard
			let hotKey = (hotKeys.values.first { $0.shortcut == shortcut }),
			KeyboardShortcuts.isDispatchEligible(hotKey.shortcut)
		else {
			return OSStatus(eventNotHandledErr)
		}

		switch Int(GetEventKind(event)) {
		case kEventRawKeyDown:
			hotKey.onKeyDown(hotKey.shortcut)
			return noErr
		case kEventRawKeyUp:
			hotKey.onKeyUp(hotKey.shortcut)
			return noErr
		default:
			break
		}

		return OSStatus(eventNotHandledErr)
	}
}

extension CarbonKeyboardShortcuts {
	static var system: [KeyboardShortcuts.Shortcut] {
		var shortcutsUnmanaged: Unmanaged<CFArray>?
		guard
			CopySymbolicHotKeys(&shortcutsUnmanaged) == noErr,
			let shortcuts = shortcutsUnmanaged?.takeRetainedValue() as? [[String: Any]]
		else {
			assertionFailure("Could not get system keyboard shortcuts")
			return []
		}

		return shortcuts.compactMap {
			guard
				($0[kHISymbolicHotKeyEnabled] as? Bool) == true,
				let carbonKeyCode = $0[kHISymbolicHotKeyCode] as? Int,
				let carbonModifiers = $0[kHISymbolicHotKeyModifiers] as? Int
			else {
				return nil
			}

			return KeyboardShortcuts.Shortcut(
				carbonKeyCode: carbonKeyCode,
				carbonModifiers: carbonModifiers
			)
		}
	}
}
#endif
