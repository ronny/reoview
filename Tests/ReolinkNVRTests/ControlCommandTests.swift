import Foundation
import Testing
@testable import ReolinkNVR

private func decodeOne<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try #require(try JSONDecoder().decode([T].self, from: Data(json.utf8)).first)
}

/// The `param` object a command puts on the wire, with the channel merged the
/// way `NVRClient` merges it.
private func param(_ command: some NVRCommand, channel: Int? = nil) throws -> [String: Any] {
    try #require(try RequestBody.element(command, channel: channel)["param"] as? [String: Any])
}

@Suite("Control request shape")
struct ControlRequestShapeTests {
    @Test("A press sends the direction and a release sends Stop")
    func ptzPressAndRelease() async throws {
        let transport = FixtureTransport(replaying: [
            Fixture.login,
            Fixture.acknowledgement("PtzCtrl"),
            Fixture.acknowledgement("PtzCtrl"),
        ])
        let client = NVRClient(
            host: "192.168.8.215",
            credentials: Credentials(user: "viewer", password: "s3cr3t"),
            transport: transport
        )

        _ = try await client.send(PtzCtrl(move: .up), channel: 1)
        _ = try await client.send(PtzCtrl.stop, channel: 1)

        let sent = await transport.requests(cmd: "PtzCtrl")
        #expect(sent.count == 2)

        let press = try #require(sent.first?.bodyElements.first)
        #expect(press["cmd"] as? String == "PtzCtrl")
        #expect(press["action"] as? Int == 0)
        let pressParam = try #require(press["param"] as? [String: Any])
        #expect(pressParam["channel"] as? Int == 1)
        #expect(pressParam["op"] as? String == "Up")
        #expect(pressParam["speed"] as? Int == 25)
        #expect(pressParam["id"] == nil)

        let release = try #require(sent.last?.bodyElements.first)
        let releaseParam = try #require(release["param"] as? [String: Any])
        #expect(releaseParam["channel"] as? Int == 1)
        #expect(releaseParam["op"] as? String == "Stop")
        #expect(releaseParam["speed"] == nil, "reolink_aio leaves speed off a Stop")
    }

    @Test("A channel without ptz speed sends no speed field")
    func ptzWithoutSpeed() throws {
        let body = try param(PtzCtrl(move: .left, speed: nil), channel: 1)
        #expect(body["op"] as? String == "Left")
        #expect(body["speed"] == nil)
    }

    @Test("A preset is PtzCtrl with ToPos and an id")
    func ptzPreset() throws {
        let body = try param(PtzCtrl(preset: 3), channel: 1)
        #expect(body["op"] as? String == "ToPos")
        #expect(body["id"] as? Int == 3)
        #expect(body["speed"] == nil)
    }

    @Test("SetPtzGuard nests the channel inside PtzGuard")
    func setPtzGuard() throws {
        let stored = try #require(
            try param(SetPtzGuard(channel: 1, operation: .setPosition))["PtzGuard"] as? [String: Any]
        )
        #expect(stored["channel"] as? Int == 1)
        #expect(stored["cmdStr"] as? String == "setPos")
        #expect(stored["bSaveCurrentPos"] as? Int == 1)

