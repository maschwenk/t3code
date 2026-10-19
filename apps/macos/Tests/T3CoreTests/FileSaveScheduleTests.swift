import Foundation
import Testing

@testable import T3Core

@Test func autosaveDebouncesAndSerializesEditsIncludingARevert() throws {
  var schedule = FileSaveSchedule()
  schedule.change(at: 10)
  schedule.change(at: 10.3)
  let blocked1 = schedule.begin(at: 10.799)
  #expect(blocked1 == nil)
  let firstAttempt = schedule.begin(at: 10.8)
  let first = try #require(firstAttempt)
  schedule.change(at: 10.9)
  let blocked2 = schedule.begin(at: 12)
  #expect(blocked2 == nil)
  schedule.complete(first, succeeded: true, at: 12)
  #expect(schedule.pending)
  let revertedAttempt = schedule.begin(at: 12)
  let reverted = try #require(revertedAttempt)
  schedule.complete(reverted, succeeded: true, at: 12.1)
  #expect(!schedule.pending)
  schedule.flush(at: 12.2)
  let blocked3 = schedule.begin(at: 13)
  #expect(blocked3 == nil)
}

@Test func closingFlushesNewEditsWithoutConcurrentWritesOrRetryLoops() throws {
  var schedule = FileSaveSchedule()
  schedule.change(at: 1)
  schedule.flush(at: 1.1)
  let firstAttempt = schedule.begin(at: 1.1)
  let first = try #require(firstAttempt)
  schedule.change(at: 1.2)
  schedule.flush(at: 1.3)
  let blocked4 = schedule.begin(at: 1.3)
  #expect(blocked4 == nil)
  schedule.complete(first, succeeded: true, at: 1.4)
  let latestAttempt = schedule.begin(at: 1.4)
  let latest = try #require(latestAttempt)
  schedule.complete(latest, succeeded: false, at: 1.5)
  #expect(schedule.pending)
  let blocked5 = schedule.begin(at: 100)
  #expect(blocked5 == nil)
  schedule.flush(at: 100)
  let retriedAttempt = schedule.begin(at: 100)
  let retried = try #require(retriedAttempt)
  schedule.complete(retried, succeeded: true, at: 100.1)
  #expect(!schedule.pending)
}

@Test func aNewEditAfterFailureGetsItsOwnDebounce() throws {
  var schedule = FileSaveSchedule()
  schedule.change(at: 1)
  let firstAttempt = schedule.begin(at: 1.5)
  let first = try #require(firstAttempt)
  schedule.change(at: 2)
  schedule.complete(first, succeeded: false, at: 2.1)
  let blocked6 = schedule.begin(at: 2.49)
  #expect(blocked6 == nil)
  let latestAttempt = schedule.begin(at: 2.5)
  let latest = try #require(latestAttempt)
  schedule.complete(first, succeeded: true, at: 2.6)
  #expect(schedule.inFlight == latest)
  schedule.complete(latest, succeeded: true, at: 2.7)
  #expect(!schedule.pending)
}
