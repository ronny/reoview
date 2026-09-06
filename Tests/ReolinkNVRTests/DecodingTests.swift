import Foundation
import Testing
@testable import ReolinkNVR

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> [T] {
    try JSONDecoder().decode([T].self, from: Data(json.utf8))
}

private func decodeOne<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try #require(decode(type, json).first)
}

@Suite("Response decoding")
struct ResponseDecodingTests {
    @Test("GetEvents carries motion, AI and the doorbell visitor state")
    func events() throws {
        let events = try decodeOne(GetEvents.Response.self, Fixture.eventsDoorbell)

        #expect(events.channel == 0)
        #expect(events.motionDetected)
        #expect(events.visitorDetected)
        #expect(events.supportsVisitor)
        #expect(events.aiDetected("people"))
        #expect(events.aiDetected("vehicle") == false)
        #expect(events.aiDetected("face") == false)
        #expect(events.supportedAITypes == ["people", "vehicle"])
    }

    @Test("A smart-AI entry that arrives as an array is dropped, not fatal")
    func smartAIArrayIsDropped() throws {
        let events = try decodeOne(GetEvents.Response.self, Fixture.eventsDoorbell)
        #expect(events.ai["crossline"] == nil)
    }

    @Test("md without a support field still counts as supported")
    func motionWithoutSupportField() throws {
        let events = try decode(GetEvents.Response.self, Fixture.eventsTwoChannels)

        #expect(events.count == 2)
        #expect(events[0].motionDetected == false)
        #expect(events[0].supportsVisitor)
        #expect(events[1].motionDetected)
        #expect(events[1].visitor == nil, "the driveway camera is not a doorbell")
        #expect(events[1].aiDetected("people"))
    }

    @Test("GetMdState and GetAiState decode in both firmware shapes")
    func fallbackCommands() throws {
        #expect(try decodeOne(GetMdState.Response.self, Fixture.mdState).motionDetected)

        let legacy = try decodeOne(GetAiState.Response.self, Fixture.aiStateLegacy)
        #expect(legacy.channel == 0)
        #expect(legacy.aiDetected("people"))
        #expect(legacy.aiDetected("vehicle") == false)

        let current = try decodeOne(GetAiState.Response.self, Fixture.aiState)
        #expect(current.aiDetected("vehicle"))
        #expect(current.supportedAITypes == ["people", "vehicle"])
    }

    @Test("GetDevInfo decodes, wrapped in a one-element array or not")
    func devInfo() throws {
        let plain = try decodeOne(GetDevInfo.Response.self, Fixture.devInfo)
        #expect(plain.devInfo.model == "RLN8-410")
        #expect(plain.devInfo.firmVer == "v3.6.5.562")
        #expect(plain.devInfo.channelNum == 8)
        #expect(plain.devInfo.exactType == "NVR")

        let wrapped = try decodeOne(GetDevInfo.Response.self, Fixture.devInfoWrappedInArray)
        #expect(wrapped.devInfo.serial == plain.devInfo.serial)
    }

    @Test("GetEnc reports the codec per quality")
    func enc() throws {
        let enc = try decodeOne(GetEnc.Response.self, Fixture.encTelephotoChannel)

        #expect(enc.codec(.main) == .h265)
        #expect(enc.codec(.sub) == .h264)
        #expect(enc.stream(.main)?.width == 3840)
        #expect(enc.enc.audio == 1)
    }

    @Test("An absent vType falls back the way reolink_aio does")
    func encWithoutVType() throws {
        let json = """
        [{"cmd":"GetEnc","code":0,"value":{"Enc":{"channel":0,"mainStream":{"bitRate":4096},"subStream":{"bitRate":256}}}}]
        """
        let enc = try decodeOne(GetEnc.Response.self, json)

        #expect(enc.codec(.sub) == .h264)
        #expect(enc.codec(.main, mainEncTypeVersion: 0) == .h264)
        #expect(enc.codec(.main, mainEncTypeVersion: 1) == .h265)
    }

    @Test("An action-1 response puts its payload under initial")
    func initialInsteadOfValue() throws {
        let json = """
        [{"cmd":"GetMdState","code":0,"initial":{"state":0},"range":{"state":[0,1]}}]
        """
        #expect(try decodeOne(GetMdState.Response.self, json).state == 0)
    }
}

@Suite("Camera identity")
struct CameraIdentityTests {
    @Test("A camera takes its id from the channel UID")
    func camerasFromChannelStatus() throws {
        let status = try decodeOne(GetChannelstatus.Response.self, Fixture.channelStatus)
        let cameras = Camera.cameras(from: status)

        #expect(status.count == 8)
        #expect(cameras.map(\.id) == ["95270005AAAAAAAA", "95270005BBBBBBBB", "ch2"])
        #expect(cameras[0].name == "Front Door")
        #expect(cameras[0].model == "Reolink Video Doorbell PoE")
        #expect(cameras[1].channel == 1)
        #expect(cameras[2].name == "Channel 2", "the firmware puts \"0\" in the name field")
    }

    @Test("A StreamSource id is camera, lens and quality")
    func streamSourceIdentity() {
        let camera = Camera(id: "95270005BBBBBBBB", name: "Driveway", model: "TrackMix", channel: 1)

        #expect(camera.streamSources(hasTelephotoLens: true).map(\.id) == [
            "95270005BBBBBBBB/wide/main",
            "95270005BBBBBBBB/wide/sub",
            "95270005BBBBBBBB/telephoto/main",
        ])
        #expect(camera.streamSources(hasTelephotoLens: false).count == 2)
    }
}