        let goto = try #require(
            try param(SetPtzGuard(channel: 1, operation: .goToPosition))["PtzGuard"] as? [String: Any]
        )
        #expect(goto["cmdStr"] as? String == "toPos", "the guard spells it differently to PtzCtrl")
        #expect(goto["bSaveCurrentPos"] == nil)
    }

    @Test("A settings-only guard change keeps setPos but never saves the position")
    func setPtzGuardSettingsOnly() throws {
        let body = try #require(
            try param(SetPtzGuard(channel: 1, enabled: true, returnTime: 120))["PtzGuard"] as? [String: Any]
        )
        #expect(body["cmdStr"] as? String == "setPos")
        #expect(body["bSaveCurrentPos"] == nil)
        #expect(body["benable"] as? Int == 1)
        #expect(body["timeout"] as? Int == 120)
    }

    @Test("GetZoomFocus asks for the range with action 1")
    func getZoomFocusAction() throws {
        let element = try RequestBody.element(GetZoomFocus(), channel: 1)
        #expect(element["action"] as? Int == 1)
        #expect((element["param"] as? [String: Any])?["channel"] as? Int == 1)
    }

    @Test("StartZoomFocus nests the channel, op and pos inside ZoomFocus")
    func startZoomFocus() throws {
        let zoom = try #require(
            try param(StartZoomFocus(channel: 1, zoom: 12))["ZoomFocus"] as? [String: Any]
        )
        #expect(zoom["channel"] as? Int == 1)
        #expect(zoom["op"] as? String == "ZoomPos")
        #expect(zoom["pos"] as? Int == 12)

        let focus = try #require(
            try param(StartZoomFocus(channel: 1, focus: 200))["ZoomFocus"] as? [String: Any]
        )
        #expect(focus["op"] as? String == "FocusPos")
        #expect(focus["pos"] as? Int == 200)
    }

    @Test("SetAiCfg writes back the field the camera reported")
    func setAiCfg() throws {
        let smart = try param(SetAiCfg(smartTrack: true), channel: 1)
        #expect(smart["channel"] as? Int == 1)
        #expect(smart["bSmartTrack"] as? Int == 1)
        #expect(smart["aiTrack"] == nil)

        let legacy = try param(SetAiCfg(aiTrack: false), channel: 1)
        #expect(legacy["aiTrack"] as? Int == 0)
        #expect(legacy["bSmartTrack"] == nil)
    }

    @Test("GetAiCfg asks for the track method range with action 1")
    func getAiCfgAction() throws {
        #expect(try RequestBody.element(GetAiCfg(), channel: 1)["action"] as? Int == 1)
    }

    @Test("SetWhiteLed nests the channel inside WhiteLed")
    func setWhiteLed() throws {
        let plain = try #require(try param(SetWhiteLed(channel: 1, on: true))["WhiteLed"] as? [String: Any])
        #expect(plain["channel"] as? Int == 1)
        #expect(plain["state"] as? Int == 1)
        #expect(plain["bright"] == nil)
        #expect(plain["mode"] == nil)

        let full = try #require(
            try param(SetWhiteLed(channel: 1, on: false, brightness: 40, mode: .schedule))["WhiteLed"] as? [String: Any]
        )
        #expect(full["state"] as? Int == 0)
        #expect(full["bright"] as? Int == 40)
        #expect(full["mode"] as? Int == 3)
    }

    @Test("The siren carries alarm_mode manul and a manual_switch, never times")
    func sirenPayload() throws {
        let on = try param(AudioAlarmPlay(on: true), channel: 0)
        #expect(on["channel"] as? Int == 0)
        #expect(on["alarm_mode"] as? String == "manul")
        #expect(on["manual_switch"] as? Int == 1)
        #expect(on["times"] == nil, "reolink_aio never sends times beside manul")

        let off = try param(AudioAlarmPlay(on: false), channel: 0)
        #expect(off["alarm_mode"] as? String == "manul")
        #expect(off["manual_switch"] as? Int == 0)

        let counted = try param(AudioAlarmPlay(times: 2), channel: 0)
        #expect(counted["alarm_mode"] as? String == "times")
        #expect(counted["times"] as? Int == 2)
        #expect(counted["manual_switch"] == nil)
    }

    @Test("QuickReplyPlay carries the file id beside the channel")
    func quickReplyPlay() throws {
        let body = try param(QuickReplyPlay(fileID: 1), channel: 0)
        #expect(body["channel"] as? Int == 0)
        #expect(body["id"] as? Int == 1)
    }

    @Test("SetAudioCfg nests the volume inside AudioCfg")
    func setAudioCfg() throws {
        let body = try #require(try param(SetAudioCfg(channel: 0, volume: 45))["AudioCfg"] as? [String: Any])
        #expect(body["channel"] as? Int == 0)
        #expect(body["volume"] as? Int == 45)
    }

    @Test("SetManualRec sends a duration on start and none on stop")
    func setManualRec() throws {
        let start = try #require(try param(SetManualRec(channel: 0, recording: true))["Rec"] as? [String: Any])
        #expect(start["channel"] as? Int == 0)
        #expect(start["enable"] as? Int == 1)
        #expect(start["duration"] as? Int == 600)

        let stop = try #require(try param(SetManualRec(channel: 0, recording: false))["Rec"] as? [String: Any])
        #expect(stop["enable"] as? Int == 0)
        #expect(stop["duration"] == nil)
    }
}

