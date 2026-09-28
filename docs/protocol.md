# Protocol notes

These notes describe the subset implemented by OpenRayneo. They are based on inspection of RayNeo AI 1.0.5 and device traffic, followed by direct Mac-to-glasses tests. They are not an official specification or a compatibility guarantee. Official packages and raw captures are not included in this repository.

## Connection flow

```text
Local HTTP client
      |
      v
OpenRayneo on macOS
      |-- BLE discovery: RayNeo iO name or B81D service
      |-- Read pairing characteristic and verify classic device address
      |-- Subscribe to BLE notifications
      |-- Exchange device information and authenticate
      |-- Authenticate classic Bluetooth and open RFCOMM channel 26
      v
RayNeo iO notification / teleprompter UI
```

The Mac must have a classic Bluetooth pairing with the selected glasses. The bridge checks the classic address advertised by the BLE pairing characteristic before authenticating a candidate device.

| BLE role | UUID |
| --- | --- |
| Service | `0000B81D-0000-1000-8000-00805F9B34FB` |
| Send characteristic | `EA8B70D5-2BD3-49AB-9C31-9C38B2C3C4F9` |
| Receive characteristic | `7DB3E235-3608-41F3-A03C-955FCBD2EA4B` |
| Pairing information | `EA8B60C5-2BD3-49AB-9C31-9D38B1C5C5F9` |

Discovery can also retrieve matching BLE services already connected to macOS. BLE operations and delegate callbacks run on the main queue; the HTTP worker waits for completion without blocking that queue.

The implemented application authentication uses a random challenge, device identifiers, and a protocol constant with SHA-256. It does not implement account-bound ECDH authentication. A response requesting ECDH is rejected explicitly.

### HFP is not an application readiness requirement

During Mac testing, `IOBluetoothHandsFreeAudioGateway` did not deliver the expected completion callback, while directly opening RFCOMM 26 succeeded. The bridge therefore does not register or wait for a separate HFP gateway object. macOS may independently manage audio profiles; successful data-channel opening is the bridge's readiness signal.

## Transport framing

The observed classic data path is RFCOMM/SPP over L2CAP PSM `0x0003`, server channel `26`.

| Field | Size | Encoding |
| --- | --- | --- |
| Magic | 2 bytes | `AA 55` |
| Body length | 2 bytes | Big-endian; includes sequence, flag, protocol ID, and payload |
| Sequence | 2 bytes | Big-endian |
| Flag | 1 byte | `0` in outgoing frames |
| Protocol ID | 1 byte | See below |
| Payload | Variable | Command-specific |
| CRC | 2 bytes | Big-endian CRC16-XMODEM over the body |

| Protocol ID | Function |
| --- | --- |
| `0x10` | BLE connection and application authentication |
| `0x11` | File-transfer tasks |
| `0x14` | Teleprompter metadata and controls |
| `0x15` | Notifications |

The 16-bit body length permits at most 65,531 payload bytes after the four-byte sequence/flag/protocol header. The encoder rejects larger payloads with HTTP `413`.

A protocol frame can exceed the RFCOMM MTU. `writeSync` calls must each fit the negotiated MTU, so the bridge sends a frame in successive slices under one write lock. The tested MTU was 1011 bytes. Incoming data is buffered until complete protocol frames are available.

## Connection-pairing messages

The `0x10` payload starts with a command byte and a two-byte big-endian length. Commands `17` (device information), `24` (authentication request), and `25` (authentication response) contain TLVs. Status commands `22` and `23` contain raw status bytes instead.

An observed pairing-state payload was:

```text
17 00 02 02 00
|  |     |
|  |     +-- status 2: paired, followed by one trailing byte
|  +-------- two payload bytes
+----------- command 0x17 (decimal 23)
```

Treating this status body as TLVs drops the message. The bridge exposes the first status byte in `/v1/device` as `ble.pairingState`. This is separate from `ble.ready`, which reflects successful application authentication; the pairing-state notification is not guaranteed to arrive on every reconnection.

## Notifications

Notification payloads use protocol `0x15`, Protobuf action `1`, message type `2`, and a JSON body. The bridge supplies an app identity, timestamp, notification ID, title, and content using the observed field names.

Writing a notification frame does not provide an acknowledgment of visible rendering. That is why the API returns `202`, and display behavior was checked by a person wearing the glasses.

## Teleprompter transfer

A script startup sends teleprompter settings, transfers its UTF-8 text, updates the script metadata, and sends the transfer-complete/start information.

The file task uses protocol `0x11`:

| Top-level Protobuf field | Meaning |
| --- | --- |
| `1` | Transfer descriptor: task ID, script DID as filename, byte count, MD5, and content type |
| `2` | Descriptor response observed in the capture |
| `3` | Device request: task ID, chunk number, byte offset, and requested byte count |
| `4` | Host response: task ID, chunk number, byte offset, byte count, and content |
| `5` | Transfer completion/result |

Protobuf omits default zero values. In particular, an absent request offset means `0`, and an absent completion result means success (`0`). Both occurred in the observed traffic and are handled by the implementation.

Text transfer sizes and offsets use UTF-8 **bytes**. The teleprompter metadata's `total` uses UTF-16 code units. The file descriptor carries MD5, and the teleprompter completion metadata carries FNV-1a 32 over the UTF-8 content. These checksums are protocol requirements, not security guarantees.

The bridge waits for requests and a successful file-transfer result matching the current task ID. Teleprompter control responses are not a guarantee of actual display state. Pause/resume/stop apply only to the active script recorded in the current process.

## Validation boundaries

Device tests confirmed:

- BLE application authentication and direct RFCOMM 26 connection.
- Chinese notification title and body rendering.
- A short Chinese script (150 UTF-8 bytes).
- A 120-line Chinese script (16,319 UTF-8 bytes), transferred through successive RFCOMM MTU-sized writes.
- Visible pause, resume, and stop behavior.

The long script was requested as one application-level file chunk. It validates transport segmentation, not a sequence of multiple file-chunk requests. Larger transfers, other firmware versions, and account-bound ECDH authentication remain unverified or unsupported as described in the README.

Local verification also covered replay of five intact captured pairing frames, file-transfer replay with omitted zero fields, CRC/malformed-TLV rejection, API authentication, malformed content length, oversized payload rejection, health reads during connection waits, BLE timeout cleanup, and retry. These were development checks; the current repository does not ship a persistent automated protocol test suite. GitHub Actions checks the build only.
