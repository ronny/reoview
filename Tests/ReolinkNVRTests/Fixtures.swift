import Foundation

/// Recorded response bodies, in the shapes that `reolink_aio` documents.
///
/// They are string literals because the package manifest carries no resource
/// rule for this target.
enum Fixture {
    static let login = """
    [{"cmd":"Login","code":0,"value":{"Token":{"leaseTime":3600,"name":"e7d2c8f0a1b34567"}}}]
    """

    static let secondLogin = """
    [{"cmd":"Login","code":0,"value":{"Token":{"leaseTime":3600,"name":"9f10bc22de334455"}}}]
    """

    static let loginRejected = """
    [{"cmd":"Login","code":1,"error":{"detail":"login failed","rspCode":-7}}]
    """

    static let badToken = """
    [{"cmd":"GetDevInfo","code":1,"error":{"detail":"please login first","rspCode":-6}}]
    """

    static let abilityError = """
    [{"cmd":"GetEnc","code":1,"error":{"detail":"ability error","rspCode":-9}}]
    """

    static let devInfo = """
    [{"cmd":"GetDevInfo","code":0,"value":{"DevInfo":{"B485":0,"IOInputNum":0,"IOOutputNum":0,\
    "audioNum":0,"buildDay":"build 23061923","cfgVer":"v3.1.0.0","channelNum":8,"detail":"IPC_NVR",\
    "diskNum":1,"exactType":"NVR","firmVer":"v3.6.5.562","hardVer":"RLN8-410","itemNo":"P400",\
    "model":"RLN8-410","name":"NVR","serial":"9527000012345678","type":"NVR","wifi":0}}}]
    """

    /// The same response with `DevInfo` wrapped in a one-element array, which
    /// some firmwares do.
    static let devInfoWrappedInArray = """
    [{"cmd":"GetDevInfo","code":0,"value":{"DevInfo":[{"channelNum":8,"exactType":"NVR",\
    "firmVer":"v3.6.5.562","hardVer":"RLN8-410","model":"RLN8-410","name":"NVR",\
    "serial":"9527000012345678","type":"NVR"}]}}]
    """

    static let channelStatus = """
    [{"cmd":"GetChannelstatus","code":0,"value":{"count":8,"status":[\
    {"channel":0,"name":"Front Door","online":1,"sleep":0,"typeInfo":"Reolink Video Doorbell PoE","uid":"95270005AAAAAAAA"},\
    {"channel":1,"name":"Driveway","online":1,"sleep":0,"typeInfo":"Reolink TrackMix PoE","uid":"95270005BBBBBBBB"},\
    {"channel":2,"name":"0","online":1,"typeInfo":"IPC","uid":""},\
    {"channel":3,"name":"0","online":0}]}}]
    """

    static let ability = """
    [{"cmd":"GetAbility","code":0,"value":{"Ability":{\
    "abilityChn":[\
    {"mainEncType":{"permit":0,"ver":0},"ptzCtrl":{"permit":64,"ver":0},"supportAutoTrackStream":{"permit":0,"ver":0},"supportAiPeople":{"permit":0,"ver":1}},\
    {"mainEncType":{"permit":0,"ver":1},"ptzCtrl":{"permit":64,"ver":3},"supportAutoTrackStream":{"permit":0,"ver":1},"supportAiPeople":{"permit":0,"ver":1}}],\
    "cloudStorage":{"permit":0,"ver":0},"devInfo":{"permit":64,"ver":1},"p2p":{"permit":0,"ver":1},\
    "scheduleVersion":{"permit":64,"ver":1},"talk":{"permit":0,"ver":0}}}}]
    """

    /// Channel 1 of the NVR: H.265 main, H.264 sub.
    static let encTelephotoChannel = """
    [{"cmd":"GetEnc","code":0,"value":{"Enc":{"audio":1,"channel":1,\
    "mainStream":{"bitRate":6144,"frameRate":25,"gop":4,"height":2160,"profile":"High","size":"3840*2160","vType":"h265","width":3840},\
    "subStream":{"bitRate":256,"frameRate":10,"gop":4,"height":480,"profile":"High","size":"640*480","vType":"h264","width":640}}}}]
    """

