#!/usr/bin/env node

/**
 * Repair the development Electron.app after macOS Gatekeeper/XProtect has
 * quarantined it or moved it to the Trash.
 *
 * This script deliberately touches only this project's Electron runtime. It
 * does not disable Gatekeeper or change any system-wide security setting.
 */

import { existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const scriptDir = dirname(fileURLToPath(import.meta.url))
const projectRoot = resolve(scriptDir, '..')
const electronDir = join(projectRoot, 'node_modules', 'electron')
const electronApp = join(electronDir, 'dist', 'Electron.app')
const electronInstaller = join(electronDir, 'install.js')

function log(message) {
  process.stdout.write(`[fix:mac] ${message}\n`)
}

function fail(message) {
  process.stderr.write(`[fix:mac] ERROR: ${message}\n`)
  process.exit(1)
}

/** Run a command without a shell so paths cannot be interpreted as code. */
function run(command, args, options = {}) {
  log(`Running ${command} ${args.join(' ')}`)
  const result = spawnSync(command, args, {
    cwd: projectRoot,
    stdio: 'inherit',
    shell: false,
    ...options
  })

  if (result.error) {
    fail(`${command} could not be started: ${result.error.message}`)
  }
  if (result.status !== 0) {
    fail(`${command} exited with status ${result.status ?? 'unknown'}`)
  }
}

/** Return stdout for a successful read-only command. */
function capture(command, args) {
  const result = spawnSync(command, args, {
    cwd: projectRoot,
    encoding: 'utf8',
    shell: false
  })

  if (result.error) {
    fail(`${command} could not be started: ${result.error.message}`)
  }
  if (result.status !== 0) {
    fail(`${command} exited with status ${result.status ?? 'unknown'}`)
  }
  return result.stdout ?? ''
}

if (process.platform !== 'darwin') {
  log(`Skipped: this command is only needed on macOS (current platform: ${process.platform}).`)
  process.exit(0)
}

log(`Target: ${electronApp}`)

// XProtect may have moved only Electron.app to the Trash. Re-run Electron's
// installer to restore a freshly checksum-verified runtime in that case.
if (!existsSync(electronApp)) {
  log('Electron.app is missing; restoring the Electron runtime first…')

  if (existsSync(electronInstaller)) {
    run(process.execPath, [electronInstaller], {
      env: { ...process.env, force_no_cache: 'true' }
    })
  } else {
    log('The electron package is also missing; restoring dependencies with npm install…')
    const npmCommand = process.platform === 'win32' ? 'npm.cmd' : 'npm'
    run(npmCommand, ['install'])
  }
}

if (!existsSync(electronApp)) {
  fail(
    'Electron.app is still missing after reinstall. Check the macOS security notification, ' +
      'your network/ELECTRON_MIRROR setting, then run this command again.'
  )
}

// Remove only the quarantine metadata, including attributes attached to nested
// files in the bundle. Check first so a clean bundle remains an idempotent
// success. Do not use `spctl --master-disable` or weaken Gatekeeper globally.
const attributes = capture('/usr/bin/xattr', ['-lr', electronApp])
if (attributes.includes('com.apple.quarantine')) {
  run('/usr/bin/xattr', ['-dr', 'com.apple.quarantine', electronApp])
} else {
  log('No quarantine attribute found; continuing with signature repair.')
}

// Ad-hoc sign the local development runtime. This is intentionally not a
// distribution signature; release builds should use Developer ID + notarization.
run('/usr/bin/codesign', [
  '--force',
  '--deep',
  '--sign',
  '-',
  '--timestamp=none',
  electronApp
])

// Fail loudly if the resulting bundle is internally inconsistent.
run('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', electronApp])

log('Done. Electron.app is repaired for local development.')
log('Start the editor with: npm run dev')
