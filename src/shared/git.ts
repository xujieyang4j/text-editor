import type { GitRemote, GitTrackingStatus } from './ipc.js'

/** Remove embedded URL credentials before Git metadata crosses into the renderer. */
export function sanitizeGitRemoteUrl(value: string): string {
  const url = value.trim()
  if (!url) return ''
  const helper = /^([A-Za-z0-9][A-Za-z0-9+.-]*)::(.+)$/.exec(url)
  if (helper) {
    if (helper[1].toLowerCase() === 'ext') return `${helper[1]}::[redacted]`
    const address = helper[2].trim()
    const urlLike = /^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(address) ||
      /^[^/@:\s]+(?::[^@\s]+)?@[^:\s]+:.+$/.test(address) ||
      /^(?:\.{0,2}\/|\/)/.test(address)
    return `${helper[1]}::${urlLike ? sanitizeGitRemoteUrl(address) : '[redacted]'}`
  }
  const credentialScp = /^[^/@:\s]+:[^@\s]+@([^:\s]+):(.+)$/.exec(url)
  if (credentialScp) return `${credentialScp[1]}:${credentialScp[2]}`
  const scp = /^[^/@:\s]+@([^:\s]+):(.+)$/.exec(url)
  if (scp) return `${scp[1]}:${scp[2]}`
  try {
    const parsed = new URL(url)
    // Userinfo can carry tokens even without a password. SSH usernames are
    // not secrets, but omitting all URL userinfo is the safest display rule.
    if (parsed.username || parsed.password) {
      parsed.username = ''
      parsed.password = ''
    }
    parsed.search = ''
    parsed.hash = ''
    const sanitized = parsed.toString()
    try {
      return decodeURI(sanitized)
    } catch {
      return sanitized
    }
  } catch {
    // SCP-like Git URLs (user@host:path) contain identity, not a password.
    // A colon inside the userinfo is nevertheless credential-shaped and must
    // never cross into renderer-visible status.
    return url.replace(/^([^@/:]+):[^@]*@([^:]+):(.*)$/, '$2:$3')
  }
}

/** Parse `git config --get-regexp remote.*.(url|pushurl)` output. */
export function parseGitRemoteLines(text: string): GitRemote[] {
  const byName = new Map<string, GitRemote>()
  const lines = text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean)
  for (let index = 0; index < lines.length; index += 1) {
    const inline = /^remote\.(.+)\.(url|pushurl)[\t ]+(.+)$/.exec(lines[index])
    const splitKey = /^remote\.(.+)\.(url|pushurl)$/.exec(lines[index])
    const match = inline ?? (splitKey && lines[index + 1] ? [lines[index], splitKey[1], splitKey[2], lines[++index]] : null)
    if (!match) continue
    const [, name, kind, rawUrl] = match
    const url = sanitizeGitRemoteUrl(rawUrl).slice(0, 4_096)
    if (!url) continue
    const remote = byName.get(name) ?? { name }
    if (kind === 'url') remote.fetchUrl ??= url
    else remote.pushUrl ??= url
    byName.set(name, remote)
  }
  return [...byName.values()].sort((a, b) => a.name.localeCompare(b.name)).slice(0, 100)
}

/** Parse the local tracking ref and `rev-list --left-right --count` result. */
export function parseGitTracking(
  upstreamText: string,
  aheadBehindText: string,
  remoteText = '',
  remoteRefText = ''
): GitTrackingStatus {
  const upstream = upstreamText.trim() || undefined
  const remote = remoteText.trim() || undefined
  const rawRemoteRef = remoteRefText.trim()
  const remoteBranch = rawRemoteRef
    ? rawRemoteRef.replace(/^refs\/heads\//, '')
    : undefined
  const values = aheadBehindText.trim().split(/\s+/)
  const count = (value: string | undefined): number => {
    const parsed = Number(value)
    return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : Number.NaN
  }
  const ahead = count(values[0])
  const behind = count(values[1])
  const comparable = values.length === 2 && Number.isFinite(ahead) && Number.isFinite(behind)
  return {
    ...(upstream ? { upstream } : {}),
    ...(remote ? { remote } : {}),
    ...(remoteBranch ? { remoteBranch } : {}),
    ...(comparable ? { ahead, behind } : {})
  }
}