    /// `GetEvents` for the doorbell. `md` carries no `support` field, `ai`
    /// carries a smart-AI entry that arrives as an array.
    static let eventsDoorbell = """
    [{"cmd":"GetEvents","code":0,"value":{"ai":{\
    "crossline":[{"alarm_state":0,"index":0,"support":1}],\
    "dog_cat":{"alarm_state":0,"support":0},\
    "face":{"alarm_state":0,"support":0},\
    "people":{"alarm_state":1,"support":1},\
    "vehicle":{"alarm_state":0,"support":1}},\
    "channel":0,"md":{"alarm_state":1},"visitor":{"alarm_state":1,"support":1}}}]
    """

    static let eventsTwoChannels = """
    [{"cmd":"GetEvents","code":0,"value":{"ai":{"people":{"alarm_state":0,"support":1}},\
    "channel":0,"md":{"alarm_state":0},"visitor":{"alarm_state":0,"support":1}}},\
    {"cmd":"GetEvents","code":0,"value":{"ai":{"people":{"alarm_state":1,"support":1},\
    "vehicle":{"alarm_state":0,"support":1}},"channel":1,"md":{"alarm_state":1}}}]
    """

    static let mdState = """
    [{"cmd":"GetMdState","code":0,"value":{"state":1}}]
    """

    /// The pre-3.0.0.494 shape, where every AI type is a bare `Int`.
    static let aiStateLegacy = """
    [{"cmd":"GetAiState","code":0,"value":{"channel":0,"dog_cat":0,"face":0,"people":1,"vehicle":0}}]
    """

    static let aiState = """
    [{"cmd":"GetAiState","code":0,"value":{"channel":0,"face":{"alarm_state":0,"support":0},\
    "people":{"alarm_state":0,"support":1},"vehicle":{"alarm_state":1,"support":1}}}]
    """

    static let logout = """
    [{"cmd":"Logout","code":0,"value":{"rspCode":200}}]
    """

    /// `GetAbility` with the keys that gate the milestone 4 controls, in the
    /// versions the RLN8-410 reports. Channel 0 is the doorbell, channel 1 the
    /// TrackMix, channel 2 an empty slot.
    static let abilityControls = """
    [{"cmd":"GetAbility","code":0,"value":{"Ability":{\
    "abilityChn":[\
    {"aiTrack":{"permit":0,"ver":0},"alarmAudio":{"permit":0,"ver":1},"floodLight":{"permit":0,"ver":0},\
    "ptzPreset":{"permit":0,"ver":0},"ptzType":{"permit":0,"ver":0},"supportAudioAlarm":{"permit":0,"ver":1},\
    "supportAudioFileList":{"permit":6,"ver":1},"supportAutoReply":{"permit":6,"ver":1},\
    "supportAutoTrackStream":{"permit":0,"ver":0},"supportDigitalZoom":{"permit":0,"ver":0},\
    "supportFLswitch":{"permit":0,"ver":0},"supportPtzSpeed":{"permit":0,"ver":0},\
    "supportQuickReplyPlay":{"permit":6,"ver":1}},\
    {"aiTrack":{"permit":6,"ver":1},"alarmAudio":{"permit":0,"ver":1},"floodLight":{"permit":6,"ver":2},\
    "ptzPreset":{"permit":7,"ver":1},"ptzType":{"permit":7,"ver":3},"supportAudioAlarm":{"permit":0,"ver":1},\
    "supportAudioFileList":{"permit":0,"ver":0},"supportAutoReply":{"permit":0,"ver":0},\
    "supportAutoTrackStream":{"permit":6,"ver":1},"supportDigitalZoom":{"permit":6,"ver":1},\
    "supportFLswitch":{"permit":6,"ver":1},"supportPtzSpeed":{"permit":6,"ver":1},\
    "supportQuickReplyPlay":{"permit":0,"ver":0}},\
    {"aiTrack":{"permit":0,"ver":0},"ptzType":{"permit":0,"ver":0}}],\
    "devInfo":{"permit":64,"ver":1},"scheduleVersion":{"permit":64,"ver":1}}}}]
    """

