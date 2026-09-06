import Foundation
import Testing
@testable import ReolinkNVR

@Suite("Capabilities")
struct CapabilitiesTests {
    private func abilities() throws -> Capabilities {
        let responses = try JSONDecoder().decode([GetAbility.Response].self, from: Data(Fixture.ability.utf8))
        return try #require(responses.first).capabilities
    }

    @Test("Per-channel and host abilities are kept apart")
    func hostAndChannelAbilities() throws {
        let capabilities = try abilities()

        #expect(capabilities.channelCount == 2)
        #expect(capabilities.abilityVersion("scheduleVersion") == 1)
        #expect(capabilities.abilityVersion("talk") == 0)
        #expect(capabilities.supports("p2p"))
        #expect(capabilities.supports("cloudStorage") == false)
        #expect(capabilities.abilityVersion("ptzCtrl", channel: 1) == 3)
        #expect(capabilities.abilityVersion("ptzCtrl", channel: 0) == 0)
    }

    @Test("supportAutoTrackStream finds the telephoto lens")
    func telephotoLens() throws {
        let capabilities = try abilities()

        #expect(capabilities.hasTelephotoLens(channel: 0) == false)
        #expect(capabilities.hasTelephotoLens(channel: 1))
    }

    @Test("An unknown name or channel is not supported, and does not trap")
    func unknownLookups() throws {
        let capabilities = try abilities()

        #expect(capabilities.abilityVersion("supportAutoTrackStream", channel: 7) == 0)
        #expect(capabilities.supports("noSuchAbility", channel: 1) == false)
        #expect(capabilities.supports("noSuchAbility") == false)
    }

    @Test("GetEvents support comes from a probe, not from GetAbility")
    func getEventsSupport() throws {
        let capabilities = try abilities()
        #expect(capabilities.supportsGetEvents == false)

        #expect(capabilities.recording(command: "GetEvents", present: true).supportsGetEvents)
        #expect(capabilities.recording(command: "GetEvents", present: false).supportsGetEvents == false)
    }

    @Test("An ability with an unexpected shape is skipped, not fatal")
    func lenientDecoding() throws {
        let json = """
        [{"cmd":"GetAbility","code":0,"value":{"Ability":{"abilityChn":[{"ptzCtrl":{"permit":64,"ver":3},"weird":"text"}],"talk":"text","p2p":{"permit":0,"ver":1}}}}]
        """
        let capabilities = try #require(
            try JSONDecoder().decode([GetAbility.Response].self, from: Data(json.utf8)).first
        ).capabilities

        #expect(capabilities.supports("p2p"))
        #expect(capabilities.supports("talk") == false)
        #expect(capabilities.abilityVersion("ptzCtrl", channel: 0) == 3)
    }
}
