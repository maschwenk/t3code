import Foundation

public struct BrowserViewport: Equatable, Sendable {
  public let width: Int?
  public let height: Int?
  public let presetID: String?
  public static let fill = BrowserViewport()
  private init() {
    width = nil
    height = nil
    presetID = nil
  }
  public init(width: Int, height: Int, presetID: String? = nil) throws {
    guard (240...3840).contains(width), (240...3840).contains(height), width * height <= 3840 * 2160
    else {
      throw T3Error(
        "Use dimensions from 240 to 3840 pixels, with an area no larger than 3840 × 2160.")
    }
    self.width = width
    self.height = height
    self.presetID = presetID
  }
  public init(_ value: JSON) throws {
    guard value["_tag"].string == "preset" || value["_tag"].string == "freeform" else {
      self = .fill
      return
    }
    try self.init(
      width: value.requiredInt("width"), height: value.requiredInt("height"),
      presetID: value["_tag"].string == "preset" ? value["presetId"].string : nil)
  }
  public var json: JSON {
    guard let width, let height else { return .object(["_tag": .string("fill")]) }
    var fields: [String: JSON] = [
      "_tag": .string(presetID == nil ? "freeform" : "preset"),
      "width": .number(Double(width)), "height": .number(Double(height)),
    ]
    if let presetID { fields["presetId"] = .string(presetID) }
    return .object(fields)
  }
  public var rotated: Self {
    guard let width, let height else { return self }
    return try! Self(width: height, height: width, presetID: presetID)
  }
}

public struct BrowserDevicePreset: Sendable {
  public let id: String
  public let name: String
  public let viewport: BrowserViewport
  private init(_ id: String, _ name: String, _ width: Int, _ height: Int) {
    self.id = id
    self.name = name
    viewport = try! BrowserViewport(width: width, height: height, presetID: id)
  }
  // Same IDs and CSS sizes as packages/shared/src/previewViewport.ts.
  public static let all: [Self] = [
    .init("iphone-se", "iPhone SE", 375, 667),
    .init("iphone-xr", "iPhone XR", 414, 896),
    .init("iphone-12-pro", "iPhone 12 Pro", 390, 844),
    .init("iphone-14-pro-max", "iPhone 14 Pro Max", 430, 932),
    .init("pixel-7", "Pixel 7", 412, 915),
    .init("samsung-galaxy-s8-plus", "Samsung Galaxy S8+", 360, 740),
    .init("samsung-galaxy-s20-ultra", "Samsung Galaxy S20 Ultra", 412, 915),
    .init("ipad-mini", "iPad Mini", 768, 1024),
    .init("ipad-air", "iPad Air", 820, 1180),
    .init("ipad-pro", "iPad Pro", 1024, 1366),
    .init("surface-pro-7", "Surface Pro 7", 912, 1368),
    .init("surface-duo", "Surface Duo", 540, 720),
    .init("galaxy-z-fold-5", "Galaxy Z Fold 5", 344, 882),
    .init("asus-zenbook-fold", "Asus Zenbook Fold", 853, 1280),
    .init("samsung-galaxy-a51-71", "Samsung Galaxy A51/71", 412, 914),
    .init("nest-hub", "Nest Hub", 1024, 600),
    .init("nest-hub-max", "Nest Hub Max", 1280, 800),
  ]
}
