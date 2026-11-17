// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.content.Context
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.time.*
import java.util.UUID
import java.util.concurrent.TimeUnit

internal data class CompanionContentState(val dashboard: JSONObject? = null, val todos: List<JSONObject> = emptyList(),
    val schedules: List<JSONObject> = emptyList(), val busy: Boolean = false, val notice: String = "连接后读取眼镜内容",
    val weatherCities: List<JSONObject> = emptyList(), val weather: JSONObject? = null, val automaticWeather: Boolean = false)

/** Device-backed content shared by manual pages, model tools and the local Agent API. */
internal class CompanionContent(context: Context, private val requests: GlassesRequests,
    private val address: () -> String?, private val changed: () -> Unit) {
    @Volatile var state = CompanionContentState(); private set
    private val phoneLocation = PhoneLocation(context)
    private val local = context.getSharedPreferences("device-content", Context.MODE_PRIVATE)
    private val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
        .connectTimeout(20, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS).build()
    private fun device() = checkNotNull(address()) { "请先完整连接眼镜" }
    private fun cacheKey() = "todos:" + device()
    private fun cachedTodos() = JSONArray(local.getString(cacheKey(), "[]")).objects()
    private fun cache(items: List<JSONObject>) { check(local.edit().putString(cacheKey(), JSONArray(items).toString()).commit()) }
    private var weatherAttemptAt = 0L
    fun connected() {
        val id = device()
        state = state.copy(automaticWeather = local.getBoolean("weatherAutomatic:$id", false),
            weather = local.getString("weatherCard:$id", null)?.let(::JSONObject)); changed()
        automaticWeather()
    }
    fun setAutomaticWeather(enabled: Boolean) {
        check(local.edit().putBoolean("weatherAutomatic:" + device(), enabled).commit())
        state = state.copy(automaticWeather = enabled); changed(); if (enabled) automaticWeather(force = true)
    }
    fun automaticWeather(force: Boolean = false) {
        if (address() == null || !state.automaticWeather || state.busy || !force && System.currentTimeMillis() - weatherAttemptAt < 30 * 60_000) return
        val city = local.getString("weatherCity:" + device(), null)?.let(::JSONObject) ?: return
        weatherAttemptAt = System.currentTimeMillis()
        run { weather(city); pushWeather() }
    }
    fun refresh() = run { dashboard(); events(1); events(0); JSONObject().put("readBack", true) }
    fun disconnected() { weatherAttemptAt = 0; state = CompanionContentState(); changed() }
    fun run(work: () -> JSONObject) {
        check(!state.busy) { "请等待当前眼镜操作" }
        state = state.copy(busy = true, notice = "正在与眼镜同步…"); changed()
        execute(work) { result -> state = state.copy(busy = false, notice = result.fold({ it.optString("message").ifBlank { if (it.optBoolean("readBack")) "设备回读已确认" else "已发送，具体状态见结果" } }, { it.message ?: "操作失败" })); changed() }
    }
    fun execute(work: () -> JSONObject, completion: (Result<JSONObject>) -> Unit) = requests.perform(work, completion)
    fun execute(name: String, args: JSONObject, completion: (Result<JSONObject>) -> Unit) = execute({ tool(name, args) }, completion)

    fun dashboard(): JSONObject {
        val response = launcher("dashboard_config", "", "0")
        val raw = response.getJSONObject("payload").get("data")
        val config = if (raw is JSONObject) raw else JSONObject(raw.toString())
        state = state.copy(dashboard = config); return config
    }
    fun layout(mode: Int, widgets: List<Int>): JSONObject {
        require(mode in 0..2 && widgets.size in 1..5 && widgets.distinct().size == widgets.size)
        val previous = dashboard()
        launcher("dashboard_update", JSONObject().put("simple_mode", mode).put("widgets", JSONArray(widgets)).toString())
        val added = widgets.filter { id -> id !in previous.optJSONArray("widgets").ints() }
        if (1 in added && state.weather != null) pushWeather()
        if (6 in added) pushClock()
        val actual = dashboard()
        val same = actual.optInt("simple_mode") == mode && actual.optJSONArray("widgets").ints() == widgets
        return JSONObject().put("readBack", same).put("config", actual).put("message", if (same) "首页布局已回读确认" else "设备布局与请求不同，请核对组件内容是否已配置")
    }
    fun events(eventType: Int): List<JSONObject> {
        val rows = mutableListOf<JSONObject>(); var last: JSONObject? = null
        requests.request(22, 15, JSONObject().put("queryType", 0).put("eventType", eventType)
            .put("lastSyncTime", 0).put("eventIDList", JSONArray()).put("needFullData", true)) { type, body ->
            if (type != 16 || !body.has("dataList")) false else {
                rows += body.getJSONArray("dataList").objects().filter { it.optInt("eventType", -1) == eventType }
                if (body.optBoolean("isLastBatch")) { last = body; true } else false
            }
        }
        val response = checkNotNull(last)
        check(response.optBoolean("needFullData") && response.getInt(if (eventType == 1) "todoTotal" else "scheduleTotal") == rows.size &&
            rows.map { it.getLong("eventID") }.distinct().size == rows.size) { "设备列表未完整返回，未执行修改" }
        if (eventType == 1) {
            val completed = cachedTodos().filter { it.optInt("status") == 1 && rows.none { row -> row.getLong("eventID") == it.getLong("eventID") } }
            cache(rows + completed); state = state.copy(todos = rows + completed)
        } else state = state.copy(schedules = rows)
        return rows
    }
    fun todo(action: String, args: JSONObject): JSONObject {
        val key = "mutation:" + device() + ":" + args.optString("request_id").ifBlank { UUID.randomUUID().toString() }
        local.getString(key, null)?.let { saved ->
            val old = JSONObject(saved); return JSONObject().put("eventID", old.getLong("id")).put("duplicate", true)
                .put("items", JSONArray(events(1))).put("readBack", false).put("message", "同一请求已发送过，请根据回读核对；没有重复修改")
        }
        val before = events(1)
        val old = cachedTodos().firstOrNull { it.getLong("eventID") == args.optLong("event_id", -1) }
        val now = System.currentTimeMillis()
        val id = if (action == "add") {
            val reserved = cachedTodos().map { it.getLong("eventID") }.toSet()
            (80000L until 90000L).firstOrNull { it !in reserved } ?: error("手机本地待办ID已用完")
        } else checkNotNull(old) { "未找到该待办，请先读取列表" }.getLong("eventID")
        val target = if (action == "add") JSONObject().put("eventType", 1).put("eventID", id).put("createTime", now)
            .put("title", args.getString("title")).put("isImportant", args.optBoolean("important")).put("status", 0).put("eventSource", 0)
            else JSONObject(old.toString())
        if (args.has("title")) { require(args.getString("title").isNotBlank()); target.put("title", args.getString("title")) }
        if (args.has("important")) target.put("isImportant", args.getBoolean("important"))
        if (args.has("completed")) target.put("status", if (args.getBoolean("completed")) 1 else 0)
        target.put("lastModifiedTime", now / 1000)
        check(local.edit().putString(key, JSONObject().put("id", id).put("action", action).put("item", target).toString()).commit())
        target.put("syncState", "outcome_unknown")
        cache(cachedTodos().filter { it.getLong("eventID") != id } + target)
        if (action == "delete") requests.request(22, 7, JSONObject().put("eventType", 1).put("todoTotal", 1).put("eventIDList", JSONArray().put(id)), wait = false)
        else {
            requests.request(22, 2, JSONObject(target.toString()).apply { remove("syncState") }, wait = false)
            if (action == "update" && args.has("completed")) {
                val pending = (before.filter { it.getLong("eventID") != id } + target).filter { it.optInt("status") != 1 }
                if (pending.isEmpty() || old?.optInt("status") == 1 && !args.getBoolean("completed"))
                    requests.request(22, 6, JSONObject().put("total", pending.size).put("isLastBatch", true).put("eventList", JSONArray(pending.map { JSONObject(it.toString()).apply { remove("syncState") } })), wait = false)
            }
        }
        val actual = events(1); val found = actual.firstOrNull { it.getLong("eventID") == id }
        val confirmed = if (action == "delete") before.any { it.getLong("eventID") == id } && found == null
            else found?.let { it.optString("title") == target.optString("title") && it.optInt("status") == target.optInt("status") && it.optBoolean("isImportant") == target.optBoolean("isImportant") } == true
        if (action == "delete" && confirmed) cache(cachedTodos().filter { it.getLong("eventID") != id })
        return JSONObject().put("eventID", id).put("readBack", confirmed).put("pendingRemoved", old != null && found == null)
            .put("items", JSONArray(state.todos)).put("message", if (confirmed) "待办已回读确认" else "已发送待办修改；待完成列表已回读，操作结果仍需核对")
    }
    fun schedule(action: String, args: JSONObject): JSONObject {
        val mutationKey = "scheduleMutation:" + device() + ":" + args.optString("request_id").ifBlank { UUID.randomUUID().toString() }
        local.getString(mutationKey, null)?.let { prior ->
            return JSONObject().put("eventID", prior.toLong()).put("duplicate", true).put("readBack", false)
                .put("items", JSONArray(events(0))).put("message", "该请求已发送过；请核对日程列表，没有重复写入")
        }
        val items = events(0).map { JSONObject(it.toString()) }.toMutableList()
        val id = if (action == "add") generateSequence(System.currentTimeMillis()) { it + 1 }.first { id -> items.none { it.getLong("eventID") == id } }
            else args.getLong("event_id")
        val existing = items.firstOrNull { it.getLong("eventID") == id }
        val target = if (action == "add") JSONObject().put("eventType", 0).put("eventID", id).put("status", 0).put("eventSource", 0).put("createTime", System.currentTimeMillis())
            else JSONObject(checkNotNull(existing) { "日程不存在" }.toString())
        if (action == "delete") items.remove(existing) else {
            if (args.has("title")) target.put("title", args.getString("title"))
            if (args.has("start_time")) target.put("startTime", args.getLong("start_time"))
            if (args.has("end_time")) target.put("endTime", args.getLong("end_time"))
            require(target.optString("title").isNotBlank() && target.getLong("endTime") > target.getLong("startTime")) { "日程需要明确标题、开始和结束时间" }
            val instant = Instant.ofEpochSecond(target.getLong("startTime")); val zone = ZoneId.systemDefault()
            target.put("localTimeOffset", zone.rules.getOffset(instant).totalSeconds)
                .put("isTomorrowSchedule", instant.atZone(zone).toLocalDate() == LocalDate.now(zone).plusDays(1)).put("lastModifiedTime", System.currentTimeMillis())
            items.remove(existing); items += target
        }
        check(local.edit().putString(mutationKey, id.toString()).commit())
        requests.request(22, 5, JSONObject().put("scheduleTotal", items.size).put("isLastBatch", true).put("eventList", JSONArray(items)), wait = false)
        val actual = events(0); val row = actual.firstOrNull { it.getLong("eventID") == id }
        val confirmed = if (action == "delete") row == null else row != null && listOf("title", "startTime", "endTime").all { row.opt(it) == target.opt(it) }
        return JSONObject().put("eventID", id).put("readBack", confirmed).put("items", JSONArray(actual))
    }
    fun searchCities(query: String): JSONObject {
        val url = "https://geocoding-api.open-meteo.com/v1/search?name=" + java.net.URLEncoder.encode(query, "UTF-8") + "&count=8&language=zh&format=json"
        val result = get(url); state = state.copy(weatherCities = result.optJSONArray("results").objects()); return result
    }
    fun currentWeather(): JSONObject {
        val location = phoneLocation.current()
        val result = forecast(location.getDouble("latitude"), location.getDouble("longitude"))
        result.getJSONObject("current").put("description", description(result.getJSONObject("current").getInt("weather_code")))
        return result
            .put("location", location).put("source", "Open-Meteo").put("fetchedAt", System.currentTimeMillis())
    }
    private fun forecast(latitude: Double, longitude: Double): JSONObject = get(
        "https://api.open-meteo.com/v1/forecast?latitude=$latitude&longitude=$longitude&current=temperature_2m,weather_code,is_day&hourly=temperature_2m,weather_code,is_day,precipitation_probability&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto&forecast_days=3")
    fun weather(city: JSONObject): JSONObject {
        val deviceId = device()
        val latitude = city.getDouble("latitude"); val longitude = city.getDouble("longitude")
        val response = forecast(latitude, longitude)
        val current = response.getJSONObject("current"); val day = current.optInt("is_day", 1) == 1
        val hourly = response.getJSONObject("hourly"); val data = JSONObject()
        val currentTime = current.getString("time")
        val indices = (0 until hourly.getJSONArray("time").length()).filter { hourly.getJSONArray("time").getString(it) >= currentTime }.take(5)
        for (index in indices) {
            val time = LocalDateTime.parse(hourly.getJSONArray("time").getString(index)).hour.toString() + "时"
            data.put(time, JSONArray().put(kotlin.math.round(hourly.getJSONArray("temperature_2m").getDouble(index)).toInt())
                .put(icon(hourly.getJSONArray("weather_code").getInt(index), hourly.getJSONArray("is_day").getInt(index) == 1)))
        }
        val daily = response.getJSONObject("daily")
        val card = JSONObject().put("location", city.getString("name")).put("location_id", city.getLong("id").toString())
            .put("temp", kotlin.math.round(current.getDouble("temperature_2m")).toInt()).put("icon", icon(current.getInt("weather_code"), day))
            .put("des", description(current.getInt("weather_code"))).put("temp_range", "${kotlin.math.round(daily.getJSONArray("temperature_2m_max").getDouble(0)).toInt()}°/${kotlin.math.round(daily.getJSONArray("temperature_2m_min").getDouble(0)).toInt()}°")
            .put("hourly", data)
        check(address() == deviceId) { "设备连接已变化，未保存旧请求的天气" }
        card.put("fetchedAt", System.currentTimeMillis())
        state = state.copy(weather = card)
        check(local.edit().putString("weatherCity:" + device(), city.toString()).putString("weatherCard:" + device(), card.toString()).commit())
        return JSONObject().put("weather", card)
    }
    fun pushWeather(): JSONObject {
        val card = checkNotNull(state.weather) { "请先选择城市并获取天气" }
        launcher("current_weather_update", JSONObject().put("location", card.getString("location")).put("temp", card.getInt("temp")).put("icon", card.getInt("icon")).toString())
        launcher("weather_update", JSONArray().put(card).toString())
        return JSONObject().put("sent", "weather").put("readBack", false).put("message", "首页温度与天气卡均已收到回包，眼镜显示待确认")
    }
    fun pushClock(): JSONObject = launcher("clock_update", JSONArray().put(JSONObject().put("location", "本地时间")
        .put("location_id", ZoneId.systemDefault().id).put("timezone", ZoneId.systemDefault().id).put("offset", ZonedDateTime.now().offset.totalSeconds)).toString())
    fun launcher(command: String, data: String, timestamp: String = (System.currentTimeMillis() / 1000).toString()): JSONObject {
        return checkNotNull(requests.request(15, 18, JSONObject().put("cmd", command).put("payload", JSONObject()
            .put("value", 0).put("mode", 0).put("data", data).put("ts", timestamp))) { type, body -> type == 19 && body.optString("cmd") == command })
    }
    fun tool(name: String, args: JSONObject): JSONObject = when (name) {
        "todo_read" -> JSONObject().put("items", JSONArray(events(1))).put("localItems", JSONArray(state.todos))
        "todo_add", "todo_update", "todo_delete" -> todo(name.substringAfter('_'), args)
        "schedule_read" -> JSONObject().put("items", JSONArray(events(0)))
        "schedule_add", "schedule_update", "schedule_delete" -> schedule(name.substringAfter('_'), args)
        "weather_search_cities" -> searchCities(args.getString("query"))
        "weather_current" -> currentWeather()
        "location_current" -> phoneLocation.current()
        "weather_get" -> weather(args.getJSONObject("city"))
        "weather_push" -> pushWeather()
        "dashboard_read" -> dashboard()
        "dashboard_update" -> layout(args.getInt("mode"), args.getJSONArray("widgets").ints())
        else -> error("未实现的设备工具：$name")
    }
    fun observe(type: Int, body: JSONObject) {
        if (type !in setOf(4,10) || address() == null) return
        val updates = if (type == 4) listOf(body) else body.optJSONArray("eventList").objects()
        val cached = cachedTodos().toMutableList()
        for (update in updates) {
            val old = cached.firstOrNull { it.optLong("eventID") == update.optLong("eventID", -1) } ?: continue
            listOf("status", "isImportant", "lastModifiedTime").forEach { if (update.has(it)) old.put(it, update.opt(it)) }
            if (old.optString("syncState") != "outcome_unknown") old.put("syncState", "confirmed_by_glasses")
        }
        cache(cached); state = state.copy(todos = cached); changed()
    }
    fun close() { http.dispatcher.cancelAll(); http.dispatcher.executorService.shutdown(); http.connectionPool.evictAll() }
    private fun get(url: String): JSONObject = http.newCall(Request.Builder().url(url).build()).execute().use { response ->
        check(response.isSuccessful) { "天气请求失败：HTTP ${response.code}" }; JSONObject(checkNotNull(response.body).string())
    }
    private fun icon(code: Int, day: Boolean): Int = when (code) {
        0 -> if (day) 100 else 150; 1 -> if (day) 103 else 153; 2 -> if (day) 101 else 151; 3 -> 104
        45,48 -> 501; 51,53,55 -> 309; 56,57,66,67 -> 313; 61 -> 305; 63 -> 306; 65 -> 307
        71 -> 400; 73 -> 401; 75,77 -> 402; 80 -> if (day) 300 else 350; 81,82 -> if (day) 301 else 351
        85,86 -> if (day) 407 else 457; 95,97 -> 302; 96,99 -> 304; else -> 104
    }
    private fun description(code: Int) = when (code) { 0 -> "晴"; 1,2 -> "多云"; 3 -> "阴"; 45,48 -> "雾"; in 51..67, in 80..82 -> "雨"; in 71..77,85,86 -> "雪"; in 95..99 -> "雷雨"; else -> "天气" }
}
internal fun JSONArray?.objects(): List<JSONObject> = if (this == null) emptyList() else List(length()) { getJSONObject(it) }
internal fun JSONArray?.ints(): List<Int> = if (this == null) emptyList() else List(length()) { getInt(it) }
