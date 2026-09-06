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
}