@Suite("Control response decoding")
struct ControlResponseDecodingTests {
    @Test("GetPtzPreset keeps only the slots that hold a position")
    func ptzPresets() throws {
        let response = try decodeOne(GetPtzPreset.Response.self, Fixture.ptzPresets)

        #expect(response.presets.count == 3)
        #expect(response.storedPresets.map(\.id) == [1, 3])
        #expect(response.storedPresets.first?.name == "Driveway")
    }

    @Test("A preset id that arrives as a string still decodes")
    func ptzPresetStringNumbers() throws {
        let response = try decodeOne(GetPtzPreset.Response.self, Fixture.ptzPresetsWithStringNumbers)

        #expect(response.storedPresets.map(\.id) == [1])
    }

    @Test("A guard position needs both benable and bexistPos")
    func ptzGuard() throws {
        let response = try decodeOne(GetPtzGuard.Response.self, Fixture.ptzGuard)

        #expect(response.guardPosition.isEnabled)
        #expect(response.guardPosition.hasStoredPosition)
        #expect(response.guardPosition.returnTime == 60)

        let unset = """
        [{"cmd":"GetPtzGuard","code":0,"value":{"PtzGuard":{"benable":1,"bexistPos":0,"channel":1}}}]
        """
        let none = try decodeOne(GetPtzGuard.Response.self, unset)
        #expect(none.guardPosition.isEnabled == false)
        #expect(none.guardPosition.returnTime == 60, "the default when the field is absent")
    }

    @Test("GetZoomFocus reads the position from value and the range from range")
    func zoomFocus() throws {
        let response = try decodeOne(GetZoomFocus.Response.self, Fixture.zoomFocus)

        #expect(response.zoom == 4)
        #expect(response.focus == 32)
        #expect(response.zoomRange?.min == 0)
        #expect(response.zoomRange?.max == 33)
        #expect(response.focusRange?.max == 223)
    }

    @Test("An absent range is not fatal, it only means zoom is unavailable")
    func zoomFocusWithoutRange() throws {
        let response = try decodeOne(GetZoomFocus.Response.self, Fixture.zoomFocusWithoutRange)

        #expect(response.zoom == 4)
        #expect(response.zoomRange == nil)
        #expect(response.focusRange == nil)
    }

    @Test("GetAiCfg keeps bSmartTrack and aiTrack apart")
    func aiCfg() throws {
        let smart = try decodeOne(GetAiCfg.Response.self, Fixture.aiCfgSmartTrack)
        #expect(smart.usesSmartTrack)
        #expect(smart.autoTrackEnabled)
        #expect(smart.aiTrack == 2, "aiTrack is the track method here, not the on/off state")
        #expect(smart.disappearBackTime == 30)
        #expect(smart.stopBackTime == 15)

        let legacy = try decodeOne(GetAiCfg.Response.self, Fixture.aiCfgAiTrack)
        #expect(legacy.usesSmartTrack == false)
        #expect(legacy.autoTrackEnabled == false)
    }

