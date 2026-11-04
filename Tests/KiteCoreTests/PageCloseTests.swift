import Foundation
import Testing
@testable import KiteCore

@Suite struct PageCloseTests {
    @Test func pageWithoutHandlerClosesWhenItLetsGo() {
        var close = PageClose()
        let (g, start) = close.request()
        #expect(start == [.armTimer(generation: g), .startUnload])
        #expect(close.pageLetGo() == [.cancelTimer, .finish(.close, generation: g)])
        #expect(close.phase == .closing)
    }

    @Test func leaveClosesAfterThePageLetsGo() {
        var close = PageClose()
        let (g, _) = close.request()
        #expect(close.dialogShown() == [.cancelTimer])
        #expect(close.answered(leave: true) == [.armTimer(generation: g)])
        // CEF resets the dialog state inside Continue: it mustn't end a request that picked Leave.
        #expect(close.dialogReset() == [])
        #expect(close.pageLetGo() == [.cancelTimer, .finish(.close, generation: g)])
    }

    @Test func cancelKeepsThePageAndAllowsAnotherRequest() {
        var close = PageClose()
        let (g, _) = close.request()
        _ = close.dialogShown()
        #expect(close.answered(leave: false) == [.finish(.stay, generation: g)])
        #expect(close.phase == .idle)
        let (g2, again) = close.request()
        #expect(g2 != g)
        #expect(again == [.armTimer(generation: g2), .startUnload])
    }

    @Test func aNewerRequestSupersedesTheOlderOne() {
        var close = PageClose()
        let (first, _) = close.request()
        let (second, effects) = close.request()
        #expect(effects == [.finish(.superseded, generation: first), .armTimer(generation: second)])
        // The older request's timer is stale.
        #expect(close.timerFired(generation: first) == [])
        _ = close.dialogShown()
        #expect(close.answered(leave: false) == [.finish(.stay, generation: second)])
    }

    @Test func aRequestWhileTheDialogIsUpTakesItsAnswer() {
        var close = PageClose()
        let (first, _) = close.request()
        _ = close.dialogShown()
        let (second, effects) = close.request()
        #expect(effects == [.finish(.superseded, generation: first)])
        #expect(close.answered(leave: false) == [.finish(.stay, generation: second)])
    }

    /// A second click on the close button while "Leave site?" is up: no new close starts, the sheet stays,
    /// and its answer goes to the newer request.
    @Test func aSecondClickWhileTheSheetIsUpKeepsAsking() {
        var close = PageClose()
        let (first, _) = close.request()
        _ = close.dialogShown()
        let (second, effects) = close.request()
        #expect(!effects.contains(.startUnload))
        #expect(close.pending == second)
        #expect(close.phase == .asking(second))
        _ = close.answered(leave: true)
        #expect(close.pageLetGo() == [.cancelTimer, .finish(.close, generation: second)])
        #expect(first != second)
    }

    @Test func aForcedCloseSupersedesTheRequest() {
        var close = PageClose()
        let (g, _) = close.request()
        _ = close.dialogShown()
        #expect(close.forced() == [.cancelTimer, .finish(.superseded, generation: g)])
        #expect(close.answered(leave: false) == [])
        #expect(close.pageLetGo() == [])
    }

    @Test func aForcedCloseWithNothingPendingSaysNothing() {
        var close = PageClose()
        #expect(close.forced() == [])
        let (g, effects) = close.request()
        #expect(effects == [.finish(.close, generation: g)])
    }

    @Test func resetEndsOnlyARequestWhoseDialogWasShown() {
        var close = PageClose()
        let (g, _) = close.request()
        #expect(close.dialogReset() == [])
        _ = close.dialogShown()
        #expect(close.dialogReset() == [.finish(.stay, generation: g)])
    }

    @Test func aDialogOutsideARequestIsIgnored() {
        var close = PageClose()
        #expect(close.dialogShown() == [])
        #expect(close.answered(leave: true) == [])
        #expect(close.pageLetGo() == [])
    }

    @Test func aPageThatNeverAnswersIsClosedAtTheDeadline() {
        var close = PageClose()
        let (g, _) = close.request()
        #expect(close.timerFired(generation: g) == [.forceClose, .finish(.close, generation: g)])
        #expect(close.pageLetGo() == [])
    }

    @Test func aPageThatHangsAfterLeaveIsClosedAtTheDeadline() {
        var close = PageClose()
        let (g, _) = close.request()
        _ = close.dialogShown()
        _ = close.answered(leave: true)
        #expect(close.timerFired(generation: g) == [.forceClose, .finish(.close, generation: g)])
    }

    @Test func theDialogStopsTheDeadline() {
        var close = PageClose()
        let (g, _) = close.request()
        _ = close.dialogShown()
        #expect(close.timerFired(generation: g) == [])
    }
}

@Suite struct PageCloseChainTests {
    @Test func asksOnlyPagesWithHandlersOnScreenFirst() {
        let order = PageCloseChain.order(["a", "b", "c", "d"], shown: ["c"], hasHandler: ["a", "c", "d"])
        #expect(order == ["c", "a", "d"])
    }

    @Test func proceedsOnceEveryPageAgreed() {
        var chain = PageCloseChain(asking: ["a", "b"])
        #expect(chain.start() == .ask("a"))
        #expect(chain.answered(.close) == .ask("b"))
        #expect(chain.answered(.close) == .proceed(approved: ["a", "b"]))
    }

    @Test func stopsAtTheFirstPageThatStays() {
        var chain = PageCloseChain(asking: ["a", "b", "c"])
        _ = chain.start()
        _ = chain.answered(.close)
        #expect(chain.answered(.stay) == .stop(approved: ["a"]))
    }

    @Test func aSupersededAnswerStopsTheChain() {
        var chain = PageCloseChain(asking: ["a"])
        _ = chain.start()
        #expect(chain.answered(.superseded) == .stop(approved: []))
    }

    @Test func nothingToAskProceedsAtOnce() {
        var chain = PageCloseChain<String>(asking: [])
        #expect(chain.start() == .proceed(approved: []))
    }
}
