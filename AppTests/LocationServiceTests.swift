import XCTest
import CoreLocation
@testable import NoPonto

final class LocationServiceTests: XCTestCase {
    func testLocationRequiresRecentValidFix() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func fix(age: TimeInterval, accuracy: Double = 10, latitude: Double = -22.9) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -43.3), altitude: 0,
                       horizontalAccuracy: accuracy, verticalAccuracy: 10, timestamp: now.addingTimeInterval(-age))
        }
        XCTAssertTrue(LocationService.isFresh(fix(age: 0), now: now))
        XCTAssertTrue(LocationService.isFresh(fix(age: 59), now: now))
        XCTAssertFalse(LocationService.isFresh(fix(age: 61), now: now), "Expired coordinates cannot drive nearby points or walking")
        XCTAssertFalse(LocationService.isFresh(fix(age: -6), now: now), "Future-dated fixes are invalid")
        XCTAssertFalse(LocationService.isFresh(fix(age: 0, accuracy: -1), now: now))
        XCTAssertFalse(LocationService.isFresh(fix(age: 0, latitude: 100), now: now))
    }
}
