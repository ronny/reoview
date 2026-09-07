# Baichuan two-way talk — research

Read on 2026-09-06. The question: can ReoView do two-way talk to the Front Door
doorbell (channel 0) through the RLN8-410 on `192.168.8.215:9000`, from Swift?

Every claim below names the file and repo it came from. Where sources disagree,
the disagreement is recorded, not smoothed over.

## Answers first

| Question | Answer |
|---|---|
| Does talk work through the NVR? | **Yes. Measured on this NVR on 2026-09-06.** `TalkConfig` returns 200 for channel 0, and the NVR immediately streams the doorbell's live microphone back. See [Measured against the device](#measured-against-the-device-2026-09-06), which corrects several claims below. |
| Audio format | IMA/DVI-4 ADPCM, 16000 Hz, 16-bit, mono, 1024 samples per block. Confirmed by the device. Read it from `TalkAbility` anyway. |
| Effort | Two to four days for a working prototype, on top of an existing Baichuan client. There is no Baichuan client in ReoView today, so add three to five days for transport, login and encryption. |
| Existing Swift code | Yes. `jestatsio/reolens` (MIT) has a Swift Baichuan client with a talkback file. Transport and login look sound. The talk frame layout is a guess and does not match the working implementations. |
| Quick-reply upload | No public upload path exists in any source read. See [Quick-reply clips](#quick-reply-clips-and-uploading). |

## Measured against the device, 2026-09-06

The sections below were written from source code. This section was written from
the NVR. Where they disagree, this section is right.

Probed against the RLN8-410 at `192.168.8.215:9000`, firmware v3.6.5.562, on
channel 0, the Video Doorbell PoE. No audio was ever sent, so the doorbell
speaker was never used.

### Talk works through the NVR

`TalkConfig`, message id 201, built from the device's own `TalkAbility` and sent
with `mixAudioStream`, answers **status 200**.

The 200 is not a blanket accept. Controls on the same connection:

| Request | Status |
|---|---|
| Message 10 on channels 2, 5 and 7, which have no camera | 400 |
| Message 201 on channels 2, 5 and 7 | 400 |
| Message 201 on channel 0 with a deliberately wrong config | 400 |
| Message 201 on channel 0 with the config the device asked for | 200 |

A 400 for the wrong codec is only possible if something parses the config.

Then the decisive part. After the 200, with nothing further sent, the NVR
streams unsolicited message id 202 back at 15.8 messages per second, in
4160-byte payloads, until message 11 releases the session. The payload decodes
to int16 audio of a quiet room: 192,660 samples, minimum -297, maximum 299, RMS
48.4. One `00 00 00 01` start code in 128 KB rules out video.

The NVR therefore does not merely forward a small XML query. It opens a live
audio path to a camera on its PoE port and carries the camera's microphone
across it.

`followVideoStream` also returns 200 but sends nothing back. Use
`mixAudioStream`.

### Corrections to the sections below

1. **FullAes is compulsory, not a case to mitigate.** This firmware answers only
   the encryption word `12dc`. `03dc`, `02dc`, `01dc` and `00dc` each get
   silence on an accepted connection. A Swift client needs AES from the first
   commit.
2. **A binary payload is encrypted.** Under FullAes the extension carries
   `<encryptLen>N</encryptLen><binaryData>1</binaryData>`, and the first N bytes
   of the payload are AES-128-CFB under the session key. The inbound frames are
   a working example to copy for the outbound direction.
3. **`audioTalk` does not exist** in the message 199 response on this firmware.
   Only `ipcAudioTalk`, which is 1 on the two populated channels and 0 on the
   ten empty ones. Code that looks for `audioTalk` finds nothing.
4. **Status 300 is a success** for message 199. Accept 200, 201 and 300.
5. **`mixAudioStream` is offered**, against the dissector notes, and it is the
   mode that opens the return path.
6. **An inbound 202 extension carries no `channelId`.** The channel is only in
   header byte 12, as `channel + 1`.
7. **No 422 was seen** in six runs of opening and releasing the session.
8. **Reolink's support article is about the NVR's own front panel**, not a
   network client. It does not apply here.

### TalkAbility, verbatim

Channel 0 and channel 1 return byte-identical XML.

```xml
<TalkAbility version="1.1">
<duplexList><duplex>FDX</duplex></duplexList>
<audioStreamModeList>
<audioStreamMode>followVideoStream</audioStreamMode>
<audioStreamMode>mixAudioStream</audioStreamMode>
</audioStreamModeList>
<audioConfigList><audioConfig>
<priority>0</priority>
<audioType>adpcm</audioType>
<sampleRate>16000</sampleRate>
<samplePrecision>16</samplePrecision>
<lengthPerEncoder>1024</lengthPerEncoder>
<soundTrack>mono</soundTrack>
</audioConfig></audioConfigList>
</TalkAbility>
```

### Talk works. Three of the guesses above were wrong

The doorbell played a clean 700 Hz tone and then intelligible speech on
2026-09-07. What made the difference came from a packet capture of Reolink's own
macOS app talking to this NVR, not from reasoning about the sources.

Before the capture, every block was accepted without error and nothing came out
of the speaker. A wrong frame is discarded in silence.

Two things were wrong, and two others only looked wrong.

**The two that mattered:**

| Field | What was assumed | What the app sends |
|---|---|---|
| Binary payload of message 202 | AES encrypted, with `encryptLen` declared, mirroring the inbound frames | **Plaintext.** The extension stays encrypted. |
| `corr` on message 202 | the number the talk session was opened with | **0** |

**The two that did not matter.** The capture also showed the BcMedia header
differing, and it is tempting to record that as part of the fix. It was not.
The run that first made the doorbell speak still used the `neolinkRust` rules,
because the client's configuration defaulted to them and only
`BcMedia.adpcmFrame` had been changed. So the device accepted a frame four
bytes longer, carrying 256 where the vendor sends 2, and played it correctly.

| Field | neolink Rust | Reolink's app | Device behaviour |
|---|---|---|---|
| Offset 10 | 256 | 2 | ignored |
| Padding | 4 bytes | none | ignored |

neolink's parser guesses as much: "on some camera this value is just 2". This
NVR ignores both. `reolinkApp` is the default now anyway, because matching the
vendor byte for byte is the safer bet on firmware nobody here has seen, but it
is a preference and not a fix.

The vendor's header, for reference:

```
30 31 77 62 08 02 08 02 00 01 02 00     "01wb", 520, 520, 0x0100, 2
```

The encoder needed no change. ADPCM nibble order, the DVI state header and the
pacing were all right first time, which the steady tone confirms.

Two smaller findings from the doorbell:

- Releasing the slot 100 ms after the last block cuts the final word. The device
  plays from its own buffer. 400 ms of trailing silence and an 800 ms playout
  wait fixed it.
- Audio carries a little crackle. It was not localised. There is no clipping,
  and IMA ADPCM at 16 kHz is a lossy format, so some roughness is expected.

### How the capture was taken

The official Reolink app runs on macOS and can talk to a doorbell behind this
NVR. Quit it, start a capture, then start it again so the login is included:

```bash
sudo tcpdump -i any -s 0 -w talk.pcap 'host 192.168.8.215 and port 9000'
```

macOS writes pcapng, not pcap. Frame headers are plaintext, so message ids,
lengths, `corr` and the payload offset can be read without any key.

## Sources

Ordered by trust.

| Source | What it gave |
|---|---|
| `QuantumEntangledAndy/neolink`, `crates/core/src/bc/` and `crates/core/src/bc_protocol/talk.rs` | The only complete, working talk implementation read. Rust. |
| `QuantumEntangledAndy/neolink`, `dissector/protocol.md`, `dissector/messages.md`, `dissector/mediapacket.md` | The protocol notes carried over from `thirtythreeforty/neolink`. Real packet captures. |
| `starkillerOG/reolink_aio`, `reolink_aio/baichuan/` | Header parsing, login, encryption, keepalive, channel addressing. No talk. |
| `borexola/neolink.net`, `src/Neolink.Server/` | Independent C# reimplementation with talk. Useful as a second opinion. |
| `joeblack2k/reolink_talk`, `custom_components/reolink_talk/talk.py` | Python port of neolink talk layered on `reolink_aio`. |
| `reolink/reolink-cli`, `skills/reolink-cli/references/voice-alert.md` | Vendor documentation (`NOTICE`: "Copyright 2026 Reolink"). Confirms message ids 201/202 and the audio format. |
| `jestatsio/reolens`, `Sources/ReolinkBaichuan/` | A Swift Baichuan client. |
| `mnpg/Reolink_api_documentations`, `official/Camera HTTP API User Guide_v8.pdf` | The public HTTP API. Read to prove an absence. |

## Transport and framing

One TCP connection to port 9000. Every message is a header plus a body. The body
may hold an Extension XML, a payload, or both.

### Header

All fields little-endian. Offsets in bytes.

```
0   u32   magic          f0 de bc 0a   (client <-> device)
4   u32   message id
8   u32   body length    extension + payload, on-wire bytes
12  u8    channel / encryption offset
13  u8    stream type    0 = clear, 1 = fluent, 4 = balanced
14  u16   message number
16  u16   status code, or the encryption word during login
18  u16   message class
20  u32   payload offset  -- only when class is 14 64 or 00 00
```

Layout from `crates/core/src/bc/ser.rs`, function `bc_header`, and
`crates/core/src/bc/de.rs`, function `bc_header`
(`QuantumEntangledAndy/neolink`). Confirmed against
`reolink_aio/baichuan/base_protocol.py`, `parse_bc_data`, and
`dissector/protocol.md`.

Bytes 12 to 15 are one 4-byte block that the device echoes back verbatim. The two
reference implementations divide it differently:

| Source | Byte 12 | Byte 13 | Bytes 14-15 |
|---|---|---|---|
| neolink `bc/ser.rs` | `channel_id` | `stream_type` | `msg_num` u16 |
| reolink_aio `baichuan.py` `send()` | `ch_id` (channel + 1; 250 = host, 251 = push) | counter (3 bytes, 12-15) | |
| `dissector/protocol.md` | channel id | stream id | unknown, then message handle |

Both work, because the device treats the block as an opaque correlation id. Byte
12 is load-bearing for one other reason: it is the XOR key offset for
`BCEncrypt`. `reolink_aio/baichuan/baichuan.py` line ~307 comments this
explicitly (`# enc_offset = ch_id`), and `crates/core/src/bc/ser.rs` passes
`self.meta.channel_id as u32` as `enc_offset`.

`reolink_aio` rejects a reply whose bytes 12-15 differ from the request
(`baichuan.py`, "message id error for cmd_id"). Copy that check.

### Message class

The class at offset 18 decides the header length.

| Bytes at 18 | u16 | Meaning | Header |
|---|---|---|---|
| `14 65` | 0x6514 | Legacy body | 20 bytes |
| `14 66` | 0x6614 | Modern body, no payload offset | 20 bytes |
| `14 64` | 0x6414 | Modern body, has payload offset | 24 bytes |
| `00 00` | 0x0000 | Modern body, has payload offset | 24 bytes |

From `crates/core/src/bc/model.rs`, `BcHeader::is_modern` and
`has_payload_offset`, and `reolink_aio/baichuan/base_protocol.py`,
`parse_bc_data`.

"Legacy" is not a firmware generation. It is one message shape, used for exactly
one message: the first login packet. `reolink_aio` does not even parse an
incoming legacy body — it raises "with legacy message class, parsing not
implemented" (`base_protocol.py`). Everything this app needs is modern, class
`14 64`. Firmware v3.6.5.562 is far newer than the split.

### Payload offset

For a 24-byte header, `payload offset` is the length of the Extension XML in
on-wire bytes. The payload runs from there to `body length`. If the offset is 0
there is no Extension. If the offset equals the body length there is no payload.
A header-only message has both at 0. From `crates/core/src/bc/model.rs`, the
`ModernMsg` doc comment, and `dissector/protocol.md`.

The Extension describes the payload. Its two important fields:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<Extension version="1.1">
<binaryData>1</binaryData>
<channelId>0</channelId>
</Extension>
```

`binaryData` of 1 puts that message number into binary mode. The receiver must
then treat the payload of every later message with the same message number as
bytes, not XML, until it sees `binaryData` 0. From `crates/core/src/bc/codex.rs`,
`Decoder::decode` (`binary_on` / `binary_off` keyed on `msg_num`).

### Message ids that matter

From `crates/core/src/bc/model.rs` (`QuantumEntangledAndy/neolink`) and, where
noted, `reolink_aio/baichuan/baichuan.py`.

| Id | Name | Use |
|---|---|---|
| 1 | Login | Both halves of the handshake |
| 2 | Logout | |
| 10 | TalkAbility | Ask what audio the device accepts |
| 11 | TalkReset | Release the talk slot |
| 93 | Ping / LinkType | Keepalive. `reolink_aio` `_keepalive_loop` sends this |
| 199 | Support | Carries `audioTalk` and `ipcAudioTalk` |
| 201 | TalkConfig | Open a talk session |
| 202 | Talk | Carry the audio |
| 234 | UDP keep alive | Device-initiated. Answer with status 200 |
| 347 | GetAudioFileList | `reolink_aio` `GetAudioFileList` |
| 349 | QuickReplyPlay | `reolink_aio` `QuickReplyPlay` |
| 427 / 428 | Get / Set AutoReply | `reolink_aio` |

## Login and encryption

### Handshake

Four steps. From `crates/core/src/bc_protocol/login.rs` and
`reolink_aio/baichuan/baichuan.py` (`_get_nonce`, `login`).

**1. Ask for the nonce.** Send message id 1, class `14 65`, body length 0. Put
the encryption request in the status field.

| Max encryption wanted | Bytes at offset 16 |
|---|---|
| None | `00 dc` |
| BCEncrypt | `01 dc` |
| AES | `12 dc` |

`reolink_aio` always sends `12 dc`. neolink defaults to the same
(`MaxEncryption::Aes`).

`neolink` can also send the full 1836-byte legacy login with MD5 user and
password (`crates/core/src/bc/ser.rs`, `bc_legacy`), but its login path sends
`LoginUpgrade`, which is a header only. Send the header only.

**2. Read the nonce.** The reply comes back class `14 66`, 20-byte header, body
XOR-encrypted with `BCEncrypt`. It contains:

```xml
<Encryption version="1.1"><nonce>...</nonce></Encryption>
```

The status field of the reply is `<level> dd`. The low byte is the cipher the
device chose.

| Low byte | Cipher |
|---|---|
| 0x00 | None |
| 0x01 | BCEncrypt |
| 0x02 | AES |
| 0x12 | AES, media also encrypted (`FullAes`) |

From `crates/core/src/bc/codex.rs`, `Decoder::decode`. `reolink_aio` also accepts
`03dd` as AES (`baichuan.py`, `_decrypt`), and `dissector/protocol.md` says the
client asks for 3 and the camera answers 2. Accept 0x02, 0x03 and 0x12 as AES.

**3. Send the modern login.** Message id 1, class `14 64`, body still
`BCEncrypt` — the AES key is not usable until the login is accepted. neolink
forces this in `crates/core/src/bc/codex.rs` (`Encoder::encode`, "During login
the encryption protocol cannot go higher than BCEncrypt"), and `reolink_aio`
passes `enc_type=EncType.BC` for cmd 1.

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<body>
<LoginUser version="1.1">
<userName>MD5_31(username + nonce)</userName>
<password>MD5_31(password + nonce)</password>
<userVer>1</userVer>
</LoginUser>
<LoginNet version="1.1">
<type>LAN</type>
<udpPort>0</udpPort>
</LoginNet>
</body>
```

`MD5_31` is the uppercase hex MD5 truncated to 31 characters. The 32nd character
is dropped because the camera firmware compares a 32-byte buffer with a trailing
NUL. From `crates/core/src/bc_protocol.rs`, `md5_string` and `test_md5_string`,
and `reolink_aio/baichuan/util.py`, `md5_str_modern`.

**4. Read `DeviceInfo`.** Status 200 means logged in. Status 401 means bad
credentials (`reolink_aio/baichuan/base_protocol.py`).

### The AES key

```
key_phrase = "<nonce>-<password>"
hash       = uppercase_hex(md5(key_phrase))      # 32 chars
aes_key    = first 16 ASCII bytes of hash        # not the first 16 digest bytes
```

From `crates/core/src/bc_protocol/credentials.rs`, `make_aeskey`, and
`reolink_aio/baichuan/util.py` plus `baichuan.py` `_get_nonce`
(`md5_str_modern(f"{self._nonce}-{self._password}")[0:16]`).

Cipher is AES-128 in CFB mode with a 128-bit segment. The IV is the ASCII string
`0123456789abcdef`. From `crates/core/src/bc/crypto.rs` (`IV`, `Aes128CfbEnc`)
and `reolink_aio/baichuan/baichuan.py` (`AES.new(..., mode=AES.MODE_CFB, iv=AES_IV,
segment_size=128)`).

Note the CFB state is not carried between messages. Both implementations build a
fresh cipher per message: neolink clones the cipher (`enc.clone().encrypt(...)`
in `crypto.rs`), `reolink_aio` calls `AES.new` on every call.

### BCEncrypt

A rotating XOR. From `crates/core/src/bc/crypto.rs` and
`reolink_aio/baichuan/util.py`:

```
XML_KEY = [0x1F, 0x2D, 0x3C, 0x4B, 0x5A, 0x69, 0x78, 0xFF]
out[i]  = in[i] ^ XML_KEY[(offset + i) % 8] ^ (offset & 0xFF)
```

`offset` is header byte 12.

### What is encrypted

The header is never encrypted. The Extension and the payload are each encrypted
separately, then concatenated. `crates/core/src/bc/ser.rs` calls
`encryption_protocol.encrypt` once for the Extension and once for the payload.
`reolink_aio` does the same:
`enc_body_bytes = self._aes_encrypt(ext_bytes) + self._aes_encrypt(body_bytes)`.

**A binary payload is not encrypted.** `crates/core/src/bc/ser.rs`,
`bc_payload`, returns `BcPayloads::Binary(x) => x.to_owned()` with no cipher
applied. `joeblack2k/reolink_talk` (`talk.py`, `send_talk_binary`) makes the same
choice and spells out the consequence: the header's `body length` and
`payload offset` must then be **on-wire byte counts**, because the encrypted
Extension and the plaintext binary have different lengths from their plaintext
forms. For AES-CFB the ciphertext is the same length as the plaintext, so this
only bites if padding is ever introduced. Compute both fields from the bytes you
are about to write.

### Keepalive

`reolink_aio` sends message id 93 every 30 seconds, measured from the last
receive, and backs the interval down to 9 seconds if the connection drops early
(`baichuan.py`: `KEEP_ALLIVE_INTERVAL = 30`, `MIN_KEEP_ALLIVE_INTERVAL = 9`,
`_keepalive_loop`).

The device also sends message id 234 on its own. Answer it with a header-only
message, same message number, status 200, class `14 64`. From
`crates/core/src/bc_protocol/keepalive.rs` and
`reolink_aio/baichuan/base_protocol.py` `_send_heartbeat_response`.

## Talk

Four messages. All carry `<channelId>` in the Extension and the channel in
header byte 12.

### 1. Ask what the device accepts — message id 10

Extension only, no payload:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<Extension version="1.1">
<channelId>0</channelId>
</Extension>
```

The reply (`dissector/messages.md`, entry 10):

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<body>
<TalkAbility version="1.1">
<duplexList><duplex>FDX</duplex></duplexList>
<audioStreamModeList><audioStreamMode>followVideoStream</audioStreamMode></audioStreamModeList>
<audioConfigList>
<audioConfig>
<priority>0</priority>
<audioType>adpcm</audioType>
<sampleRate>16000</sampleRate>
<samplePrecision>16</samplePrecision>
<lengthPerEncoder>1024</lengthPerEncoder>
<soundTrack>mono</soundTrack>
</audioConfig>
</audioConfigList>
</TalkAbility>
</body>
```

Read the lists, do not assume. `joeblack2k/reolink_talk` (`talk.py`,
`parse_talk_ability`) prefers `FDX` from `duplexList` and `mixAudioStream` from
`audioStreamModeList` when present. `reolink_aio` treats the presence of
`mixAudioStream` as the marker for two-way audio support
(`baichuan.py` line ~2191).

`reolink_aio` only sends message id 10 when the HTTP ability `talk` is above 0
(`baichuan.py` line ~2020). The NVR reports `talk = 1` for channel 0 here.

### 2. Open the session — message id 201

Extension is `<channelId>`. Payload is `TalkConfig`, copied from the ability the
device just reported. From `dissector/messages.md` entry 201,
`crates/core/src/bc_protocol/talk.rs`, and
`src/Neolink.Server/Protocol/BcCamera.cs` `SendTalkConfigAsync`
(`borexola/neolink.net`):

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<body>
<TalkConfig version="1.1">
<channelId>0</channelId>
<duplex>FDX</duplex>
<audioStreamMode>followVideoStream</audioStreamMode>
<audioConfig>
<audioType>adpcm</audioType>
<sampleRate>16000</sampleRate>
<samplePrecision>16</samplePrecision>
<lengthPerEncoder>1024</lengthPerEncoder>
<soundTrack>mono</soundTrack>
</audioConfig>
</TalkConfig>
</body>
```

Status 200 means the slot is yours. Status 422 means someone else holds it — the
phone app, another client, or your own crashed session. Send message id 11, then
retry once. `crates/core/src/bc_protocol/talk.rs` says the official client does
exactly this. `src/Neolink.Server/Protocol/BcCamera.cs` repeats it, and its
comment names the other holder: "another talker (phone app, NVR) holds it".

`reolink/reolink-cli`, `skills/reolink-cli/references/troubleshooting.md`, is
blunt about the constraint: "device permits ONE talk session globally".

Status 400 has been seen when the XML shape is wrong.
`joeblack2k/reolink_talk` (`talk.py`, `build_talk_config_variants`) retries with
the XML declaration stripped and with the `<body>` wrapper stripped. That is a
sign of firmware variation, not a documented rule.

### 3. Stream the audio — message id 202

One message number for the whole stream. Extension on every message:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<Extension version="1.1">
<binaryData>1</binaryData>
<channelId>0</channelId>
</Extension>
```

Payload is one or more BcMedia ADPCM frames, unencrypted.
`dissector/messages.md` entry 202 notes: "No reply from camera."
`crates/core/src/bc_protocol/talk.rs` `talk_stream` nevertheless awaits a reply
per message; `talk` does not. `joeblack2k/reolink_talk` awaits with a 5-second
timeout and says some firmware silently drops packets otherwise. Treat the
reply as optional.

### 4. Release — message id 11

Extension `<channelId>` only, no payload. Expect 200.
`crates/core/src/bc_protocol/talk.rs` `talk_stop`.

Send it in a `defer`-style path. `src/Neolink.Server/Protocol/BcCamera.cs`:
"Release the speaker even when the caller's token is already cancelled —
otherwise the camera stays busy for the next talker." It uses a fresh 3-second
timeout for the release.

### Audio format

| Field | Value | Meaning |
|---|---|---|
| `audioType` | `adpcm` | IMA / DVI-4 4-bit ADPCM |
| `sampleRate` | 16000 | Hz |
| `samplePrecision` | 16 | Input PCM bit depth |
| `soundTrack` | `mono` | 1 channel |
| `lengthPerEncoder` | 1024 | Samples per ADPCM block |

`crates/core/src/bc/xml.rs` documents `lengthPerEncoder` as "Number of audio
samples this should be twice the block size for adpcm".
`crates/core/src/bc_protocol/talk.rs` derives:

```
block_size      = lengthPerEncoder / 2      = 512 bytes of packed nibbles
full_block_size = block_size + 4            = 516 bytes, with the DVI state header
```

So one block is 1024 samples, 64 ms at 16 kHz.

`crates/core/src/bc_protocol/talk.rs` refuses anything but `adpcm`
(`if &talk_config.audio_config.audio_type != "adpcm" { return Err(...) }`).
AAC exists in the Baichuan media stream (`dissector/mediapacket.md` lists an AAC
media packet) but is an inbound codec. No source sends AAC for talk.

Does this differ per model? The vendor CLI says the rate comes from the device:
"**Must** feed PCM16 LE mono at a sample rate the device advertises (verify via
`reolink-cli raw 10`). E1 Outdoor confirmed: 16 kHz / 16-bit / mono"
(`reolink/reolink-cli`, `skills/reolink-cli/references/voice-alert.md`).
`joeblack2k/reolink_talk` says a device is usable "only if the device reports
`TalkAbility` with `audioType=adpcm`" (its `README.md`).

