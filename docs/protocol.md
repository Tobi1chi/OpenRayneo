# Protocol notes

These notes describe the subset implemented by OpenRayneo, based on inspection of RayNeo AI 1.0.5 and device traffic, followed by direct Mac-to-glasses tests. They are not an official specification. Official packages and raw captures are not included in this repository.

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

For **first pairing**, classic inquiry in macOS Bluetooth Settings is not reliable: the glasses can be absent from Nearby Devices. The historically verified workflow used a separate `RayNeo Pair` helper calling `IOBluetoothDevicePair` with the known classic address. It verified completion code `0`, independently checked `isPaired()`, exited the helper, and only then started the command-line Bridge. No preliminary SDP query or BLE identity preparation was part of that successful helper.

### Command-line pairing

The app executable now provides a direct-address pairing command and an independent status command, so this operation is kept in source rather than a disposable `/tmp` helper. A known classic address is required. An existing macOS record or a previously captured BLE advertisement can supply it; CoreBluetooth manufacturer data uses company ID `16 57` (little-endian `0x5716`), model `06`, followed by six address bytes. This layout matches the official APK parser `S3.C0912a`.

1. Stop every Bridge and pairing-helper process and turn off the phone's Bluetooth. For a new device, enter glasses pairing mode; for recovery of the known glasses, preserve their current state.
2. Set the actual classic address, then verify a clean starting state:

   ```sh
   export RAYNEO_ADDRESS='AA-BB-CC-DD-EE-FF'
   ./OpenRayneoBridge.app/Contents/MacOS/openrayneo-bridge --unpair "$RAYNEO_ADDRESS"
   ./OpenRayneoBridge.app/Contents/MacOS/openrayneo-bridge --pairing-status "$RAYNEO_ADDRESS"
   ```

   Require both `isPaired: false` and `isConnected: false`. `--unpair` removes only this device's Mac record through the runtime-checked native `remove` selector, which is not a public SDK API. Unsupported removal or incomplete cleanup stops the workflow; use macOS settings to forget the target if necessary. The pairing command refuses an already paired or connected target. The gate reflects the Mac's exposed state, not the glasses' or every internal macOS cache's state.
3. Pair directly and let the command exit:

   ```sh
   ./OpenRayneoBridge.app/Contents/MacOS/openrayneo-bridge --pair "$RAYNEO_ADDRESS"
   ```

   Require `Pairing result: 0; isPaired: true` and exit code `0`. The tested iO uses the system's Just Works pairing. If numeric comparison is requested, use an interactive terminal and confirm only matching numbers. PIN entry is not implemented by this CLI.
4. Verify from a new process:

   ```sh
   ./OpenRayneoBridge.app/Contents/MacOS/openrayneo-bridge --pairing-status "$RAYNEO_ADDRESS"
   ```

   Require `isPaired: true`. Keep the glasses' state unchanged after this point; re-entering pairing mode creates a different test starting state.
5. Only after the helper exits, start the standalone API:

   ```sh
   export OPENRAYNEO_API_TOKEN="$(openssl rand -hex 24)"
   export OPENRAYNEO_PORT=8766
   ./OpenRayneoBridge.app/Contents/MacOS/openrayneo-bridge --headless
   ```

   Keep it running. From a second terminal, use the same token and port:

   ```sh
   curl -X POST http://127.0.0.1:8766/v1/device/connect \
     -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"
   curl http://127.0.0.1:8766/health
   ```

   Connection is complete only when the authenticated connect request succeeds and both `bleReady` and `rfcommConnected` are true. `ok: true` alone only means the HTTP service is alive.

If the first BLE scan misses the glasses, preserve the bond and retry `/v1/device/connect`. Restarting the standalone Bridge triggers a fresh scan even when an earlier BLE session was ready. Freeze the pairing state and protocol settings while comparing results; do not simultaneously change the handshake, scan rules, and process model.

On the development Mac, the bundled `--pair` command reproduced classic pairing and BLE authentication but did not complete its fresh-pair RFCOMM trial. The separate original Swift helper subsequently restored the complete connection and a visibly confirmed notification on 2026-09-29, as described below. Do not assume the bundled CLI or GUI behaves the same without testing their complete workflow.

