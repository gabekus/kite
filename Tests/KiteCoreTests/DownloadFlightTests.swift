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

    @Test func throwsIntoTheBinWhenTheSidebarIsHidden() throws {
        let flight = try #require(DownloadFlight(pointer: .init(x: 800, y: 615), windowHeight: 1200, target: .bin))
        // Lands 8pt short of (70, 70), doesn't sink, and shrinks to 0.7.
        let landing = flight.position(at: flight.landingTime)
        #expect(abs(landing.x - 62) < 1e-9 && abs(landing.y - 70) < 1e-9)
        #expect(flight.duration == flight.landingTime)
        #expect(abs(flight.scale(at: flight.landingTime).x - 0.7) < 1e-9)
        #expect(abs(flight.scale(at: flight.apexTime).x - 1.6) < 1e-9)
        // Then bounces to (70, 70) and stays there at the landing scale.
        let frames = flight.frames
        let last = try #require(frames.last)
        #expect(abs(last.position.x - 70) < 0.01 && abs(last.position.y - 70) < 0.01)
        let bounce = frames.filter { $0.time >= flight.landingTime }
        #expect(bounce.count > 30)
        #expect(bounce.allSatisfy { abs($0.scaleX - frames[frames.count - bounce.count - 1].scaleX) < 1e-12 })
        // It lands falling fast, so the spring carries it below the bin first.
        #expect(bounce.contains { $0.position.y < 60 })
        #expect(abs(flight.totalDuration - (last.time + 1.0 / 60)) < 1e-12)
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(abs(b.time - a.time - 1.0 / 60) < 1e-9) }
    }

    @Test func springSettlesOnItsTarget() {
        let spring = DampedSpring(dampingRatio: 0.48, response: 0.72)
        #expect(abs(spring.stiffness - pow(2 * .pi / 0.72, 2)) < 1e-9)
        let start = spring.state(at: 0, x0: -8, v0: 300)
        #expect(abs(start.x + 8) < 1e-12 && abs(start.v - 300) < 1e-9)
        // Velocity is the derivative of the displacement.
        let a = spring.state(at: 0.3, x0: -8, v0: 300), b = spring.state(at: 0.3 + 1e-6, x0: -8, v0: 300)
        #expect(abs((b.x - a.x) / 1e-6 - a.v) < 1e-3)
        let samples = spring.samples(offset: .init(x: -8, y: 0), velocity: .init(x: 0, y: -1500))
        #expect(abs(samples[0].x + 8) < 1e-12)
        let last = samples[samples.count - 1]
        #expect(abs(last.x) < 0.01 && abs(last.y) < 0.01)
    }

    @Test func binGeometry() {
        #expect(DownloadBin.tileSize == 46)
        #expect(DownloadBin.shownX - DownloadBin.hiddenX == 133)
        #expect(DownloadBin.shadowOpacity(dark: true) == 0.15)
    }
}

@Suite struct DownloadBadgeCompletionTests {
    @Test func fadesOutAfterTheLastStep() {
        #expect(abs(DownloadBadgeCompletion.duration - 1.45) < 1e-12)
        #expect(DownloadBadgeCompletion.steps.last?.opacity == 0)
        #expect(DownloadBadgeCompletion.steps.map(\.scale) == [0.9, 1, 1.03, 0.97])
    }
}
