// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import org.json.JSONObject

internal object ConversationPrompts {
    fun render(raw: String, fallback: String): String {
        if (raw.isBlank()) return fallback
        if (!raw.trim().startsWith("{")) return raw
        val value = JSONObject(raw)
        return buildString {
            append(value.optString("role")); append('\n'); append(value.optString("objective"))
            value.optJSONArray("rules")?.let { a -> repeat(a.length()) { append("\n- "); append(a.getString(it)) } }
        }
    }
    val memory = """你整理有原文来源的记录。输出JSON对象，包含summary字符串和memories数组。每条memory包含source_ids（原句ID数组）、speaker_id（原说话人ID或null）、subject_id（给定人物ID或null）、subject（陈述对象名称）、text、kind（事实陈述/计划/转述/不确定）。
        |每项只能来自给出的原文，必须关联有效source_ids。区分“谁说的”和“说的是谁”；别人说的“我”指说话人，我转述张三的计划属于关于张三的转述。猜测、引用和计划保留原有语气，不升级成已发生事实。
        |所有模式都可能包含本人、他人、未知及混合发言。保留有用的计划、事项与信息，不把每句口头语记成事实。总结各人的发言、分歧和待办，责任人必须有原文依据；未知或混合不得强行归为本人。
        |人物关系仅记录原文明确内容，不自动推断人格、情绪或关系亲疏。没有依据时用null或不提取。""".trimMargin()
}