The historical prompt/todo repair provides a second pairing reference: stop the Bridge, forget the stale macOS bond, then run a standalone Swift script using `IOBluetoothDevicePair(device: device)`, its delegate, and `pair.start()`. The script pumped the Foundation run loop until completion (up to 25 seconds), printed `device.isPaired()`, called `pair.stop()` even after success, and exited. A subsequent Bridge request completed BLE authentication and RFCOMM 26 with MTU 1011. The earlier bundled helper used `setDevice` and omitted `stop()` on success. The revised helper now follows the original construction, timeout, and cleanup; so far these differences do not explain the earlier failure. The GUI now launches it separately and verifies pairing in another process before starting the Bridge. The GUI recovery test is described below; first-attempt pairing remains unreliable.

A replay of that original script on 2026-09-29 independently confirmed `isPaired: false` before pairing, completion `0`, and `isPaired: true` from a new process after the script exited. macOS also logged successful classic encryption. The standalone Bridge then missed the glasses in three BLE scans, including after the wearer woke the glasses. With the Bridge stopped, an independent 30-second scan received 257 advertisements from 12 devices but no RayNeo name, B81D service, matching manufacturer prefix, or known peripheral identifier; no B81D peripheral was already connected. This replay did not reach application authentication or RFCOMM. This is a discovery failure, not an RFCOMM or invalid-link-key result.

In a subsequent controlled check, the wearer exited and re-entered glasses pairing mode while preserving the Mac bond. A scan immediately found the RayNeo name and B81D; the next Bridge attempt authenticated BLE but failed to open RFCOMM. macOS logged RFCOMM failure `719` (`0x2cf`), while the Bridge reported its 12-second timeout. No `INVALID_LINK_KEY` entry was found for this attempt. This confirms that re-entering pairing mode restored discoverability in this instance; it does not mean it is required after every failure, and the existing classic bond still needs verification. The wearer observed a connecting animation during some failed attempts; successful BLE authentication and that animation do not prove a full connection.

### Verified recovery on 2026-09-29

The successful recovery followed the failed BLE-authenticated attempt above:

1. Stop the Bridge. Forget the target bond on the Mac without manually re-entering glasses pairing mode again. The wearer observed the glasses leave the connecting state automatically.
2. Independently confirm `isPaired: false`, then run the original direct-address Swift pairing helper below. Require completion `0` and `paired: true`; allow the helper to call `stop()` and exit.
3. Query from a new process and require `isPaired: true`. Do not issue another Forget command. One intervening trial was invalidated by a second manual Forget action about five seconds after pairing success; this was confirmed by the wearer and was not an automatic bond loss.
4. Start the standalone Bridge with `--headless`, the existing API token, and port 8766; call `POST /v1/device/connect` once.
5. The successful response was HTTP 200, BLE `phase: authenticated`, `ready: true`, `pairingState: 2`, and `rfcommConnected: true`. macOS opened RFCOMM 26 in about 75 ms with MTU 1011. `/health` confirmed both connection flags; a notification returned 202 and the wearer confirmed success.

To preserve the original helper's relevant implementation without a disposable source file, set `RAYNEO_ADDRESS` to the actual address and run:

```sh
swift - <<'SWIFT'
import Foundation
import IOBluetooth
final class PairDelegate: NSObject, IOBluetoothDevicePairDelegate {
    var done = false
    func devicePairingStarted(_ sender: Any!) { print("pairing started") }
    func devicePairingConnecting(_ sender: Any!) { print("connecting") }
    func devicePairingConnected(_ sender: Any!) { print("connected") }
    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        print("confirmation required: \(numericValue)")
    }
    func devicePairingPINCodeRequest(_ sender: Any!) { print("PIN required") }
    func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {
        print("passkey: \(passkey)")
    }
    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        print("finished: \(error)")
        done = true
    }
}
let delegate = PairDelegate()
let device = IOBluetoothDevice(addressString: ProcessInfo.processInfo.environment["RAYNEO_ADDRESS"]!)!
let pair = IOBluetoothDevicePair(device: device)!
pair.delegate = delegate
print("start result: \(pair.start())")
let deadline = Date().addingTimeInterval(25)
while !delegate.done && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
print("paired: \(device.isPaired())")
pair.stop()
SWIFT
```

