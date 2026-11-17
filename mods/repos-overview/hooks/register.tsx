import type { Register } from 'claude-code'

import { formatOverview, parseStatus } from './overview'
import type { RepoSummary } from './overview'

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'repos',
      description: 'Branch and uncommitted-change overview of every repo in the workspace',
    })
    return next(e)
  })

  on('command.run', { command: 'repos' }, async $ => {
    const cwd = await $.session.cwd()
    const base = cwd.split('/').filter(Boolean).pop() ?? cwd
    const candidates: { name: string; path: string }[] = []

    // The session directory itself, when it is a repo.
    if (await $.fs.exists(`${cwd}/.git`)) candidates.push({ name: base, path: cwd })
    // Each visible child (real directory or symlink) that is a repo.
    for (const entry of await $.fs.list(cwd)) {
      if (entry.name.startsWith('.') || (entry.kind === 'file')) continue
      const path = `${cwd}/${entry.name}`
      if (await $.fs.exists(`${path}/.git`)) candidates.push({ name: entry.name, path })
    }
    if (candidates.length === 0) return { text: `No git repositories found in ${cwd}` }

    const rows: RepoSummary[] = []
    const failed: string[] = []
    await Promise.all(
      candidates.map(async c => {
        try {
          const r = await $.process.run(['git', '-C', c.path, 'status', '--porcelain=v1', '-b'], { timeoutMs: 15000 })
          if (r.exitCode === 0) rows.push(parseStatus(c.name, r.stdout))
          else failed.push(c.name)
        } catch {
          failed.push(c.name)
        }
      }),
    )
    rows.sort((a, b) => a.name.localeCompare(b.name))
    failed.sort()
    return { text: formatOverview(base, rows, failed) }
  })
}
