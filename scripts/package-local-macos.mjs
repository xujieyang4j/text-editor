#!/usr/bin/env node

/**
 * Build a macOS app for local use, apply an ad-hoc signature, verify it, and
 * create a ZIP from the signed bundle. This deliberately does not disable
 * Gatekeeper and does not produce a Developer ID/notarized release artifact.
 */

import { existsSync } from 'node:fs'
import { lstat, mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, stat } from 'node:fs/promises'
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const scriptDir = dirname(fileURLToPath(import.meta.url))
const projectRoot = resolve(scriptDir, '..')
const packageJsonPath = join(projectRoot, 'package.json')
const electronBuilderCli = join(projectRoot, 'node_modules', 'electron-builder', 'cli.js')

function log(message) {
  process.stdout.write(`[dist:mac:local] ${message}\n`)
}

function fail(message) {
  throw new Error(message)
}

function run(command, args, options = {}) {
  log(`Running ${basename(command)} ${args.join(' ')}`)
  const result = spawnSync(command, args, {
    cwd: projectRoot,
    stdio: 'inherit',
    shell: false,
    ...options
  })

  if (result.error) fail(`${command} could not be started: ${result.error.message}`)
  if (result.status !== 0) fail(`${command} exited with status ${result.status ?? 'unknown'}`)
}

function capture(command, args) {
  const result = spawnSync(command, args, {
    cwd: projectRoot,
    encoding: 'utf8',
    shell: false
  })

  if (result.error) fail(`${command} could not be started: ${result.error.message}`)
  if (result.status !== 0) {
    fail(`${command} exited with status ${result.status ?? 'unknown'}: ${(result.stderr || result.stdout || '').trim()}`)
  }
  return `${result.stdout ?? ''}${result.stderr ?? ''}`
}

async function pathExists(target) {
  try {
    await lstat(target)
    return true
  } catch (error) {
    if (error && typeof error === 'object' && error.code === 'ENOENT') return false
    throw error
  }
}

function usage() {
  process.stdout.write(`Usage: npm run dist:mac:local [-- --open] [-- --arm64|--x64|--universal]\n\n` +
    `  --open       Launch the generated app after packaging\n` +
    `  --arm64      Build for Apple Silicon\n` +
    `  --x64        Build for Intel Macs\n` +
    `  --universal  Build a universal app containing both architectures\n`)
}

function parseOptions(argv) {
  let arch
  let openAfterBuild = false

  for (const arg of argv) {
    if (arg === '--help' || arg === '-h') return { help: true }
    if (arg === '--open') {
      openAfterBuild = true
      continue
    }
    const candidate = arg.startsWith('--') ? arg.slice(2) : ''
    if (candidate === 'arm64' || candidate === 'x64' || candidate === 'universal') {
      if (arch && arch !== candidate) fail('Specify only one target architecture.')
      arch = candidate
      continue
    }
    fail(`Unknown option: ${arg}`)
  }

  const nativeArch = process.arch === 'arm64' || process.arch === 'x64' ? process.arch : undefined
  return { help: false, arch: arch ?? nativeArch, openAfterBuild }
}

function assertGeneratedPath(root, target) {
  const rel = relative(root, target)
  if (!rel || rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    fail(`Refusing to modify a path outside the local release directory: ${target}`)
  }
}

async function findPackagedApp(stagingRoot) {
  const candidates = []
  for (const output of await readdir(stagingRoot, { withFileTypes: true })) {
    if (!output.isDirectory() || !output.name.startsWith('mac')) continue
    const outputDir = join(stagingRoot, output.name)
    for (const entry of await readdir(outputDir, { withFileTypes: true })) {
      if (entry.isDirectory() && !entry.isSymbolicLink() && entry.name.endsWith('.app')) {
        candidates.push(join(outputDir, entry.name))
      }
    }
  }

  if (candidates.length !== 1) {
    fail(`Expected exactly one top-level .app in the staging directory, found ${candidates.length}.`)
  }
  return candidates[0]
}

