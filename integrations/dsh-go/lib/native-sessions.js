// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
import {z} from 'zod'

// Plugin-owned metadata only: no tokens, transcripts, or model credentials.
export const nativeSessionDomain = {
  name: 'openrayneo_native_sessions', version: 1,
  tables: {bindings: {valueSchema: z.object({sessionId: z.string(), phoneId: z.string(), conversationKey: z.string(), preset: z.string()})}},
}

export function nativeScope(ctx, config, request) {
  const input = request.input
  if (request.kind !== 'task' || input?.source !== 'NATIVE' || input.backfill || !input.phoneId || !input.conversationKey) return
  const preset = config.agentPreset || ctx.get('agentPresets')?.defaultId || ''
  return {key: JSON.stringify([input.phoneId, input.conversationKey, preset]), phoneId: input.phoneId, conversationKey: input.conversationKey, preset}
}

export async function nativeSession(ctx, opening, scope, signal) {
  const bindings = (await opening).table('bindings')
  signal.throwIfAborted()
  const current = bindings.get(scope.key)
  if (current) {
    try {
      // Cold-safe read. A temporary error never causes creation or prompt replay.
      await ctx.sessionController.state({sessionId: current.sessionId}, signal)
      return current.sessionId
    } catch (error) {
      if (signal.aborted || error.code !== 'session/not-found') throw error
    }
  }
  const created = await ctx.sessionController.create(scope.preset ? {agentPreset: scope.preset} : {})
  await bindings.put(scope.key, {sessionId: created.sessionId, phoneId: scope.phoneId, conversationKey: scope.conversationKey, preset: scope.preset})
  signal.throwIfAborted()
  return created.sessionId
}
