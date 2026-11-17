// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.time.ZonedDateTime

/** Facts for the external phone Agent; the companion performs no semantic routing. */
internal class VoiceModePolicy(context: Context) {
    private val prompts = context.assets.open("assistant/voice-modes.json").bufferedReader().use { JSONObject(it.readText()) }
    val agentPrompt: String = prompts.getString("agent")
    fun input(source: ConversationSource, segments: List<SpeechSegment>, people: List<VoicePerson>,
              previous: List<String>, previousReply: String): JSONObject {
        val now = System.currentTimeMillis()
        return JSONObject().put("mode", source.name.lowercase())
            .put("capture_delay_estimate_seconds", if (source == ConversationSource.ALWAYS_ON) 20 else 0)
            .put("now", ZonedDateTime.now().toString())
            .put("segments", JSONArray(segments.map { segment ->
                val person = people.firstOrNull { it.id == segment.personId }
                JSONObject().put("id", segment.id).put("beginMS", segment.beginMS).put("endMS", segment.endMS)
                    .put("text", segment.text).put("sourceChannel", segment.sourceChannel).put("identityBasis", segment.identityBasis).put("speaker", segment.speaker).put("mixed", segment.mixed).put("personId", segment.personId)
                    .put("person_name", person?.name ?: JSONObject.NULL)
                    .put("is_self", person?.self == true && segment.stable)
                    .put("identity_note", if (segment.identityBasis == "channel1_default_self") "双通道中通道1按用户策略默认本人，不是声纹确认；另一通道可能录到同一人，不要仅按文字相似删原话" else "按本段身份出处理解").put("identity_stable", segment.stable && person != null)
                    .put("timelineAt", segment.timelineAt.takeIf { it > 0 } ?: segment.receivedAt).put("timeBasis", segment.timeBasis)
                    .put("processingMode", segment.processingMode).put("asrCompletedAt", segment.receivedAt)
                    .put("age_seconds", (now - (segment.timelineAt.takeIf { it > 0 } ?: segment.receivedAt)).coerceAtLeast(0) / 1000)
                    .put("processing_delay_seconds", (segment.receivedAt - (segment.timelineAt.takeIf { it > 0 } ?: segment.receivedAt)).coerceAtLeast(0) / 1000)
            })).put("previous_request", JSONArray(previous)).put("previous_reply", previousReply)
    }
}
