# Schedule and weather transport

Research on the official RayNeo AI 1.0.5 Android APK and existing official-app Bluetooth captures, followed by direct Mac weather experiments. OpenRayneo exposes experimental dashboard-read and weather-write endpoints. Schedule writes remain unimplemented.

## Evidence and shared transport

Sources:

- APK `P3/EnumC0848h.java`: business IDs `LAUNCHER = 15` and `SCHEDULE_TODO = 22`.
- APK `resources/transportMessage.proto`: envelope fields `version = 1`, `type = 2`, `message = 3`, and optional binary `data = 4`.
- Official HCI samples: weather requests and replies, dashboard configuration queries, and empty schedule batches. Six retained HCI logs were inspected for complete AA55 frames; no populated schedule batch was found. Frames split across HCI packets were not reassembled.
- Flutter AOT `libapp.so`: model, method, and package names supporting further investigation. Strings alone do not establish field mappings or message type numbers.

The messages travel over the existing Classic Bluetooth SPP/RFCOMM connection, using the [AA55 framing](protocol.md). They are structured data for built-in firmware pages, rather than rendered images.

```text
AA 55 | body length (BE16) | sequence (BE16) | 00 | business ID
      | Protobuf envelope | CRC16-XMODEM (BE16)
```

The body length includes the sequence, reserved byte, business ID, and Protobuf bytes. The CRC covers that body. Captured envelopes use version `1`; field `3` contains UTF-8 JSON. Phone transmissions also carry an empty field `4` in these samples.

| Function | Business | Message type | Evidence |
| --- | --- | --- | --- |
| Schedule batch | `0x16` / 22 | `5` | Empty official batch captured |
| Todo batch | `0x16` / 22 | `6` | Official capture and direct Mac tests |
| Task query / reply | `0x16` / 22 | `15` / `16` | Captured and used for todo queries |
| Calendar permission/status | `0x16` / 22 | `9` | Captured `authStatus: 1`; full enum semantics unverified |
| Weather update / reply | `0x0F` / 15 | `18` / `19` | Both weather commands and matching replies captured |
| Dashboard configuration query / reply | `0x0F` / 15 | `18` / `19` | Captured with `cmd: dashboard_config` |

## Schedule batches

The observed phone-to-glasses type `5` JSON is:

```json
{"scheduleTotal":0,"isLastBatch":true,"eventList":[]}
```

This differs from the todo type `6` envelope, which uses `total`. Do not reuse the todo outer object unchanged for schedules. The empty batch is an official synchronization message, not a safe query or display-opening command; do not send it as a probe because it may clear existing schedules.

The capture also contains type `9` with `{"authStatus":1}` near schedule synchronization. The APK contains `SyncCalendarPermissionMsg`. The capture does not give all permission values or whether this message is required before every write.

The task query captured on this shared business uses type `15`:

```json
{"queryType":0,"eventType":1,"lastSyncTime":0,"eventIDList":[],"needFullData":false}
```

Type `16` replies include `scheduleTotal`, `todoTotal`, `batchNo`, `isLastBatch`, `needFullData`, `chunkInfo`, and `dataList`. OpenRayneo already uses `needFullData: true` for its verified todo read/merge/write path. The observed `eventType: 1` query and the two counters do not show how to request schedule-only records; do not guess another enum value.

Flutter symbols include `ScheduleEventItem`, `SyncScheduleMsg`, `BatchSyncScheduleMsg`, `ScheduleStatusUpdateMsg`, `ScheduleEventDTO`, `syncSchedule`, `batchSyncSchedule`, and `scheduleStatusUpdate`. Relevant package paths include:

- `common_services/glasses_service/schedule_todo/ai_task_ble_service.dart`
- `features/calendar_page/presentation/calendar_view_model.dart`
- `features/dashboard_page/presentation/pages/schedule_settings_page.dart`

