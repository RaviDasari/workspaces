import { describe, expect, test } from 'claude-code/testing'

import { describeChanges, formatOverview, parseStatus } from './overview'

describe('parseStatus', () => {
  test('clean tracked branch', () => {
    const s = parseStatus('api', '## main...origin/main\n')
    expect(s.branch).toBe('main')
    expect(describeChanges(s)).toBe('clean')
  })
  test('counts staged, modified, untracked and ahead/behind', () => {
    const s = parseStatus('web', '## feature/x...origin/feature/x [ahead 2, behind 1]\nM  a\n M b\nMM c\n?? d\n?? e\n')
    expect(s.branch).toBe('feature/x')
    expect([s.ahead, s.behind]).toEqual([2, 1])
    expect([s.staged, s.modified, s.untracked]).toEqual([2, 2, 2])
    expect(describeChanges(s)).toBe('2 staged · 2 modified · 2 untracked')
  })
  test('detached, no commits, conflicts', () => {
    expect(parseStatus('a', '## HEAD (no branch)\n').branch).toBe('detached')
    expect(parseStatus('a', '## No commits yet on main\n').branch).toBe('main (no commits)')
    expect(parseStatus('a', '## main\nUU f\n').conflicted).toBe(1)
  })
})

describe('formatOverview', () => {
  test('one row per repo plus a summary', () => {
    const rows = [parseStatus('api', '## main\n'), parseStatus('web', '## dev [ahead 1]\n M x\n')]
    const text = formatOverview('idp', rows, ['broken'])
    expect(text).toContain('idp: 2 repos')
    expect(text).toContain('✓ api')
    expect(text).toContain('● web')
    expect(text).toContain('dev ↑1')
    expect(text).toContain('? broken')
    expect(text).toContain('1 with uncommitted changes')
  })
})
