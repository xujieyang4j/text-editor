#!/usr/bin/env node

/**
 * Keep the public GitHub Release surface small and deterministic. Platform
 * jobs stage only their expected installers; the publish job verifies the
 * complete set and creates checksums plus a machine-readable manifest.
 */

import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { copyFile, lstat, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDir = dirname(fileURLToPath(import.meta.url))
const projectRoot = resolve(scriptDir, '..')
const packageJson = JSON.parse(await readFile(join(projectRoot, 'package.json'), 'utf8'))
const version = packageJson.version
const prefix = `text-editor-xujieyang-${version}`

const STABLE_VERSION = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/

if (typeof version !== 'string' || !STABLE_VERSION.test(version)) {
  throw new Error('package.json must contain a stable semantic version (for example, 1.2.3).')
}

const expectedByTarget = {
  'windows-x64': [
    `${prefix}-windows-x64-setup.exe`,
    `${prefix}-windows-x64-portable.exe`
  ],
  'linux-x64': [
    `${prefix}-linux-x86_64.AppImage`,
    `${prefix}-linux-amd64.deb`
  ],
  'macos-x64': [
    `${prefix}-macos-x64.dmg`,
    `${prefix}-macos-x64.zip`
  ],
  'macos-arm64': [
    `${prefix}-macos-arm64.dmg`,
    `${prefix}-macos-arm64.zip`
  ]
}

const allExpected = Object.values(expectedByTarget).flat().sort()

function fail(message) {
  throw new Error(message)
}

function verifyTag(tag) {
  if (!new RegExp(`^v${STABLE_VERSION.source.slice(1, -1)}$`).test(tag || '')) {
    fail(`Release tag ${tag || '(empty)'} is not a stable v-prefixed semantic version.`)
  }
  if (tag !== `v${version}`) {
    fail(`Release tag ${tag} does not match package version v${version}.`)
  }
  process.stdout.write(`Release tag ${tag} matches package.json.\n`)
}

async function assertRegularNonemptyFile(file) {
  const info = await lstat(file)
  if (!info.isFile() || info.isSymbolicLink() || info.size === 0) {
    fail(`Expected a non-empty regular release file: ${file}`)
  }
  return info
}

async function sha256(file) {
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(file)) hash.update(chunk)
  return hash.digest('hex')
}

async function stage(target) {
  const names = expectedByTarget[target]
  if (!names) fail(`Unknown release target: ${target}`)
  const sourceDir = join(projectRoot, 'release', version)
  const outputDir = join(projectRoot, 'release-assets')
  await rm(outputDir, { recursive: true, force: true })
  await mkdir(outputDir, { recursive: true })

  for (const name of names) {
    const source = join(sourceDir, name)
    await assertRegularNonemptyFile(source)
    await copyFile(source, join(outputDir, name))
  }

  process.stdout.write(`Staged ${names.length} ${target} release files:\n`)
  for (const name of names) process.stdout.write(`- ${name}\n`)
}

async function verifyAll(tag, inputDirectory) {
  verifyTag(tag)
  const inputDir = resolve(projectRoot, inputDirectory)
  const actual = await readdir(inputDir, { withFileTypes: true })
  if (actual.some((entry) => !entry.isFile() || entry.isSymbolicLink())) {
    fail('The merged release artifact directory contains a non-file entry.')
  }
  const actualNames = actual.map((entry) => entry.name).sort()
  if (JSON.stringify(actualNames) !== JSON.stringify(allExpected)) {
    fail(`Unexpected release file set.\nExpected: ${allExpected.join(', ')}\nActual: ${actualNames.join(', ')}`)
  }

  const files = []
  for (const name of actualNames) {
    const file = join(inputDir, name)
    const info = await assertRegularNonemptyFile(file)
    files.push({ name, bytes: info.size, sha256: await sha256(file) })
  }

  const checksums = `${files.map((file) => `${file.sha256}  ${file.name}`).join('\n')}\n`
  await writeFile(join(inputDir, 'SHA256SUMS.txt'), checksums, 'utf8')
  const manifest = {
    schemaVersion: 1,
    version,
    tag,
    commit: process.env.GITHUB_SHA || null,
    files
  }
  await writeFile(join(inputDir, 'release-manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`, 'utf8')

  for (const file of files) {
    if (await sha256(join(inputDir, file.name)) !== file.sha256) fail(`Checksum verification failed for ${file.name}.`)
  }
  process.stdout.write(`Verified ${files.length} installers and wrote checksums plus a release manifest.\n`)
}

const [command, first, second] = process.argv.slice(2)
if (command === 'verify-tag' && first && !second) {
  verifyTag(first)
} else if (command === 'stage' && first && !second) {
  await stage(first)
} else if (command === 'verify-all' && first && second) {
  await verifyAll(first, second)
} else {
  process.stderr.write('Usage:\n  node scripts/release-artifacts.mjs verify-tag <vVERSION>\n  node scripts/release-artifacts.mjs stage <windows-x64|linux-x64|macos-x64|macos-arm64>\n  node scripts/release-artifacts.mjs verify-all <vVERSION> <artifact-directory>\n')
  process.exitCode = 2
}
