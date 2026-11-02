import Foundation
import Testing
@testable import KiteCore

@Suite struct SpaceReorderTests {
    // Arc's three-space strip: cells 36 wide on a 34pt pitch from x 92.5, centres 110.5, 144.5, 178.5.
    private func index(_ x: Double) -> Int {
        SpaceReorder.dropIndex(pointerX: x, stripMinX: 92.5, count: 3, pitch: 34, cellWidth: 36)
    }

    @Test func dropsInTheSlotNearestThePointer() {
        // Arc moved the open slot between pointer x 128 and 134, and again between 162 and 168.
        #expect(index(110.5) == 0)
        #expect(index(127) == 0)
        #expect(index(128) == 1)
        #expect(index(161) == 1)
        #expect(index(162) == 2)
        // Past either end the first or last slot.
        #expect(index(40) == 0)
        #expect(index(240) == 2)
        #expect(SpaceReorder.dropIndex(pointerX: 100, stripMinX: 0, count: 0, pitch: 34, cellWidth: 36) == 0)
    }

    @Test func opensASlotWhereTheDragAims() {
        let ids = ["a", "b", "c"]
        #expect(SpaceReorder.slots(ids, dragging: "a", target: 1) == ["b", nil, "c"])
        #expect(SpaceReorder.slots(ids, dragging: "a", target: 2) == ["b", "c", nil])
        #expect(SpaceReorder.slots(ids, dragging: "c", target: 0) == [nil, "a", "b"])
        // Off the strip the slot closes.
        #expect(SpaceReorder.slots(ids, dragging: "b", target: nil) == ["a", "c"])
    }

    @Test func stripWidth() {
        // Arc: three cells span x 92.5 to 196.5.
        #expect(SpaceReorder.width(slots: 3, pitch: 34, cellWidth: 36) == 104)
        #expect(SpaceReorder.width(slots: 2, pitch: 34, cellWidth: 36) == 70)
        #expect(SpaceReorder.width(slots: 0, pitch: 34, cellWidth: 36) == 0)
    }

    @Test func dropMovesTheSpaceKeepingTheCurrentOne() {
        var state = BrowserState(spaces: ["A", "B", "C"].map { Space(name: $0, icon: "", theme: .arcDefault) })
        let ids = state.spaces.map(\.id)
        state.selectSpace(ids[0])
        // The drop's slot index is its place among the other spaces.
        state.moveSpace(ids[0], to: 2)
        #expect(state.spaces.map(\.id) == [ids[1], ids[2], ids[0]])
        #expect(state.selectedSpaceID == ids[0])
    }
}
