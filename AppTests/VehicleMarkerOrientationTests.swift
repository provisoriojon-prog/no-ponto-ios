import XCTest
@testable import NoPonto

final class VehicleMarkerOrientationTests: XCTestCase {
    func testCardinalCoursesPointTheSameWayOnANorthUpMap() throws {
        for degrees in [0.0, 90, 180, 270] {
            let result = try XCTUnwrap(VehicleMarkerOrientation.screenDegrees(bearing: degrees, cameraHeading: 0))
            XCTAssertEqual(result, degrees, accuracy: 0.0001)
        }
    }

    func testRotatedMapPreservesTheVehiclesGeographicCourse() throws {
        // On an east-up map, east points up, south right, west down and north left.
        let courses = [0.0, 90, 180, 270]
        let rotatedMaps: [(Double, [Double])] = [
            (90, [270, 0, 90, 180]),
            (180, [180, 270, 0, 90]),
            (270, [90, 180, 270, 0])
        ]
        for (camera, expectedDirections) in rotatedMaps {
            for (bearing, expected) in zip(courses, expectedDirections) {
                let result = try XCTUnwrap(VehicleMarkerOrientation.screenDegrees(bearing: bearing, cameraHeading: camera))
                XCTAssertEqual(result, expected, accuracy: 0.0001)
            }
        }
    }

    func testNorthBoundaryWrapsWithoutReversingTheArrow() throws {
        let cases: [(Double, Double, Double)] = [(0, 360, 0), (360, 0, 0), (1, 359, 2), (359, 1, 358)]
        for (bearing, camera, expected) in cases {
            let result = try XCTUnwrap(VehicleMarkerOrientation.screenDegrees(bearing: bearing, cameraHeading: camera))
            XCTAssertEqual(result, expected, accuracy: 0.0001)
        }
    }

    func testMissingOrInvalidDirectionUsesTheNeutralMarker() {
        let invalidBearings: [Double?] = [nil, Double.nan, Double.infinity, -Double.infinity, -1, 361]
        for bearing in invalidBearings {
            XCTAssertNil(VehicleMarkerOrientation.screenDegrees(bearing: bearing, cameraHeading: 0))
        }
        for camera in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(VehicleMarkerOrientation.screenDegrees(bearing: 90, cameraHeading: camera))
        }
    }
}