Calendar logs and symbols indicate a phone-side system-calendar import path, but the conversion to an individual on-wire event is unknown. A populated official schedule capture is needed to establish event fields, timestamp units, timezone/all-day handling, stable IDs, reminders, status changes, and incremental/delete messages. Global strings such as `startTime`, `endTime`, and `recurrenceRule` do not by themselves identify the wire keys.

## Weather commands

Weather updates use Launcher business `0x0F`, not a dedicated weather business ID. The JSON is a command wrapper:

```json
{
  "cmd": "current_weather_update",
  "payload": {
    "value": 0,
    "mode": 0,
    "data": "{\"location\":\"Example location\",\"icon\":100,\"temp\":22}",
    "ts": "1790640000"
  }
}
```

Values above are illustrative. The important encoding details are that `payload.data` is a **JSON string**, not an embedded object, and `payload.ts` is a **string containing Unix seconds** in the samples. `value` and `mode` are both numeric `0`; their wider semantics are unknown.

### Current-location weather

`cmd: current_weather_update` contains one object after decoding `payload.data`:

```json
{"location":"Example location","icon":100,"temp":22}
```

The observed location label was the generic current-location label. This compact payload is distinct from the configured city cards below; neither message carries latitude or longitude in the captured Bluetooth JSON.

### City weather cards

`cmd: weather_update` uses the same wrapper, but its decoded `payload.data` is an array:

```json
[
  {
    "location": "Example city",
    "location_id": "<configured-city-id>",
    "temp": 22,
    "icon": 100,
    "des": "Sunny",
    "temp_range": "27°/14°",
    "hourly": {
      "10am": [22, 100],
      "11am": [23, 100],
      "12pm": [24, 100],
      "1pm": [26, 100],
      "2pm": [27, 100]
    }
  }
]
```

`location_id` is a string. `temp_range` is already formatted for display. The observed `hourly` keys are display labels, with `[temperature, icon]` pairs; five entries appeared in a captured update. Neither a maximum entry count nor multilingual/24-hour label behavior is known. An initial direct Mac test confirmed all supplied fields displayed, but dictionary encoding scrambled the hourly sequence. The HTTP API therefore uses an ordered array and explicitly preserves that order when constructing the on-wire object; lexical sorting of clock labels would be incorrect across values such as `9am` and `10am`.

The captures associate icons `100` and `150` with clear-weather descriptions. Direct Mac testing confirmed that changing from `100` to `150` changes the displayed icon to a night/moon icon. The full icon table and temperature-unit negotiation are unknown; another weather provider's numeric codes may not be interchangeable.

For each command the glasses returned Launcher type `19`, for example:

```json
{"cmd":"weather_update","payload":{"value":0}}
```

The current-location reply uses `cmd: current_weather_update`. These are matching protocol replies from the official flow. Direct Mac city updates also returned `value: 0` and were visibly confirmed. The meaning of all `value` codes is unverified; do not treat `value: 0` as a universal success code.

### Dashboard configuration and data sources

The official app queries the dashboard using type `18`:

```json
{"cmd":"dashboard_config","payload":{"value":0,"mode":0,"data":"","ts":"0"}}
```

The type `19` reply contains another JSON string in `payload.data`, including `simple_mode`, `widgets`, `widgets_v2`, and `widgets_data`. The observed configuration maps weather to widget ID `1`, todo to `2`, and schedule to `3`; its `widgets_data.weather.location_ids` contains the configured city IDs. This is a configuration read path, not a safe contract for modifying dashboard layout.

The APK contains `WeatherComponent`, `LocationWeatherComponent`, `pushCurrentLocationWeatherToGlasses`, `fetchWeatherHourlyByGps`, and API paths `/profileapi/weather/getCityList` and `/profileapi/weather/getWeatherInfo`. Together with the captured updates, this supports a phone-side weather-fetch/format/push design. The complete HTTP request/authentication contract and weather provider are unknown. The glasses receive display data; a Mac implementation could fetch from its own weather source and format the observed Bluetooth payloads, subject to direct device verification.

