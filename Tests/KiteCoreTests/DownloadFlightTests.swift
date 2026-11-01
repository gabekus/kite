import Foundation
import Testing
@testable import KiteCore

@Suite struct DownloadFlightTests {
    @Test func landsOnTheLibraryButtonOnTime() throws {
        let flight = try #require(DownloadFlight(pointer: .init(x: 800, y: 615), windowHeight: 1200))
        #expect(flight.start == .init(x: 815, y: 600))
        // 1600 - 1100 × 600/1200.
        #expect(abs(flight.launchSpeedY - 1050) < 1e-9)
        let landing = flight.position(at: flight.landingTime)
        #expect(abs(landing.x - 32) < 1e-9)
        #expect(abs(landing.y - 40) < 1e-9)
        #expect(abs(flight.apexTime - 1050 / 2648.7) < 1e-12)
        #expect(abs(flight.duration - (flight.landingTime + 0.13333333333333333)) < 1e-12)
    }

    @Test func throwsFromLowerArcHigher() throws {
        let low = try #require(DownloadFlight(pointer: .init(x: 400, y: 215), windowHeight: 1000))
        let high = try #require(DownloadFlight(pointer: .init(x: 400, y: 915), windowHeight: 1000))
        #expect(low.launchSpeedY > high.launchSpeedY)
    }

    @Test func stretchesThenShrinks() throws {
        let flight = try #require(DownloadFlight(pointer: .init(x: 800, y: 615), windowHeight: 1200))
        let launch = flight.scale(at: 0)
        #expect(abs(launch.x - 0.8) < 1e-9 && abs(launch.y - 1.2) < 1e-9)
        let apex = flight.scale(at: flight.apexTime)
        #expect(abs(apex.x - 1.6) < 1e-9 && abs(apex.y - 1.6) < 1e-9)
        let landed = flight.scale(at: flight.landingTime)
        #expect(abs(landed.x - 0.3) < 1e-9)
        // Sinking: smaller still, never negative.
        #expect(flight.scale(at: flight.duration).x < 0.3)
        #expect(flight.scale(at: flight.duration + 5).x == 0)
    }

    @Test func framesAreSixtyPerSecond() throws {
        let flight = try #require(DownloadFlight(pointer: .init(x: 800, y: 615), windowHeight: 1200))
        let frames = flight.frames
        #expect(frames.first?.time == 0)
        #expect(abs(frames.count - Int((flight.duration * 60).rounded(.up))) <= 1)
        #expect(abs(frames[1].time - 1.0 / 60) < 1e-12)
        #expect(frames.allSatisfy { $0.time < flight.duration })
    }

    @Test func fallsBackWhenThePointerIsNotFinite() throws {
        let flight = try #require(DownloadFlight(pointer: .init(x: .nan, y: 10), windowHeight: 800))
        #expect(flight.start == .init(x: 85, y: 55))
    }
}
