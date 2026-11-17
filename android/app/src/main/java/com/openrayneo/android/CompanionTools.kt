// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import org.json.JSONArray
import org.json.JSONObject

internal object CompanionTools {
    private fun field(type: String, description: String) = JSONObject().put("type", type).put("description", description)
    private fun definition(name: String, description: String, required: List<String> = emptyList(), vararg properties: Pair<String, JSONObject>): JSONObject =
        JSONObject().put("type", "function").put("function", JSONObject().put("name", name).put("description", description)
            .put("parameters", JSONObject().put("type", "object").put("properties", JSONObject().apply { properties.forEach { put(it.first, it.second) }; if (mutates(name)) put("request_id", field("string", "同一写入重试使用同一ID；外部Agent必填，手机Agent自动提供")) })
                .put("required", JSONArray(required)).put("additionalProperties", false)))
    fun definitions(): JSONArray = JSONArray().apply {
        put(definition("navigation_status", "读取高德通知跟随状态；不推断路线"))
        put(definition("stop_navigation_mirroring", "停止眼镜跟随；高德导航仍继续"))
        put(definition("show_notification", "向眼镜发送短通知；排队成功不保证可见", listOf("title", "body"),
            "title" to field("string", "标题"), "body" to field("string", "正文")))
        put(definition("display_clear", "清空实时提示的回答，保留正在进行的收音"))
        put(definition("device_read", "主动读取眼镜状态与设置"))
        put(definition("device_brightness", "修改亮度并回读；不要把发送成功说成设备已修改", listOf("value"), "value" to field("integer", "亮度1至17")))
        put(definition("device_display", "修改画面高度和距离并回读", listOf("height", "distance"),
            "height" to field("integer", "高度1至6"), "distance" to field("integer", "距离1至3")))
        put(definition("todo_read", "读取眼镜待完成列表与手机保留的已完成项"))
        put(definition("todo_add", "添加待办；用户须明确提出此需求", listOf("title"), "title" to field("string", "标题"), "important" to field("boolean", "重要标记")))
        put(definition("todo_update", "按查询得到的ID修改待办；完成结果以回读为准", listOf("event_id"),
            "event_id" to field("integer", "实际待办ID"), "title" to field("string", "新标题"), "important" to field("boolean", "重要"), "completed" to field("boolean", "完成或撤销完成")))
        put(definition("todo_delete", "删除用户明确指定的待办；先读取核对ID", listOf("event_id"), "event_id" to field("integer", "实际待办ID")))
        put(definition("schedule_read", "读取眼镜日程"))
        val scheduleFields = arrayOf("event_id" to field("integer", "更新或删除时使用实际ID"), "title" to field("string", "标题"),
            "start_time" to field("integer", "明确开始时间的Unix秒，按当前时区理解"), "end_time" to field("integer", "明确结束时间的Unix秒"))
        put(definition("schedule_add", "添加日程。缺日期、开始或结束时间先澄清，不擅自猜时间", listOf("title", "start_time", "end_time"), *scheduleFields.filter { it.first != "event_id" }.toTypedArray()))
        put(definition("schedule_update", "修改已查询的日程", listOf("event_id"), *scheduleFields))
        put(definition("schedule_delete", "删除用户明确指定的日程", listOf("event_id"), "event_id" to field("integer", "实际日程ID")))
        put(definition("location_current", "读取手机当前位置、精度和获取时间。位置未指定时先查此工具，失败后再询问城市"))
        put(definition("weather_current", "直接获取手机当前位置的当前天气、未来小时及3天预报。用户问今天天气、会下雨吗且未指定城市时优先调用，无需参数，不修改眼镜天气设置"))
        put(definition("weather_search_cities", "用户明确指定城市时查询坐标和真实城市ID；未指定城市优先weather_current", listOf("query"), "query" to field("string", "城市名")))
        put(definition("weather_get", "获取选定城市天气，同时设置眼镜天气城市；city使用搜索结果原对象", listOf("city"), "city" to field("object", "搜索结果的id/name/latitude/longitude")))
        put(definition("weather_push", "把已获取的天气同时发送到首页温度和天气卡"))
        put(definition("dashboard_read", "读取眼镜首页模式和组件顺序"))
        put(definition("dashboard_update", "设置首页模式和顺序。保留未要求移除的组件；天气先配置城市", listOf("mode", "widgets"),
            "mode" to field("integer", "0标准、1简洁、2斜分"), "widgets" to field("array", "1天气2待办3日程4股票5邮件6世界时钟，1至5项").put("items", JSONObject().put("type", "integer"))))
        put(definition("record_query", "读取手机完整记录及关联分析/标签/笔记，可按时间范围或原文检索", emptyList(),
            "recordId" to field("string", "指定记录ID"), "from" to field("integer", "开始Unix毫秒"), "to" to field("integer", "结束Unix毫秒"), "text" to field("string", "检索文字")))
        put(definition("record_annotate", "将分析、标签、笔记关联原记录并持久保存，后续同步到电脑", listOf("recordId", "sourceRevision", "kind"),
            "recordId" to field("string", "已查询的记录ID"), "sourceRevision" to field("integer", "查询返回的record.revision"),
            "kind" to field("string", "analysis/note/tags"), "text" to field("string", "正文"),
            "tags" to field("array", "标签").put("items", field("string", "标签")), "id" to field("string", "稳定派生ID用于重试"),
            "revision" to field("integer", "派生项版本"), "agent" to field("string", "写入Agent名称")))
        put(definition("memory_search", "检索允许留存的原话与有来源记忆；不推断人物关系", listOf("query"), "query" to field("string", "关键词")))
        put(definition("teleprompter_start", "将用户要求显示的稿件传输到眼镜并开始自动滚动", listOf("title", "text"),
            "title" to field("string", "稿件名"), "text" to field("string", "全文"), "speed" to field("integer", "滚动速度1至10，默认2")))
        put(definition("teleprompter_control", "控制本应用启动的提词", listOf("action"), "action" to field("string", "pause、resume、stop")))
    }
    fun mutates(name: String) = name in setOf("todo_add", "todo_update", "todo_delete", "schedule_add", "schedule_update", "schedule_delete")
}
