// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
import z from '@deepseek-ai/schemastery'
import { defineTool } from '@deepseek-ai/dsh-tools'
import { setTimeout as delay } from 'node:timers/promises'
import { createApi } from './api.js'
import { startHarness } from './harness.js'
import {nativeSessionDomain} from './native-sessions.js'

export const name = 'openrayneo'
export const inject = ['tools', 'sessionController', 'agents', 'llm', 'agentDefaultModel', 'storageDomain']
export const Config = z.object({
  baseUrl: z.string().default('http://127.0.0.1:8766').description('OpenRayneo local API address / 本机入口地址'),
  tokenEnv: z.string().role('credential-ref').default('OPENRAYNEO_TOKEN').volatile().description('OpenRayneo access token / 本机访问令牌的凭据名称'),
  receiveVoiceTasks: z.boolean().default(true).description('Receive voice tasks / 接收眼镜语音任务'),
  agentPreset: z.string().default('').description('Optional DSH agent preset / 可选的DSH预设'),
})

function clip(text, length) { return Array.from(text).slice(0, length).join('') }
function toast(text) { return [{type: 'toast', text: clip(String(text).replace(/\s+/g, ' ').trim(), 40)}] }

// Bound the canonical result too, so neither model context nor native history stores an unlimited response.
function boundedResult(value) {
  const json = JSON.stringify(value)
  const total = Buffer.byteLength(json)
  if (total <= 8192) return value
  const chars = Array.from(json)
  const result = {truncated: true, total_bytes: total, preview: '', hint: '结果已截断，请缩小查询范围；不要据此确认未显示的内容'}
  let low = 0, high = Math.min(chars.length, 8192)
  while (low < high) {
    const middle = Math.ceil((low + high) / 2)
    result.preview = chars.slice(0, middle).join('')
    if (Buffer.byteLength(JSON.stringify(result)) <= 8192) low = middle
    else high = middle - 1
  }
  result.preview = chars.slice(0, low).join('')
  return result
}