async function verifyAppPath(stagingRoot, appPath) {
  const info = await lstat(appPath)
  if (!info.isDirectory() || info.isSymbolicLink()) fail(`Invalid application bundle: ${appPath}`)

  const resolvedRoot = await realpath(stagingRoot)
  const resolvedApp = await realpath(appPath)
  assertGeneratedPath(resolvedRoot, resolvedApp)

  const infoPlist = join(resolvedApp, 'Contents', 'Info.plist')
  if (!(await stat(infoPlist)).isFile()) fail(`Missing application metadata: ${infoPlist}`)
  return resolvedApp
}

function unsignedBuilderEnvironment() {
  const env = { ...process.env, CSC_IDENTITY_AUTO_DISCOVERY: 'false' }
  for (const key of Object.keys(env)) {
    if (key.startsWith('CSC_') || key.startsWith('APPLE_') || key.startsWith('WIN_CSC_')) {
      delete env[key]
    }
  }
  env.CSC_IDENTITY_AUTO_DISCOVERY = 'false'
  return env
}

function clearQuarantine(appPath) {
  const attributes = capture('/usr/bin/xattr', ['-lr', appPath])
  if (attributes.includes('com.apple.quarantine')) {
    run('/usr/bin/xattr', ['-dr', 'com.apple.quarantine', appPath])
  } else {
    log('No quarantine attribute found on the generated app.')
  }

  assertNoQuarantine(appPath)
}

function assertNoQuarantine(appPath) {
  const attributes = capture('/usr/bin/xattr', ['-lr', appPath])
  if (attributes.includes('com.apple.quarantine')) fail(`A quarantine attribute remains on ${appPath}.`)
}

function verifyAdHocSignature(appPath, expected) {
  run('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=4', appPath])

  const details = capture('/usr/bin/codesign', ['--display', '--verbose=4', appPath])
  if (!/^Signature=adhoc$/m.test(details)) {
    fail(`The application does not have the expected ad-hoc signature: ${appPath}`)
  }

  const identifier = details.match(/^Identifier=(.+)$/m)?.[1]?.trim()
  if (!identifier) fail(`The application signature has no bundle identifier: ${appPath}`)
  const cdHashes = [...details.matchAll(/^CDHash=([0-9a-f]+)$/gmi)].map((match) => match[1].toLowerCase()).sort()

  if (expected?.identifier && identifier !== expected.identifier) {
    fail(`Bundle identifier changed after packaging: expected ${expected.identifier}, found ${identifier}.`)
  }
  if (expected?.cdHashes?.length > 0 && cdHashes.join(',') !== expected.cdHashes.join(',')) {
    fail('The application signature changed while creating the ZIP.')
  }
  return { identifier, cdHashes }
}

function signAndVerify(appPath) {
  run('/usr/bin/codesign', [
    '--force',
    '--deep',
    '--sign',
    '-',
    '--timestamp=none',
    appPath
  ])
  return verifyAdHocSignature(appPath)
}

async function publishOutput(stagedOutputDir, finalOutputDir, verify) {
  const stagingRoot = dirname(stagedOutputDir)
  const previousOutputDir = join(stagingRoot, 'previous-output')
  const failedOutputDir = join(stagingRoot, 'failed-output')
  let hadPreviousOutput = false
  let published = false

  if (await pathExists(finalOutputDir)) {
    const info = await lstat(finalOutputDir)
    if (!info.isDirectory() || info.isSymbolicLink()) {
      fail(`Refusing to replace an unexpected local output path: ${finalOutputDir}`)
    }
    await rename(finalOutputDir, previousOutputDir)
    hadPreviousOutput = true
  }

  try {
    await rename(stagedOutputDir, finalOutputDir)
    published = true
    await verify()
  } catch (error) {
    try {
      if (published && await pathExists(finalOutputDir)) await rename(finalOutputDir, failedOutputDir)
      if (hadPreviousOutput) await rename(previousOutputDir, finalOutputDir)
    } catch (rollbackError) {
      throw new AggregateError([error, rollbackError], 'Publishing failed and the previous local build could not be restored.')
    }
    throw error
  }
}