Strings `weather_request` and `current_weather_request` also exist, but no such commands were found in the inspected complete frames. Their direction, type, trigger, and response timing are unknown, and a captured sequence of repeated updates does not imply a fixed refresh interval.

## Next implementation steps

1. Capture one disposable, populated schedule created through the official app, followed by an edit and removal, to establish event and mutation semantics.
2. Keep dashboard layout separate from weather content updates; additional firmware and weather layouts still need testing.
3. Investigate weather refresh requests and persistence after reconnect; these are not handled automatically.
4. Preserve all existing schedule records before any future schedule synchronization. Reuse the transport and operation lock, but do not assume todo event fields, ID rules, or deletion semantics apply to schedules.

## Experimental HTTP API

All endpoints require the bridge's bearer token and connect on demand.

| Method | Path | Body / result |
| --- | --- | --- |
| `GET` | `/v1/dashboard` | Returns the original `reply` and decoded `config` when available; does not modify layout |
| `POST` | `/v1/weather/current` | Object with nonempty `location`, integer `temp`, and integer `icon` |
| `POST` | `/v1/weather/cities` | `{"cities":[...]}` containing one or more city objects; each requires nonempty `location_id`. Use the ordered `hourly` array below instead of the on-wire object |

Example HTTP request body (the bridge converts `hourly` to an ordered JSON object for the glasses):

```json
{
  "cities": [{
    "location": "Weather test", "location_id": "<configured-city-id>",
    "temp": 12, "icon": 100, "des": "Test only", "temp_range": "18°/6°",
    "hourly": [
      {"time": "8am", "temp": 11, "icon": 100},
      {"time": "9am", "temp": 12, "icon": 100},
      {"time": "10am", "temp": 13, "icon": 100}
    ]
  }]
}
```

Read `config.widgets_data.weather.location_ids` before a city test and use an existing ID. Dashboard configuration contains no weather-value snapshot, so it cannot serve as a backup of the previously displayed temperatures. The captured historical weather is not a current forecast.

The bridge serializes weather data into the required JSON string, adds the current timestamp, sends Launcher type `18`, and waits up to five seconds for type `19` with the matching command and a receipt time after the request. Operations share the same lock as other display actions. These replies carry no transaction ID, so a delayed reply from a previous timed-out call with the same command may be ambiguous.

Weather writes return HTTP `202` with `sent`, `acknowledged`, optional raw `reply`, and `visible: unverified`. No universal success meaning is assigned to `payload.value`. Dashboard reads return `200` on a matching reply or `504` on timeout. Weather data is supplied by the caller; the bridge does not fetch forecasts, update on a timer, alter city selections, or automatically restore old values. Reconnecting the official app can replace test values with its weather updates.

`GET /v1/display/events` also includes replies for these three Launcher commands, without including unrelated Launcher traffic.

## Direct Mac validation

- Dashboard configuration query succeeded, returning the existing weather city ID without changing the widget layout.
- City test A visibly changed the location label, temperature (`12°`), description, temperature range, and five hourly temperatures. The first dictionary-based encoding displayed the hourly entries out of order.
- City test B used the ordered HTTP array. The user confirmed `8am`, `9am`, `10am`, `11am`, `12pm` appeared in that order, with temperatures `-7`, `-6`, `-5`, `-4`, `-3`. The city temperature was negative, and changing icon `100` to `150` visibly changed the icon.
- A separate `current_weather_update` set the home-page temperature to `31°` while the city card remained at `-7°`. The user confirmed both values, establishing that these two display areas can be updated independently. Rendering of the supplied current-location label was not separately confirmed.
- These tests supplied explicit demo data, not a live weather feed. The firmware renders the supplied fields; OpenRayneo does not calculate a forecast.
