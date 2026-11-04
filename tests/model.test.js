const test = require('node:test')
const assert = require('node:assert/strict')
const model = require('../Model.js')

test('accepts a bounded daemon event and normalizes its state', () => {
  const event = model.parseEvent(JSON.stringify({
    event: 'runtime.state',
    seq: 4,
    data: {
      revision: 2,
      state: 'paused',
      position: 3,
      duration: 10,
      seekable: true,
      track: { title: 'Track', path: '/music/track.flac' }
    }
  }))
  assert.equal(event.snapshot.state, 'paused')
  assert.equal(event.snapshot.position, 3)
  assert.equal(event.snapshot.track.title, 'Track')
})

test('rejects stale health updates by revision and session', () => {
  const stream = model.snapshotFrom({ revision: 7, state: 'playing' })
  const health = model.snapshotFrom({ revision: 6, state: 'paused' })
  assert.equal(model.shouldApplySnapshot(health, -1, 4, 4), true)
  assert.equal(model.shouldApplySnapshot(health, stream.revision, 4, 4), false)
  assert.equal(model.shouldApplySnapshot(stream, health.revision, 4, 4), true)
  assert.equal(model.shouldApplySnapshot(stream, -1, 4, 3), false)
  assert.equal(model.shouldApplySnapshot(stream, 7, 4, 4), true)
})

test('rejects unknown state, topics, and oversized events', () => {
  assert.equal(model.parseEvent(JSON.stringify({ event: 'runtime.state', data: { state: 'broken' } })), null)
  assert.equal(model.parseEvent(JSON.stringify({ event: 'other', data: { state: 'stopped' } })), null)
  assert.equal(model.parseEvent('x'.repeat(model.MAX_EVENT_LINE + 1)), null)
})

test('parses bounded favorites TOML with comments and escaped values', () => {
  const rows = model.parseFavoritesToml([
    '# comment',
    '[[entry]]',
    'path = "https://example.test/a?x=1#fragment"',
    'title = "A \\"quoted\\" title" # trailing',
    'realtime = true',
    '[[entry]]',
    "path = '/tmp/local.flac'"
  ].join('\n'))
  assert.equal(rows.length, 2)
  assert.equal(rows[0].title, 'A "quoted" title')
  assert.equal(rows[0].stream, true)
  assert.equal(rows[1].path, '/tmp/local.flac')
  assert.equal(model.parseFavoritesToml('x'.repeat(model.MAX_FAVORITES_BYTES + 1)), null)
})

test('validates paths, pids, and queue size', () => {
  assert.equal(model.safeFavoritesPath('/home/user'), '/home/user/.config/cliamp/favorites.toml')
  assert.equal(model.safeFavoritesPath('/home/user/../other'), '')
  assert.equal(model.safePid('12x'), 0)
  assert.equal(model.safePid('123'), 123)
  const queue = { ok: true, job: { state: 'succeeded', result: { tracks: [] } } }
  assert.deepEqual(model.parseQueueJob(JSON.stringify(queue)).tracks, [])
  const oversized = { ok: true, job: { state: 'succeeded', result: { tracks: new Array(model.MAX_TRACKS + 1).fill({}) } } }
  assert.equal(model.parseQueueJob(JSON.stringify(oversized)).ok, false)
})

test('parses queue durations and recovers the implicit zero index', () => {
  const response = {
    ok: true,
    snapshot: {
      state: 'playing',
      playlist_revision: 8,
      track: { title: 'First', path: '/music/first.flac' }
    },
    job: {
      state: 'succeeded',
      result: {
        total: 3,
        tracks: [
          { title: 'First', path: '/music/first.flac', duration_secs: 61 },
          { title: 'Second', path: '/music/second.flac', duration: 62.5 },
          { title: 'Live', path: 'https://example.test/live', realtime: true }
        ]
      }
    }
  }
  const queue = model.parseQueueJob(JSON.stringify(response))
  assert.equal(queue.ok, true)
  assert.equal(queue.total, 3)
  assert.equal(queue.index, 0)
  assert.equal(queue.tracks[0].current, true)
  assert.equal(queue.tracks[1].current, false)
  assert.equal(queue.tracks[0].duration, 61)
  assert.equal(queue.tracks[1].duration, 62.5)
  assert.equal(queue.tracks[2].stream, true)
})

test('keeps queue parsing bounded and caps the displayed rows', () => {
  const response = {
    ok: true,
    job: {
      state: 'succeeded',
      result: {
        total: 3,
        index: 1,
        tracks: [
          { title: 'First', path: '/music/first.flac' },
          { title: 'Second', path: '/music/second.flac' },
          { title: 'Third', path: '/music/third.flac' }
        ]
      }
    }
  }
  const queue = model.parseQueueJob(JSON.stringify(response))
  assert.equal(queue.index, 1)
  assert.equal(queue.tracks[1].current, true)
  assert.equal(model.parseQueueJob('not json').ok, false)
  assert.equal(model.parseQueueJob(JSON.stringify({ ok: false, job: {} })).ok, false)

  const rows = Array.from({ length: model.MAX_QUEUE_ROWS + 25 }, (_, index) => ({ index }))
  const visible = model.boundedQueueRows(rows, model.MAX_QUEUE_ROWS)
  assert.equal(visible.length, model.MAX_QUEUE_ROWS)
  assert.equal(visible[0].index, 0)
  assert.equal(model.boundedQueueRows(null, 10).length, 0)
})

test('bounds settings and command identities', () => {
  const settings = model.boundedSettings({ binary: 'cliamp', reconnectMs: 10, extra: 'x' })
  assert.deepEqual(settings, { binary: 'cliamp', reconnectMs: 10 })
  assert.equal(model.commandKey(['toggle', 'x']), model.commandKey(['toggle', 'x']))
  assert.notEqual(model.commandKey(['toggle']), model.commandKey(['stop']))
  assert.equal(model.scriptPath('file:///tmp/a.py'), '/tmp/a.py')
  assert.equal(model.scriptPath('file:///tmp/a.py\n'), '')
})