For a Doorbell PoE specifically: no source reads a `TalkAbility` off that model.
Frigate discussion 11924 shows people running `neolink talk` against Reolink
doorbells at `<ip>:9000` directly, which implies ADPCM, since neolink refuses
anything else. Query message id 10 and use what comes back.

### The BcMedia ADPCM frame

From `crates/core/src/bcmedia/ser.rs`, `bcmedia_adpcm`, plus the surrounding
padding code and `dissector/mediapacket.md`:

```
0   u32 le  0x62773130      bytes 30 31 77 62, ASCII "01wb"
4   u16 le  block_len + 4
6   u16 le  block_len + 4   (repeated)
8   u16 le  0x0100          sub-magic
10  u16 le  half block size
12  ..      the ADPCM block: 4-byte DVI state header + packed nibbles
+   ..      zero padding to an 8-byte boundary
```

The DVI state header is `i16 le predictor`, `u8 step index`, `u8 reserved`.
From `src/Neolink.Server/Media/Adpcm.cs` (`borexola/neolink.net`) and
`crates/core/src/bcmedia/model.rs` ("One `data` should contain 4 bytes of the
adpcm predictor state then one block of adpcm samples").

Two fields are not agreed on between implementations:

| Field | neolink Rust `bcmedia/ser.rs` | neolink.net `Adpcm.cs` | For block_len 516 |
|---|---|---|---|
| half block size at offset 10 | `(block_len - 4) / 2` | `block_len / 2` | 256 vs 258 |
| padding base | `block_len % 8` | `(block_len + 4) % 8` | 4 pad bytes vs 0 |

neolink's own parser (`crates/core/src/bcmedia/de.rs`) reads the pad from
`payload_size % 8`, that is `(block_len + 4) % 8`, which contradicts its
serializer. It also says of the half-block field: "On some camera this value is
just 2. On other cameras is half the block size without the header." The field
is very likely ignored by the device. The padding is the riskier of the two.
Start with the Rust serializer, since that is the code known to drive real
cameras, and try the other rule if the device rejects the stream.

### Framing and pacing

`crates/core/src/bc_protocol/talk.rs`:

- `talk()` puts 4 ADPCM frames in one message id 202 payload.
- `talk_stream()` puts 1.
- After each message it sleeps for the playback duration of what it sent:

```
samples = (bytes_sent - 4 * blocks_in_message) * 2 + blocks_in_message
sleep   = samples / sampleRate
```

Four blocks of 516 bytes gives 4100 samples, about 256 ms.

`talk_stream` also keeps a running `expected_stream_end` so the pacer does not
drift, and waits for it plus 100 ms before sending message id 11 — otherwise
`TalkReset` cuts off audio the device has not played yet.

`joeblack2k/reolink_talk` (`talk.py`, `talk_playback`) reproduces the same
arithmetic in Python.

### Duplex and stopping

Only `FDX` has ever been observed in `duplexList`
(`dissector/messages.md`, `crates/core/src/bc/xml.rs`). No source describes a
half-duplex mode. In practice the limit is not duplex but exclusivity: one talk
session per device, enforced by the 422 reply.

The vendor CLI adds two operational rules
(`reolink/reolink-cli`, `references/voice-alert.md`):

- Cap a single clip near 90 seconds.
- Do not issue PTZ or preview commands on the same TCP connection while pushing
  audio, because they share the socket and stutter the pacer. The CLI now gives
  talk its own login.

## Through an NVR

### What the sources actually show

The protocol is built for it. Every talk message carries the channel twice: in
header byte 12 and in `<channelId>` inside the Extension and the `TalkConfig`.
`crates/core/src/bc_protocol/talk.rs` uses `self.channel_id` in both places for
messages 10, 11, 201 and 202. `neolink`'s `sample_config.toml` documents
`channel_id` as "If you use an NVR that relays several camera connections you
can choose which camera to connect to". Numbering is 0-based there, unlike the
official client.

`reolink_aio` addresses channels the same way and is used against NVRs daily by
Home Assistant. It sends message id 10 per channel through the NVR connection
(`baichuan.py` line ~2020) and records a `two_way_audio` capability from the
reply (line ~2191). So the NVR does relay the talk-ability query to the camera.

`crates/core/src/bc/xml.rs` has a `ipcAudioTalk` field in the `Support` message
(id 199), separate from `audioTalk`. "IPC audio talk" only makes sense as an
NVR-side flag about talking to an attached camera.

### What refutes it, or at least warns

Reolink's own support article, *Introduction to Two-Way Audio*, says: "If you
connect the cameras (except for battery-powered cameras) that support two-way
audio to the NVR, the Two-way audio function can not be used between the camera
and NVR since Reolink NVR does not have a microphone and doesn't support the
two-way audio feature." The RLN36 is the stated exception. That sentence is
about the NVR's own local interface, not about a network client, but it is the
vendor saying the NVR has no talk feature.

`joeblack2k/reolink_talk` `README.md` warns: "If a camera is connected to an
NVR, two-way audio may not be usable in some configurations," and cites that
same article.

`src/Neolink.Server/Protocol/BcCamera.cs` names the NVR as a possible holder of
the 422 lock, which implies an NVR can hold a talk session — but that is a
comment, not a demonstration.

Every working talk example found connects straight to a camera on port 9000.
Frigate discussion 11924 shows `address = "192.168.8.61:9000"` style config
pointed at the doorbell itself.

### On `talk = 1` from GetAbility

It does not settle the question. `GetAbility` on an NVR reports what the device
on that channel can do, and the NVR gets that from the camera. It proves the
doorbell has a speaker and a talk feature. It says nothing about whether the NVR
firmware forwards message ids 201 and 202 to the camera and pipes the ADPCM
through. The same caution applies to `two_way_audio` derived from message id 10:
that only proves the NVR forwards a small XML query, not a sustained binary
stream.

The strongest positive signal is `ipcAudioTalk` in the `Support` message. Read
message id 199 against the NVR and see whether it reports `ipcAudioTalk` for
channel 0.

### The direct route is closed here

`CONTEXT.md` records that an ARP sweep of `192.168.8.0/24` finds one Reolink MAC.
The cameras sit behind the NVR's PoE ports. There is no route to the doorbell.
If talk requires a direct camera connection, then talk is not possible in this
installation without re-cabling the doorbell to the LAN switch, which also
breaks the NVR recording path.

### How to settle it cheaply

No code needed beyond a login. In order:

1. Log in to `192.168.8.215:9000`. Send message id 199 with `<channelId>0</channelId>`.
   Look for `audioTalk` and `ipcAudioTalk`.
2. Send message id 10 with `<channelId>0</channelId>`. If a `TalkAbility` comes
   back, the NVR forwards channel-addressed talk queries, and the exact audio
   format is now known rather than assumed.
3. Send message id 201 with the `TalkConfig` built from step 2.
   - 200: the NVR accepts the session. Very likely proxied. Continue.
   - 422: something holds the slot. Send 11, retry. A repeated 422 with nothing
     else talking is itself informative.
   - 400 or 405: the NVR does not implement it for that channel.
4. Only if step 3 returns 200, stream a short ADPCM clip and listen.

Steps 1 to 3 are perhaps 300 lines of throwaway Python on top of `reolink_aio`,
which already does login, encryption and framing. Do that before writing any
Swift.

## Quick-reply clips and uploading

Separate question, separate mechanism. The doorbell channel reports
`supportAudioFileList = 1`, `customAudio = 1`, `supportAutoReply = 1`,
`supportQuickReplyPlay = 1`, and `GetAudioFileList` returns 16 empty slots
(id 0 to 15).

### What can be read and played

`reolink_aio` implements three commands against this subsystem, all over
Baichuan, all HTTP-named:

| Command | Baichuan id | Source |
|---|---|---|
| `GetAudioFileList` | 347 | `reolink_aio/baichuan/baichuan.py`, `GetAudioFileList` |
| `QuickReplyPlay` | 349 | same file, `QuickReplyPlay` |
| `GetAutoReply` / `SetAutoReply` | 427 / 428 | same file |

`QuickReplyPlay` sends:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<body>
<audioFileInfo version="1.1">
<channelId>{channel}</channelId>
<id>{file_id}</id>
<timeout>0</timeout>
</audioFileInfo>
</body>
```

From `reolink_aio/baichuan/xmls.py`, `QuickReplyPlay_XML`.
The HTTP equivalents exist too: `reolink_aio/api.py` sends
`{"cmd": "GetAudioFileList", "action": 0, "param": {"channel": channel}}` and
`{"cmd": "QuickReplyPlay", "action": 0, "param": {"id": file_id, "channel": channel}}`.

### There is no upload path in any source read

| Where I looked | Result |
|---|---|
| `reolink_aio/baichuan/baichuan.py` | List, play, auto-reply. No write of a clip. |
| `reolink_aio/api.py` | Same. The only file upload is firmware. |
| `QuantumEntangledAndy/neolink`, all of `crates/core/src` and `dissector/messages.md` | No audio-file message at all. `dissector/messages.md` documents nothing between ids 295 and 438. |
| `borexola/neolink.net` | No audio-file commands. |
| `mnpg/Reolink_api_documentations`, `official/Camera HTTP API User Guide_v8.pdf` | Text extracted and searched. `GetAudioFileList`, `QuickReplyPlay`, `UploadAudioFile` and `AudioFileUpload` do not appear. The only audio commands are the `AudioAlarm` family, which is the siren. `customAudio` appears only as an ability flag with `permit` and `ver`. |
| `reolink/reolink-cli` | `audio replies` lists clips. There is no upload subcommand. |

The vendor CLI states the limitation directly, in
`skills/reolink-cli/references/voice-alert.md`, explaining why it uses talkback
instead of the quick-reply subsystem:

> The voice line is pre-uploaded via the Reolink mobile app — no dynamic content.

Reolink's support article *How to Customize Voice Message for Doorbell Cameras
via Reolink App* describes recording in the app only, capped at 10 seconds. It
names no file import and no format.

### Format of a stored clip

Unknown. No source states the codec, container, rate or size limit of a stored
quick-reply clip. The only fact is the 10-second cap, from Reolink's support
article, and the 16-slot id range from this device's own `GetAudioFileList`
range.

### Is it the same format as live talk?

Almost certainly not, and there is no evidence either way. Live talk is a
streaming format negotiated per session by `TalkAbility`. A stored clip is a
file in flash that the device decodes itself. The ability flags are separate
(`talk` versus `customAudio` and `supportAudioFileList`), and the commands are
separate. Do not assume the ADPCM parameters carry across.

### Recommendation

The upload route is a dead end on current public knowledge. The vendor's own
tool reached the same conclusion and chose message ids 201 and 202 instead. A
text-to-speech reply from the Mac should go down the talk path:

```
AVSpeechSynthesizer -> PCM16 mono 16 kHz -> IMA ADPCM -> msg 201 + 202
```

That is exactly what `reolink/reolink-cli`'s `voice-alert.md` recipe does with
macOS `say`, and it has the advantage that the content is dynamic and no device
storage is touched.

Finding the real upload path would need a packet capture of the Reolink mobile
app recording a voice message. That is a separate piece of work and is not
covered by any source read here.

## What a Swift implementation needs

Component by component. Sizes are rough.

| Component | Notes |
|---|---|
| TCP transport | `NWConnection` to port 9000. One connection, long-lived. Needs a re-assembling reader: a Baichuan message can span TCP segments and several can arrive in one. `reolink_aio/baichuan/base_protocol.py` `parse_bc_data` is the model — it buffers, checks the magic, waits for 20 then 24 bytes, then waits for `body length`. |
| Header codec | ~100 lines. Little-endian, class-dependent length. |
| Ciphers | `BCEncrypt` is a 10-line XOR. AES-128-CFB is **not** in CryptoKit. Use CommonCrypto `CCCryptorCreateWithMode` with `kCCModeCFB` — note `kCCModeCFB` is the 128-bit-segment variant, `kCCModeCFB8` is not. `jestatsio/reolens`, `Sources/ReolinkBaichuan/Wire/Encryption.swift` has a working version. |
| MD5 | `Insecure.MD5` from CryptoKit. Remember the 31-character truncation. |
| XML | The messages are small and fixed. String templates out, `XMLDocument` in. No dependency needed. |
| Message multiplexer | Key pending replies on the 4 bytes at offset 12. Route unsolicited ids (33 events, 234 keepalive) to handlers. |
| Login state machine | Four steps, two ciphers, one cipher switch. |
| Keepalive | Timer at 30 s from last receive, plus the id-234 responder. |
| Mic capture | `AVAudioEngine` tap with an `AVAudioFormat` of `.pcmFormatInt16`, 16000 Hz, 1 channel, interleaved. `jestatsio/reolens` does exactly this. |
| ADPCM encoder | IMA/DVI-4, ~80 lines. State must be reset per block, because each block re-seeds the decoder from its own 4-byte header. See `src/Neolink.Server/Media/Adpcm.cs`, `AdpcmEncoder.EncodeBlock`, which re-derives the predictor with the decoder's own arithmetic so both sides stay in lockstep. |
| BcMedia framer | ~30 lines. See the table above for the two disputed fields. |
| Pacer | Sleep for the playback duration of each message, with a running expected-end so it does not drift. |
| Session state machine | 200 / 422 / 400 handling, retry once through message id 11, and a guaranteed message id 11 on every exit path. |
| Entitlements | Microphone: `NSMicrophoneUsageDescription`, and `com.apple.security.device.audio-input` if sandboxed. Local network: already handled per `CONTEXT.md`, but port 9000 outbound is a new destination and the existing grant should cover it. |

### The genuinely hard parts

- **Nibble order.** `src/Neolink.Server/Media/Adpcm.cs` packs high nibble first
  and documents it. `joeblack2k/reolink_talk` (`talk.py`,
  `ima_adpcm_encode_dvi_blocks`) packs low nibble first. `jestatsio/reolens`
  packs low nibble first. They cannot all be right. Standard IMA WAV is
  low-nibble-first. Get this wrong and the device plays noise at the right
  length, which is a confusing failure.
- **Padding rule.** See the disputed-fields table. Two rules, both from working
  code, differing by 4 bytes per frame.
- **`FullAes` (0x12).** If the device negotiates 0x12 the media stream is also
  encrypted, and `crates/core/src/bc/de.rs` shows the Extension then carries
  `encryptLen`, `checkPos` and `checkValue`. Neither neolink nor
  `reolink_aio` ever *sends* an encrypted binary payload. If this NVR insists on
  0x12 for talk, the outbound encryption of message id 202 is undocumented.
  Mitigation: request 0x02 rather than 0x12 in the login, or fall back to it.
- **Whether the NVR proxies talk at all.** The whole feature rests on this.
- **Firmware pickiness about the `TalkConfig` XML.** Three shapes are tried by
  `joeblack2k/reolink_talk`. There is no rule, only trial.
- **Sharing the connection.** The vendor CLI gives talk a dedicated login
  because talk collided with the alarm subscription on one model
  (`references/voice-alert.md`). Plan for a second connection rather than
  reusing the app's event connection.

## Existing Swift code

`jestatsio/reolens` — MIT, macOS, last touched 2026-09-02, 4 stars. It has a
full `Sources/ReolinkBaichuan` module:

| File | Verdict |
|---|---|
| `Wire/Encryption.swift` | Good. Correct AES key derivation, correct CFB via CommonCrypto, correct 31-char MD5. Reusable. |
| `Wire/BcConstants.swift` | Good. Message ids and classes match neolink. Adds `classModernFileDownload = 0x6482`, which no other source mentions. |
| `Wire/BcHeader.swift`, `Transport/` | Not read in depth. Structure looks right. |
| `BaichuanLogin.swift` | Not read in depth. |
| `BaichuanTalkback.swift` | **Do not copy.** Its own comment says "The exact layout is reverse-engineered". It sends a guessed 4-byte preamble `[0x00, 0x01, len_lo, len_hi]` instead of the BcMedia frame, omits the `<binaryData>1</binaryData>` Extension, omits the per-block DVI state header, hard-codes the audio config instead of reading message id 10, and does no pacing. It cannot be working against a real device in the sense neolink is. |

So: a Swift Baichuan transport exists and is worth reading. A Swift Baichuan
*talk* implementation does not.

Nothing else turned up. A GitHub repository search for `baichuan language:swift`
returns zero results; `reolink language:swift` returns `jestatsio/reolens` and
`chrisgwynne/Reolink-on-Mac`.

## What is still unknown

1. **Whether the RLN8-410 on firmware v3.6.5.562 proxies message ids 201 and
   202 to a PoE channel.** This is the question that decides the feature. No
   source answers it. The probe in [Through an NVR](#through-an-nvr) answers it
   in an afternoon.
2. **What the Doorbell PoE actually reports in `TalkAbility`.** Assumed to be
   adpcm / 16000 / 16 / 1024 / mono. Not read off this device.
3. **The correct ADPCM nibble order.** Three implementations, two answers.
4. **The correct padding rule for the BcMedia ADPCM frame.** Two rules, both
   from shipping code.
5. **What the `half block size` field at offset 10 means.** neolink's parser
   says cameras disagree and it is probably ignored.
6. **Whether the outbound binary payload must ever be encrypted.** Unknown under
   `FullAes`.
7. **How a quick-reply clip is uploaded, and in what format.** No public source.
   Would need a capture of the mobile app.
8. **Whether `mixAudioStream` or `followVideoStream` should be requested here.**
   `reolink_aio` treats `mixAudioStream` as the marker of two-way support;
   `dissector/messages.md` only ever shows `followVideoStream`. Read the list
   and prefer `mixAudioStream` when offered, as `joeblack2k/reolink_talk` does.
9. **Whether talk needs an active video stream.** The mode name
   `followVideoStream` suggests the audio may ride the preview session. No
   source starts a stream before talking, and neolink's `talk` subcommand does
   not, so probably not — but the name is a warning.
10. **The meaning of message class `0x6482`.** Named `classModernFileDownload`
    by `jestatsio/reolens` and mentioned by no other source.
