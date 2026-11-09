import AppKit

/// The experimental staging display that window moves park windows on, made with CoreGraphics' private
/// CGVirtualDisplay classes (signatures as in Stengo/DeskPad's CGVirtualDisplayPrivate.h).
///
/// Swift can't catch Objective-C exceptions, so every class and method is checked before use: one that a macOS update
/// renames or removes makes `ensure()` return 0 instead of crashing.
@MainActor
enum VirtualDisplay {
  /// Kept until `remove()` or the app quits; dropping it removes the display.
  private static var display: NSObject?

  /// The staging display's ID, or 0 when there is none.
  static var id: CGDirectDisplayID { display.flatMap(displayID(of:)) ?? 0 }

  /// The staging display's ID, creating it if needed; 0 if it can't be made.
  static func ensure() -> CGDirectDisplayID {
    if let display, let id = displayID(of: display) { return id }
    guard
      let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
      let displayClass = NSClassFromString("CGVirtualDisplay"),
      let modeClass = NSClassFromString("CGVirtualDisplayMode"),
      let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type
    else { return 0 }

    let descriptor = descriptorClass.init()
    guard
      set(descriptor, "dispatchQueue", DispatchQueue.main),
      set(descriptor, "name", "Cubicle Staging (Experimental)"),
      set(descriptor, "maxPixelsWide", 1280),
      set(descriptor, "maxPixelsHigh", 720),
      set(descriptor, "sizeInMillimeters", NSValue(size: NSSize(width: 530, height: 300))),
      set(descriptor, "vendorID", 0x4355),
      set(descriptor, "productID", 1),
      set(descriptor, "serialNum", 1)
    else { return 0 }

    typealias InitWithObject = @convention(c) (UnsafeMutableRawPointer, Selector, AnyObject) -> UnsafeMutableRawPointer?
    typealias InitMode = @convention(c) (UnsafeMutableRawPointer, Selector, UInt, UInt, CGFloat) -> UnsafeMutableRawPointer?
    guard
      let created = create(displayClass, "initWithDescriptor:", as: InitWithObject.self, { $0($1, $2, descriptor) }),
      let mode = create(modeClass, "initWithWidth:height:refreshRate:", as: InitMode.self, { $0($1, $2, 1280, 720, 60) })
    else { return 0 }

    let settings = settingsClass.init()
    guard set(settings, "hiDPI", 0), set(settings, "modes", [mode]) else { return 0 }

    typealias ApplySettings = @convention(c) (AnyObject, Selector, AnyObject) -> ObjCBool
    let apply = NSSelectorFromString("applySettings:")
    guard created.responds(to: apply),
      unsafeBitCast(msgSend, to: ApplySettings.self)(created, apply, settings).boolValue,
      let id = displayID(of: created)
    else { return 0 }
    display = created
    return id
  }

  static func remove() {
    display = nil
  }

  private static func displayID(of display: NSObject) -> CGDirectDisplayID? {
    guard display.responds(to: NSSelectorFromString("displayID")),
      let id = (display.value(forKey: "displayID") as? NSNumber)?.uint32Value, id != 0
    else { return nil }
    return id
  }

  /// Sets a property through its setter, if the object has one; KVC unboxes numbers and NSValue structs.
  private static func set(_ object: NSObject, _ key: String, _ value: Any) -> Bool {
    let setter = NSSelectorFromString("set\(key.prefix(1).uppercased())\(key.dropFirst()):")
    guard object.responds(to: setter) else { return false }
    object.setValue(value, forKey: key)
    return true
  }

  private static let msgSend = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")!

  /// `[[cls alloc] <initializer>]`. Pointers are passed raw because alloc hands over ownership and init takes it.
  private static func create<F>(
    _ cls: AnyClass, _ initializer: String, as type: F.Type,
    _ call: (F, UnsafeMutableRawPointer, Selector) -> UnsafeMutableRawPointer?
  ) -> NSObject? {
    let selector = NSSelectorFromString(initializer)
    guard class_getInstanceMethod(cls, selector) != nil else { return nil }
    typealias Alloc = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
    guard let allocated = unsafeBitCast(msgSend, to: Alloc.self)(cls, NSSelectorFromString("alloc")),
      let initialized = call(unsafeBitCast(msgSend, to: type), allocated, selector)
    else { return nil }
    return Unmanaged<NSObject>.fromOpaque(initialized).takeRetainedValue()
  }
}