    @Test("GetWhiteLed reports state, brightness and the schedule")
    func whiteLed() throws {
        let response = try decodeOne(GetWhiteLed.Response.self, Fixture.whiteLed)

        #expect(response.whiteLed.isOn == false)
        #expect(response.whiteLed.bright == 100)
        #expect(response.whiteLed.spotlightMode == .auto)
        #expect(response.whiteLed.lightingSchedule?.startHour == 18)
        #expect(response.whiteLed.lightingSchedule?.endMin == 0)
    }

    @Test("GetAudioFileList decodes a list, and a null list as empty")
    func audioFileList() throws {
        let files = try decodeOne(GetAudioFileList.Response.self, Fixture.audioFileList)
        #expect(files.files.map(\.id) == [0, 1])
        #expect(files.files.first?.fileName == "Please leave the parcel")

        #expect(try decodeOne(GetAudioFileList.Response.self, Fixture.audioFileListEmpty).files.isEmpty)
    }

    @Test("GetAutoReply reports the file the camera plays by itself")
    func autoReply() throws {
        let response = try decodeOne(GetAutoReply.Response.self, Fixture.autoReply)

        #expect(response.autoReply.isEnabled)
        #expect(response.autoReply.selectedFileID == 1)
        #expect(response.autoReply.timeout == 10)

        let off = """
        [{"cmd":"GetAutoReply","code":0,"value":{"AutoReply":{"channel":0,"enable":0}}}]
        """
        #expect(try decodeOne(GetAutoReply.Response.self, off).autoReply.selectedFileID == -1)
    }

    @Test("GetAudioCfg reports the speaker volume")
    func audioCfg() throws {
        let response = try decodeOne(GetAudioCfg.Response.self, Fixture.audioCfg)

        #expect(response.audioCfg.volume == 70)
        #expect(response.audioCfg.talkAndReplyVolume == 80)
        #expect(response.audioCfg.visitorVolume == 60)
    }

    @Test("GetManualRec reports recording, and the stuck enable flag")
    func manualRec() throws {
        let recording = try decodeOne(GetManualRec.Response.self, Fixture.manualRec)
        #expect(recording.rec.isRecording)
        #expect(recording.rec.hasStuckEnableFlag == false)
        #expect(recording.rec.duration == 600)

        let stuck = try decodeOne(GetManualRec.Response.self, Fixture.manualRecStuck)
        #expect(stuck.rec.isRecording)
        #expect(stuck.rec.hasStuckEnableFlag)
    }

    @Test("A command that only acts decodes its acknowledgement")
    func acknowledgement() throws {
        _ = try decodeOne(PtzCtrl.Response.self, Fixture.acknowledgement("PtzCtrl"))
        _ = try decodeOne(AudioAlarmPlay.Response.self, Fixture.acknowledgement("AudioAlarmPlay"))
    }
}

@Suite("Control capability gating")
struct ControlCapabilityTests {
    private func abilities() throws -> Capabilities {
        let responses = try JSONDecoder().decode(
            [GetAbility.Response].self, from: Data(Fixture.abilityControls.utf8)
        )
        return try #require(responses.first).capabilities
    }

    @Test("ptzType, not ptzCtrl, decides which parts of the pad exist")
    func ptz() throws {
        let capabilities = try abilities()

        #expect(capabilities.ptzType(channel: 1) == 3)
        #expect(capabilities.supportsPtz(channel: 1))
        #expect(capabilities.supportsPan(channel: 1))
        #expect(capabilities.supportsTilt(channel: 1))
        #expect(capabilities.supportsPtzSpeed(channel: 1))
        #expect(capabilities.supportsPtzPresets(channel: 1))

        #expect(capabilities.supportsPtz(channel: 0) == false)
        #expect(capabilities.supportsPan(channel: 0) == false)
        #expect(capabilities.supportsPtzPresets(channel: 0) == false)
        #expect(capabilities.supportsPtz(channel: 2) == false)
    }