export async function apply(ctx, config) {
  const lifetime = new AbortController()
  const {api, base, tokenRef} = createApi(ctx, config, lifetime.signal)
  let uiBusy = false
  let deviceTail = Promise.resolve()

  async function callTool(toolName, args = {}, callerSignal) {
    const signal = AbortSignal.any([lifetime.signal, AbortSignal.timeout(50_000), ...(callerSignal ? [callerSignal] : [])])
    signal.throwIfAborted()
    const before = deviceTail
    const slot = Promise.withResolvers()
    deviceTail = before.then(() => slot.promise)
    const aborted = Promise.withResolvers()
    const onAbort = () => aborted.reject(signal.reason)
    signal.addEventListener('abort', onAbort, {once: true})
    try {
      await Promise.race([before, aborted.promise])
      signal.throwIfAborted()
      return await runTool(toolName, args, signal)
    } finally {
      slot.resolve()
      signal.removeEventListener('abort', onAbort)
    }
  }

  async function runTool(toolName, args, signal) {
    let task
    try {
      task = await api('/v1/tools/call', {body: {name: toolName, arguments: args}, signal})
    } catch (error) {
      if (error.transient) throw new Error('提交结果未确认，请先查状态，勿重复发送同一操作')
      throw error
    }
    try {
      let failures = 0
      while (task.state === 'running') {
        await delay(300, undefined, {signal})
        try {
          task = await api(`/v1/tasks/${encodeURIComponent(task.id)}`, {signal})
          failures = 0
        } catch (error) {
          if (!error.transient || ++failures > 2) throw error
          await delay(500 * failures, undefined, {signal})
        }
      }
      if (task.state !== 'completed') throw new Error(task.error || `OpenRayneo task ${task.state}`)
      return task.result
    } catch (error) {
      if (task.id && task.state === 'running') {
        // Cancels remaining writes, never replays the original tool call.
        await api(`/v1/tasks/${encodeURIComponent(task.id)}/cancel`, {body: {}, timeoutMs: 2_000, cleanup: true}).catch(() => {})
      }
      throw error
    }
  }

  const output = {schema: {type: 'object', additionalProperties: true},
    render: (_args, value) => [{type: 'text', text: JSON.stringify(value)}]}
  ctx.tools.register(defineTool({
    name: 'rayneo_status', description: 'Read current OpenRayneo connection and activity. No audio or model keys.',
    parameters: {}, output, timeoutMs: 6_000, isConcurrencySafe: () => true,
    execute: (_args, exec) => api('/v1/status', {signal: exec.signal}),
  }))
  ctx.tools.register(defineTool({
    name: 'rayneo_tools', description: 'List actual OpenRayneo tool schemas before controlling glasses, todos, calendar or weather.',
    parameters: {}, output, timeoutMs: 6_000, isConcurrencySafe: () => true,
    execute: (_args, exec) => api('/v1/tools', {signal: exec.signal}),
  }))
  ctx.tools.register(defineTool({
    name: 'rayneo_call',
    description: 'Call a tool returned by rayneo_tools. Todo/calendar writes require a stable request_id. Never replay an uncertain write; read back first. Results are capped at 8 KiB; truncated=true means narrow the query. Only modify explicitly requested content. Queued results need device confirmation.',
    parameters: {
      name: {type: 'string', required: true, description: 'Exact tool name from rayneo_tools'},
      arguments: {type: 'object', required: true, additionalProperties: true, description: 'Arguments conforming to the selected tool schema'},
    }, output, timeoutMs: 55_000, isConcurrencySafe: () => false,
    execute: async (args, exec) => boundedResult(await callTool(args.name, args.arguments, exec.signal)),
  }))

  const opening = config.receiveVoiceTasks ? await ctx.storageDomain.open(nativeSessionDomain) : undefined
  const harness = startHarness(ctx, config, api, lifetime.signal, opening)
  ctx.effect(() => () => {
    lifetime.abort()
    return harness.done.finally(async () => { if (opening) await (await opening).close() })
  })

  // All network actions acknowledge immediately; their work uses the bridge's deferred cancellation signal.
  // A single UI operation owns the device at a time; repeated taps return a valid short notice.
  function action(label, work, timeoutMs = 55_000) {
    return scope => {
      if (uiBusy) return toast('正在处理上一个操作，请稍候')
      return {pending: {label, timeoutMs}, result: async signal => {
        if (uiBusy) return toast('正在处理上一个操作，请稍候')
        uiBusy = true
        try {
          signal.throwIfAborted()
          return await work(scope, signal)
        } catch (error) {
          if (signal.aborted || lifetime.signal.aborted) return []
          return toast(error.message || '操作未完成，请查看本机服务')
        } finally { uiBusy = false }
      }}
    }
  }

  ctx.inject(['dshGo'], scoped => {
    scoped.dshGo.on('connect', action('连接眼镜', async (scope, signal) => {
      const copied = scope.clipboard?.trim() ?? ''
      const address = copied.match(/^http:\/\/\S+/m)?.[0]
      const token = copied.match(/Authorization:\s*Bearer\s+(\S+)/i)?.[1]
      if (!address || !token) return toast('请先在OpenRayneo复制地址与访问令牌')
      if (new URL(address).origin !== base.origin) return toast('地址不一致，请先修改插件的Service URL')
      const credentials = ctx.get('credentials')
      if (!credentials) throw new Error('当前DSH没有可写的凭据服务')
      signal.throwIfAborted()
      await credentials.set(tokenRef(), token)
      signal.throwIfAborted()
      const state = await api('/v1/status', {signal})
      return toast(state.link === 'FULL' ? 'OpenRayneo已接通，眼镜已完整连接' : 'OpenRayneo已接通，眼镜尚未完整连接')
    }, 15_000))
    scoped.dshGo.on('status', action('读取眼镜状态', async (_scope, signal) => {
      const state = await api('/v1/status', {signal})
      const link = {FULL: '完整连接', DISCONNECTED: '未连接', BLE_ONLY: '仅BLE连接',
        SCANNING: '扫描中', CONNECTING: '连接中', RETRY_WAIT: '等待重连', CLOSING: '断开中'}[state.link] ?? '状态未知'
      return toast(`OpenRayneo在线 · 眼镜${link} · ${state.conversationRunning ? '语音运行中' : '语音空闲'}`)
    }, 10_000))
    scoped.dshGo.on('send-glasses', action('发送到眼镜', async (scope, signal) => {
      const text = typeof scope.message === 'string' ? scope.message : ''
      if (!text.trim()) return toast('没有可发送的回复正文')
      await callTool('show_notification', {title: 'DSH Go', body: clip(text, 500)}, signal)
      return toast('已提交眼镜通知，请查看眼镜')
    }))
    scoped.dshGo.on('clear-glasses', action('清空眼镜', async (_scope, signal) => {
      await callTool('display_clear', {}, signal)
      return toast('已发送清屏请求')
    }))
  })
}
