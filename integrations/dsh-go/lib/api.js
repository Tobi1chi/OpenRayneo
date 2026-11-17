// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
import { credentialRef } from '@deepseek-ai/dsh-credentials'

export class ApiError extends Error {
  constructor(message, kind, status) {
    super(message); this.name = 'ApiError'; this.kind = kind; this.status = status
  }
  get transient() { return ['network', 'timeout', 'server', 'protocol'].includes(this.kind) }
}

export function createApi(ctx, config, lifetime) {
  const base = new URL(config.baseUrl)
  if (base.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(base.hostname)) {
    throw new Error('OpenRayneo must use a loopback HTTP address')
  }
  const tokenRef = () => credentialRef(config.tokenEnv.get())

  async function api(path, {body, signal, timeoutMs = 5_000, cleanup = false} = {}) {
    const requestSignal = AbortSignal.any([AbortSignal.timeout(timeoutMs),
      ...(!cleanup ? [lifetime] : []), ...(signal ? [signal] : [])])
    try {
      requestSignal.throwIfAborted()
      const ref = tokenRef()
      const token = (await ctx.get('credentials')?.resolve(ref))?.value ?? process.env[ref]
      if (!token) throw new ApiError('缺少连接令牌，请复制配置后点连接眼镜', 'auth', 401)
      const response = await fetch(new URL(path, base), {
        method: body === undefined ? 'GET' : 'POST', redirect: 'error',
        headers: {Authorization: `Bearer ${token}`, ...(body === undefined ? {} : {'Content-Type': 'application/json'})},
        ...(body === undefined ? {} : {body: JSON.stringify(body)}), signal: requestSignal,
      })
      // Authentication failures also occur with empty/HTML bodies. Never parse them as JSON.
      if (response.status === 401 || response.status === 403) {
        await response.body?.cancel()
        throw new ApiError(response.status === 401
          ? '连接令牌失效，请重新复制配置后点连接眼镜'
          : '本机入口拒绝访问，请核对地址与权限', 'auth', response.status)
      }
      const reader = response.body?.getReader()
      const chunks = []; let bytes = 0
      if (reader) {
        try {
          while (true) {
            const part = await reader.read()
            if (part.done) break
            bytes += part.value.byteLength
            if (bytes > 1_048_576) {
              await reader.cancel()
              throw new ApiError('接口结果超过1 MiB，请缩小查询范围', 'size')
            }
            chunks.push(part.value)
          }
        } finally { reader.releaseLock() }
      }
      const text = Buffer.concat(chunks).toString('utf8')
      let value
      if (text.trim() && /(?:application\/json|\+json)\b/i.test(response.headers.get('content-type') ?? '')) {
        try { value = JSON.parse(text) }
        catch { throw new ApiError('接口返回了损坏的JSON，请检查本机服务', 'protocol', response.status) }
      }
      if (!response.ok) {
        const message = typeof value?.error === 'string' ? value.error.slice(0, 160) : `本机接口失败：HTTP ${response.status}`
        throw new ApiError(message, response.status >= 500 || response.status === 429 ? 'server' : 'http', response.status)
      }
      if (response.status === 204) return {}
      if (!value || typeof value !== 'object' || Array.isArray(value)) {
        throw new ApiError('接口未返回JSON对象，请检查服务地址', 'protocol', response.status)
      }
      return value
    } catch (error) {
      if (signal?.aborted) throw signal.reason
      if (!cleanup && lifetime.aborted) throw lifetime.reason
      if (error instanceof ApiError) throw error
      throw new ApiError(requestSignal.aborted ? '本机服务响应超时，请检查入口是否开启' : '无法连接本机服务，请检查OpenRayneo入口',
        requestSignal.aborted ? 'timeout' : 'network')
    }
  }
  return {api, base, tokenRef}
}