    /// Every control command that only acts answers like this.
    static func acknowledgement(_ cmd: String) -> String {
        """
        [{"cmd":"\(cmd)","code":0,"value":{"rspCode":200}}]
        """
    }

    /// Slot 2 is empty, so `enable` is 0 and `reolink_aio` drops it.
    static let ptzPresets = """
    [{"cmd":"GetPtzPreset","code":0,"value":{"PtzPreset":[\
    {"channel":1,"enable":1,"id":1,"name":"Driveway"},\
    {"channel":1,"enable":0,"id":2,"name":""},\
    {"channel":1,"enable":1,"id":3,"name":"Gate"}]}}]
    """

    /// Some firmwares send `id` and `enable` as strings.
    static let ptzPresetsWithStringNumbers = """
    [{"cmd":"GetPtzPreset","code":0,"value":{"PtzPreset":[\
    {"channel":1,"enable":"1","id":"1","name":"Driveway"}]}}]
    """

    static let ptzGuard = """
    [{"cmd":"GetPtzGuard","code":0,"value":{"PtzGuard":\
    {"benable":1,"bexistPos":1,"channel":1,"timeout":60}}}]
    """

    /// The `action: 1` shape. The position sits under `value` and the range
    /// under `range`, one level deeper.
    static let zoomFocus = """
    [{"cmd":"GetZoomFocus","code":0,\
    "value":{"ZoomFocus":{"channel":1,"focus":{"pos":32},"zoom":{"pos":4}}},\
    "range":{"ZoomFocus":{"channel":1,"focus":{"pos":{"max":223,"min":0}},"zoom":{"pos":{"max":33,"min":0}}}}}]
    """

    static let zoomFocusWithoutRange = """
    [{"cmd":"GetZoomFocus","code":0,"value":{"ZoomFocus":{"channel":1,"focus":{"pos":32},"zoom":{"pos":4}}}}]
    """

    /// The TrackMix reports auto track as `bSmartTrack`.
    static let aiCfgSmartTrack = """
    [{"cmd":"GetAiCfg","code":0,"value":{"aiDisappearBackTime":30,"aiStopBackTime":15,\
    "aiTrack":2,"bSmartTrack":1,"channel":1},\
    "range":{"aiDisappearBackTime":[5,60],"aiStopBackTime":[15,60],"aiTrack":[2,3,4],"channel":1}}]
    """

    /// A camera without `bSmartTrack`. `aiTrack` then carries the on/off state.
    static let aiCfgAiTrack = """
    [{"cmd":"GetAiCfg","code":0,"value":{"aiTrack":0,"channel":1}}]
    """

    static let whiteLed = """
    [{"cmd":"GetWhiteLed","code":0,"value":{"WhiteLed":{"bright":100,"channel":1,\
    "LightingSchedule":{"EndHour":6,"EndMin":0,"StartHour":18,"StartMin":30},"mode":1,"state":0}}}]
    """

    static let audioFileList = """
    [{"cmd":"GetAudioFileList","code":0,"value":{"AudioFileList":[\
    {"channel":0,"fileName":"Please leave the parcel","id":0},\
    {"channel":0,"fileName":"We will be right there","id":1}]}}]
    """

    /// A camera that holds no recordings sends null, not an empty array.
    static let audioFileListEmpty = """
    [{"cmd":"GetAudioFileList","code":0,"value":{"AudioFileList":null}}]
    """

    static let autoReply = """
    [{"cmd":"GetAutoReply","code":0,"value":{"AutoReply":{"channel":0,"enable":1,"fileId":1,"timeout":10}}}]
    """

    static let audioCfg = """
    [{"cmd":"GetAudioCfg","code":0,"value":{"AudioCfg":{"channel":0,"talkAndReplyVolume":80,\
    "visitorLoudspeaker":1,"visitorVolume":60,"volume":70}}}]
    """

    static let manualRec = """
    [{"cmd":"GetManualRec","code":0,"value":{"Rec":{"channel":0,"duration":600,"enable":1}}}]
    """

    /// The firmware bug that puts a value above 1 in `enable`.
    static let manualRecStuck = """
    [{"cmd":"GetManualRec","code":0,"value":{"Rec":{"channel":0,"enable":3}}}]
    """
}