    @Test("A channel that never names supportPtzSpeed still takes a speed")
    func ptzSpeedDefault() throws {
        let json = """
        [{"cmd":"GetAbility","code":0,"value":{"Ability":{"abilityChn":[{"ptzType":{"permit":7,"ver":3}}]}}}]
        """
        let capabilities = try #require(
            try JSONDecoder().decode([GetAbility.Response].self, from: Data(json.utf8)).first
        ).capabilities

        #expect(capabilities.supportsPtzSpeed(channel: 0))
    }

    @Test("Zoom comes from ptzType or from supportDigitalZoom")
    func zoom() throws {
        let capabilities = try abilities()

        #expect(capabilities.supportsZoom(channel: 1), "ptzType 3 has no optical zoom, supportDigitalZoom does")
        #expect(capabilities.supportsZoom(channel: 0) == false)
    }

    @Test("The guard position and the floodlight wait for their probe")
    func probedControls() throws {
        let capabilities = try abilities()

        #expect(capabilities.supportsPtzGuard(channel: 1) == false)
        #expect(capabilities.supportsFloodlight(channel: 1) == false)

        let probed = capabilities
            .recording(command: "GetPtzGuard", present: true)
            .recording(command: "GetWhiteLed", present: true)

        #expect(probed.supportsPtzGuard(channel: 1))
        #expect(probed.supportsFloodlight(channel: 1))
        #expect(probed.supportsPtzGuard(channel: 0) == false, "the doorbell does not pan")
        #expect(probed.supportsFloodlight(channel: 0) == false, "the doorbell has no floodLight key")
    }

    @Test("Speaker volume and manual record have no ability key at all")
    func probedOnlyControls() throws {
        let capabilities = try abilities()

        #expect(capabilities.supportsSpeakerVolume(channel: 0) == false)
        #expect(capabilities.supportsManualRecord(channel: 0) == false)

        let probed = capabilities
            .recording(command: "GetAudioCfg", present: true)
            .recording(command: "GetManualRec", present: true)

        #expect(probed.supportsSpeakerVolume(channel: 0))
        #expect(probed.supportsManualRecord(channel: 0))
    }

    @Test("Quick reply belongs to the doorbell and auto track to the TrackMix")
    func perCameraControls() throws {
        let capabilities = try abilities()

        #expect(capabilities.supportsQuickReply(channel: 0))
        #expect(capabilities.supportsQuickReplyPlayback(channel: 0))
        #expect(capabilities.supportsQuickReply(channel: 1) == false)
        #expect(capabilities.supportsQuickReplyPlayback(channel: 1) == false)

        #expect(capabilities.supportsAutoTrack(channel: 1))
        #expect(capabilities.supportsAutoTrack(channel: 0) == false)
    }

    @Test("A camera can play a stored reply without carrying the auto-reply settings")
    func quickReplyPlaybackWithoutSettings() throws {
        let json = """
        [{"cmd":"GetAbility","code":0,"value":{"Ability":{"abilityChn":[\
        {"supportAudioFileList":{"permit":6,"ver":1},"supportAutoReply":{"permit":0,"ver":0},\
        "supportQuickReplyPlay":{"permit":6,"ver":1}}]}}}]
        """
        let capabilities = try #require(
            try JSONDecoder().decode([GetAbility.Response].self, from: Data(json.utf8)).first
        ).capabilities

        #expect(capabilities.supportsQuickReply(channel: 0) == false)
        #expect(capabilities.supportsQuickReplyPlayback(channel: 0))
    }

    @Test("Both siren keys gate the siren")
    func siren() throws {
        let capabilities = try abilities()

        #expect(capabilities.supportsSiren(channel: 0))
        #expect(capabilities.supportsSiren(channel: 1))
        #expect(capabilities.supportsSiren(channel: 2) == false)
    }
}
