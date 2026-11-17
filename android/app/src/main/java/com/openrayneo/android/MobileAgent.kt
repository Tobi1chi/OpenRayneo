// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.os.Handler
import android.os.Looper
import org.json.JSONObject

/** The companion exposes tools and facts; the phone's external Agent owns all response semantics. */
internal class MobileAgent(private val settings: AppSettings, private val repository: ConversationRepository,
    private val restored: (String, String, JSONObject) -> Unit, private val changed: () -> Unit,
    private val tool: (String, JSONObject, () -> Boolean, (Result<JSONObject>) -> Unit) -> Unit,
    private val finalAnswer: (String, String) -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private var generation = 0
    private var requestId: String? = null
    var running = false; private set
    var status = "启用本机Agent入口并连接DSH Go后即可使用"; private set
    var answer = ""; private set
    var question = ""; private set
    var ephemeral = false; private set
    val harness = DshRelay(main, repository, restored) { message -> if (running) { status = message; changed() } }
    fun submit(text: String, context: String = "", allowTools: Boolean = true, retainHistory: Boolean = true, forceDsh: Boolean = true) {
        check(!running) { "请等待回答，或先停止" }
        val session = ++generation
        question = text; answer = ""; running = true; ephemeral = !retainHistory
        status = "等待本机外部Agent接收…"; changed()
        requestId = harness.submit(text, context) { result ->
            if (session == generation) {
                requestId = null; running = false
                result.fold({ reply -> answer = reply; status = "本机Agent本轮已结束"; changed(); finalAnswer(text, reply) },
                    { error -> status = error.message ?: "本机Agent任务未完成"; changed() })
            }
        }
    }
    fun cancel() { generation++; requestId?.let(harness::cancelRequest); requestId = null; running = false; status = "已停止；已执行的操作会保留"; changed() }
    fun clear() { cancel(); question = ""; answer = ""; changed() }
    fun close() { generation++; running = false }
}
