import { createHash } from 'node:crypto'
import { existsSync } from 'node:fs'
import { resolve } from 'node:path'
import { spawnSync } from 'node:child_process'

const [workerArgument, parserBundleArgument] = process.argv.slice(2)
if (!workerArgument || !parserBundleArgument) {
  throw new Error('Usage: node test-worker-process.mjs <worker> <parser-bundle>')
}
const worker = resolve(workerArgument)
const parserBundle = resolve(parserBundleArgument)
if (!existsSync(worker)) throw new Error('Worker executable is missing: ' + worker)
if (!existsSync(parserBundle)) throw new Error('Parser bundle is missing: ' + parserBundle)

function runWorker(args, requests, label) {
  const result = spawnSync(worker, args, {
    encoding: 'utf8',
    input: requests.map((request) => JSON.stringify(request)).join('\n') + '\n',
    maxBuffer: 8 * 1024 * 1024,
    timeout: 15_000
  })
  if (result.error) throw new Error(label + ' worker failed: ' + result.error.message)
  if (result.status !== 0) {
    throw new Error(label + ' worker exited with ' + result.status + ': ' + result.stderr.trim())
  }
  const lines = result.stdout.trim().split(/\r?\n/u).filter(Boolean)
  try {
    return lines.map((line) => JSON.parse(line))
  } catch (error) {
    throw new Error(label + ' worker returned invalid JSON-lines: ' + error.message)
  }
}

const parserResponses = runWorker(['--parser-worker', parserBundle], [{
  version: 2,
  requestId: 'parse',
  text: 'function demo(value) {\n  return (value + 1)\n}\n',
  language: 'javascript',
  tabWidth: 4,
  indentWidth: 2,
  insertSpaces: true,
  newlineIndentationPositions: [21]
}], 'Parser')
const parser = parserResponses[0]
if (parserResponses.length !== 1 || parser?.version !== 2 || parser?.requestId !== 'parse'
    || parser?.error || parser?.result?.supported !== true || parser?.result?.parserKind !== 'lezer'
    || parser.result.highlights?.length === 0 || parser.result.syntaxNodes?.length === 0
    || parser.result.bracketPairs?.length === 0 || parser.result.symbols?.length === 0
    || parser.result.newlineIndentation?.length !== 1) {
  throw new Error('Parser worker response did not satisfy the schema-v2 smoke contract.')
}

const pluginSource = "self.onmessage=function(e){if(e.data.type==='activate')postMessage({type:'register-command',id:'hello',title:'Hello'});if(e.data.type==='run-command')postMessage({type:'notify',text:e.data.id});}"
const integrity = 'sha256-' + createHash('sha256').update(pluginSource).digest('base64')
const pluginRequests = [
  { version: 1, type: 'load', requestId: 'load', source: pluginSource, sourceIntegrity: integrity },
  { version: 1, type: 'activate', requestId: 'activate', context: { permissions: [] } },
  { version: 1, type: 'run-command', requestId: 'run', commandId: 'hello', context: { permissions: [] } },
  { version: 1, type: 'deactivate', requestId: 'deactivate', context: { permissions: [] } }
]
const pluginResponses = runWorker(
  ['--plugin-worker', 'smoke-worker', integrity, '[]'], pluginRequests, 'Plugin')
const completed = new Set(pluginResponses
  .filter((response) => response.type === 'completed').map((response) => response.requestId))
if (pluginRequests.some((request) => !completed.has(request.requestId))
    || !pluginResponses.some((response) => response.requestId === 'activate'
      && response.type === 'register-command' && response.id === 'hello')
    || !pluginResponses.some((response) => response.requestId === 'run'
      && response.type === 'notify' && response.text === 'hello')) {
  throw new Error('Plugin worker response did not satisfy the protocol smoke contract.')
}

console.log('Worker process smoke passed: parser schema v' + parser.version
  + ', ' + pluginResponses.length + ' plugin responses.')
