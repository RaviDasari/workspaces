export type RepoSummary = {
  name: string
  branch: string
  ahead: number
  behind: number
  staged: number
  modified: number
  untracked: number
  conflicted: number
}

// Reads `git status --porcelain=v1 -b` output into counts.
export function parseStatus(name: string, out: string): RepoSummary {
  const s: RepoSummary = { name, branch: '?', ahead: 0, behind: 0, staged: 0, modified: 0, untracked: 0, conflicted: 0 }
  for (const line of out.split('\n')) {
    if (line.startsWith('## ')) {
      const head = line.slice(3)
      const no = /^No commits yet on (.+)$/.exec(head)
      const detached = head.startsWith('HEAD (no branch)')
      s.branch = no ? `${no[1]} (no commits)` : detached ? 'detached' : head.split('...')[0].split(' ')[0]
      s.ahead = Number(/ahead (\d+)/.exec(head)?.[1] ?? 0)
      s.behind = Number(/behind (\d+)/.exec(head)?.[1] ?? 0)
    } else if (line.length >= 2) {
      const x = line[0]
      const y = line[1]
      if (x === '?' && y === '?') s.untracked++
      else if (x === 'U' || y === 'U' || (x === 'A' && y === 'A') || (x === 'D' && y === 'D')) s.conflicted++
      else {
        if (x !== ' ') s.staged++
        if (y !== ' ') s.modified++
      }
    }
  }
  return s
}

export function describeChanges(s: RepoSummary): string {
  const parts: string[] = []
  if (s.conflicted) parts.push(`${s.conflicted} conflicted`)
  if (s.staged) parts.push(`${s.staged} staged`)
  if (s.modified) parts.push(`${s.modified} modified`)
  if (s.untracked) parts.push(`${s.untracked} untracked`)
  return parts.length ? parts.join(' · ') : 'clean'
}

function sync(s: RepoSummary): string {
  return [s.ahead ? `↑${s.ahead}` : '', s.behind ? `↓${s.behind}` : ''].filter(Boolean).join(' ')
}

export function formatOverview(title: string, rows: RepoSummary[], failed: string[]): string {
  const w = Math.max(4, ...rows.map(r => r.name.length))
  const bw = Math.max(6, ...rows.map(r => (r.branch + ' ' + sync(r)).trim().length))
  const lines = [`${title}: ${rows.length} repo${rows.length === 1 ? '' : 's'}`]
  for (const r of rows) {
    const branch = (r.branch + ' ' + sync(r)).trim()
    const mark = describeChanges(r) === 'clean' ? '✓' : '●'
    lines.push(`  ${mark} ${r.name.padEnd(w)}  ${branch.padEnd(bw)}  ${describeChanges(r)}`)
  }
  for (const f of failed) lines.push(`  ? ${f}  (git status failed)`)
  const dirty = rows.filter(r => describeChanges(r) !== 'clean').length
  lines.push(dirty ? `${dirty} with uncommitted changes` : 'All clean')
  return lines.join('\n')
}