This reference helper handles the observed Just Works flow. It only reports PIN/numeric-comparison requests and does not answer them; process exit code alone is not its success criterion. The test did not change `pairValue=1`, perform an explicit SDP preflight, or add HFP waiting. The exact firmware reason for lost discoverability and the earlier RFCOMM rejection is unknown; neither helper construction nor `stop()` is isolated as the causal fix.

The revised GUI reproduced the recovery with unchanged code and handshake: its first manual pairing completed classic pairing and BLE application authentication, but macOS then reported `BT_ERROR_INVALID_LINK_KEY` and RFCOMM timed out. After stopping its Bridge and replacing only the Mac bond without manually re-entering glasses pairing mode, the same GUI connected successfully. RFCOMM opened in approximately 46 ms with MTU 1011, and the wearer confirmed success. Classic pairing completion and BLE application authentication therefore do not confirm that the subsequent classic connection can authenticate with the saved bond. Whether the mismatch originates in glasses key handling, macOS state, or their interaction is unknown. Both the failed and successful attempts initially logged `pendingClassicSMP:1` and LE encryption status `4803`.

The connection flow above starts after the Mac has a classic Bluetooth pairing with the selected glasses. The bridge checks the classic address advertised by the BLE pairing characteristic before authenticating a candidate device.

| BLE role | UUID |
| --- | --- |
| Service | `0000B81D-0000-1000-8000-00805F9B34FB` |
| Send characteristic | `EA8B70D5-2BD3-49AB-9C31-9C38B2C3C4F9` |
| Receive characteristic | `7DB3E235-3608-41F3-A03C-955FCBD2EA4B` |
| Pairing information | `EA8B60C5-2BD3-49AB-9C31-9D38B1C5C5F9` |

Discovery can also retrieve matching BLE services already connected to macOS. BLE operations and delegate callbacks run on the main queue; the HTTP worker waits for completion without blocking that queue.

The implemented application authentication uses a random challenge, device identifiers, and a protocol constant with SHA-256. It does not implement account-bound ECDH authentication. A response requesting ECDH is rejected explicitly.

### Pairing intent observation

The successful bridge baseline sends device-info TLV `27` (`pairValue`) as `1`. The official APK distinguishes pairing (`1`) and ordinary Venus/iO reconnection (`2`), but changing this field has not been shown to fix the current connection failure. The verified bridge behavior is preserved; this distinction is a research item, not a confirmed root cause or required migration.

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

Treating this status body as TLVs drops the message. The bridge exposes the first status byte in `/v1/device` as `ble.pairingState`. This is separate from `ble.ready`, which reflects successful application authentication; `ble.pairingState` contains the last received status, or null when none has arrived since the connection attempt began. Polling `/v1/device` reads this cached value.

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

The bridge waits for requests and a successful file-transfer result matching the current task ID. Pause/resume/stop responses confirm that the command was written; confirm playback state on the glasses. Pause/resume/stop apply only to the active script recorded in the current process.

## Validation boundaries

Device tests confirmed:

- BLE application authentication and direct RFCOMM 26 connection.
- Chinese notification title and body rendering.
- A short Chinese script (150 UTF-8 bytes).
- A 120-line Chinese script (16,319 UTF-8 bytes), transferred through successive RFCOMM MTU-sized writes.
- Visible pause, resume, and stop behavior.

The long script was requested as one application-level file chunk, which validates transport segmentation rather than a sequence of multiple file-chunk requests. Larger transfers, other firmware versions, and account-bound ECDH authentication are unverified or unsupported as described in the README.

Local verification also covered replay of five intact captured pairing frames, file-transfer replay with omitted zero fields, CRC/malformed-TLV rejection, API authentication, malformed content length, oversized payload rejection, health reads during connection waits, BLE timeout cleanup, and retry. These were development checks; the current repository does not ship a persistent automated protocol test suite. GitHub Actions checks the build only.