async function main() {
  const options = parseOptions(process.argv.slice(2))
  if (options.help) {
    usage()
    return
  }
  if (process.platform !== 'darwin') {
    fail(`This command must run on macOS (current platform: ${process.platform}).`)
  }
  if (!options.arch) fail(`Unsupported native architecture: ${process.arch}`)

  for (const tool of ['/usr/bin/xattr', '/usr/bin/codesign', '/usr/bin/ditto']) {
    if (!existsSync(tool)) fail(`Required macOS tool is missing: ${tool}`)
  }
  if (!existsSync(electronBuilderCli)) fail('electron-builder is missing. Run npm install first.')

  const packageJson = JSON.parse(await readFile(packageJsonPath, 'utf8'))
  if (typeof packageJson.version !== 'string' || !packageJson.version) fail('package.json has no valid version.')

  const resolvedProjectRoot = await realpath(projectRoot)
  const releaseBase = resolve(projectRoot, 'release')
  await mkdir(releaseBase, { recursive: true })
  const resolvedReleaseBase = await realpath(releaseBase)
  assertGeneratedPath(resolvedProjectRoot, resolvedReleaseBase)

  const requestedReleaseRoot = resolve(releaseBase, packageJson.version)
  assertGeneratedPath(resolvedReleaseBase, requestedReleaseRoot)
  await mkdir(requestedReleaseRoot, { recursive: true })
  const releaseRoot = await realpath(requestedReleaseRoot)
  assertGeneratedPath(resolvedReleaseBase, releaseRoot)
  const stagingRoot = await mkdtemp(join(releaseRoot, '.mac-local-'))
  assertGeneratedPath(releaseRoot, stagingRoot)

  try {
    run('npm', ['run', 'build'])
    run(process.execPath, [
      electronBuilderCli,
      '--mac',
      'dir',
      `--${options.arch}`,
      '--publish',
      'never',
      '--config.mac.identity=null',
      '--config.mac.notarize=false',
      `--config.directories.output=${stagingRoot}`
    ], { env: unsignedBuilderEnvironment() })

    const appPath = await verifyAppPath(stagingRoot, await findPackagedApp(stagingRoot))
    const appName = basename(appPath)
    const productName = appName.slice(0, -'.app'.length)
    log(`Preparing ${appName} for local use…`)

    clearQuarantine(appPath)
    const sourceSignature = signAndVerify(appPath)

    const localZipName = `${productName}-${packageJson.version}-mac-${options.arch}-local.zip`
    const stagedZip = join(stagingRoot, `${localZipName}.partial`)
    run('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', appPath, stagedZip])
    if ((await stat(stagedZip)).size === 0) fail('The generated ZIP is empty.')

    const verificationRoot = join(stagingRoot, 'verify-zip')
    await mkdir(verificationRoot)
    run('/usr/bin/ditto', ['-x', '-k', stagedZip, verificationRoot])
    const extractedApp = await verifyAppPath(verificationRoot, join(verificationRoot, appName))
    assertNoQuarantine(extractedApp)
    verifyAdHocSignature(extractedApp, sourceSignature)

    const stagedOutputDir = join(stagingRoot, 'publish')
    const finalOutputDir = join(releaseRoot, `mac-${options.arch}-local`)
    const stagedApp = join(stagedOutputDir, appName)
    const stagedFinalZip = join(stagedOutputDir, localZipName)
    assertGeneratedPath(stagingRoot, stagedOutputDir)
    assertGeneratedPath(releaseRoot, finalOutputDir)

    await mkdir(stagedOutputDir)
    await rename(appPath, stagedApp)
    await rename(stagedZip, stagedFinalZip)

    const finalApp = join(finalOutputDir, appName)
    const finalZip = join(finalOutputDir, localZipName)
    await publishOutput(stagedOutputDir, finalOutputDir, async () => {
      verifyAdHocSignature(finalApp, sourceSignature)
      if ((await stat(finalZip)).size === 0) fail('The published ZIP is empty.')
    })
    log(`App ready: ${finalApp}`)
    log(`ZIP ready: ${finalZip}`)
    log('This is an ad-hoc signed local build, not a notarized distribution build.')

    if (options.openAfterBuild) run('/usr/bin/open', [finalApp])
  } finally {
    await rm(stagingRoot, { recursive: true, force: true })
  }
}

main().catch((error) => {
  process.stderr.write(`[dist:mac:local] ERROR: ${error instanceof Error ? error.message : String(error)}\n`)
  process.exitCode = 1
})
