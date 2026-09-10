import assert from "node:assert/strict"
import { createHash } from "node:crypto"
import { cp, lstat, mkdir, mkdtemp, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { spawnSync } from "node:child_process"

const sourceRoot = join(dirname(fileURLToPath(import.meta.url)), "..")
const sourcePackage = JSON.parse(await readFile(join(sourceRoot, "package.json"), "utf8"))
const version = sourcePackage.version
const prefix = `text-editor-xujieyang-${version}`
const expectedByTarget = {
  "windows-x64": [
    `${prefix}-windows-x64-setup.exe`,
    `${prefix}-windows-x64-portable.exe`,
    `${prefix}-native-windows-x64.msix`,
    `${prefix}-native-windows-arm64.msix`
  ],
  "linux-x64": [
    `${prefix}-linux-x86_64.AppImage`,
    `${prefix}-linux-amd64.deb`
  ],
  "macos-x64": [
    `${prefix}-macos-x64.dmg`,
    `${prefix}-macos-x64.zip`,
    `${prefix}-native-macos-x64.dmg`,
    `${prefix}-native-macos-x64.zip`
  ],
  "macos-arm64": [
    `${prefix}-macos-arm64.dmg`,
    `${prefix}-macos-arm64.zip`,
    `${prefix}-native-macos-arm64.dmg`,
    `${prefix}-native-macos-arm64.zip`
  ]
}
const allExpected = Object.values(expectedByTarget).flat().sort()

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "lumen-release-artifacts-test-"))
  await mkdir(join(root, "scripts"), { recursive: true })
  await cp(join(sourceRoot, "scripts/release-artifacts.mjs"), join(root, "scripts/release-artifacts.mjs"))
  await writeFile(join(root, "package.json"), `${JSON.stringify({ type: "module", version })}\n`)
  return root
}

function run(root, ...arguments_) {
  return spawnSync(process.execPath, [join(root, "scripts/release-artifacts.mjs"), ...arguments_], {
    cwd: root,
    encoding: "utf8",
    env: { ...process.env, GITHUB_SHA: "0123456789abcdef" }
  })
}

async function writeExpectedFiles(root, names = allExpected) {
  const directory = join(root, "release", version)
  await mkdir(directory, { recursive: true })
  for (const [index, name] of names.entries()) {
    await writeFile(join(directory, name), `fixture-${index}-${name}\n`)
  }
  return directory
}

async function testVerifyTag() {
  const root = await fixture()
  try {
    assert.equal(run(root, "verify-tag", `v${version}`).status, 0)
    assert.notEqual(run(root, "verify-tag", version).status, 0)
    assert.notEqual(run(root, "verify-tag", "v0.1.1").status, 0)
    assert.notEqual(run(root, "verify-tag", "v01.1.0").status, 0)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
}

async function testStage() {
  const root = await fixture()
  try {
    await writeExpectedFiles(root, expectedByTarget["linux-x64"])
    assert.equal(run(root, "stage", "linux-x64").status, 0)
    assert.deepEqual(
      (await readdir(join(root, "release-assets"))).sort(),
      [...expectedByTarget["linux-x64"]].sort()
    )
  } finally {
    await rm(root, { recursive: true, force: true })
  }

  const stageFailures = ["missing", "empty"]
  if (process.platform !== "win32") stageFailures.push("symlink")
  for (const invalid of stageFailures) {
    const invalidRoot = await fixture()
    try {
      const names = expectedByTarget["linux-x64"]
      const directory = await writeExpectedFiles(invalidRoot, names)
      const target = join(directory, names[1])
      if (invalid === "missing") await rm(target)
      if (invalid === "empty") await writeFile(target, "")
      if (invalid === "symlink") {
        await rm(target)
        await symlink(join(directory, names[0]), target)
      }
      assert.notEqual(run(invalidRoot, "stage", "linux-x64").status, 0, invalid)
    } finally {
      await rm(invalidRoot, { recursive: true, force: true })
    }
  }
}

async function testVerifyAll() {
  const root = await fixture()
  try {
    const directory = join(root, "artifacts")
    await mkdir(directory)
    const expected = new Map()
    for (const [index, name] of allExpected.entries()) {
      const content = Buffer.from(`artifact-${index}-${name}\n`)
      expected.set(name, {
        bytes: content.length,
        sha256: createHash("sha256").update(content).digest("hex")
      })
      await writeFile(join(directory, name), content)
    }

    assert.equal(run(root, "verify-all", `v${version}`, "artifacts").status, 0)
    const manifest = JSON.parse(await readFile(join(directory, "release-manifest.json"), "utf8"))
    assert.equal(manifest.schemaVersion, 1)
    assert.equal(manifest.version, version)
    assert.equal(manifest.tag, `v${version}`)
    assert.equal(manifest.commit, "0123456789abcdef")
    assert.deepEqual(manifest.files.map(file => file.name), allExpected)
    for (const file of manifest.files) assert.deepEqual(
      { bytes: file.bytes, sha256: file.sha256 }, expected.get(file.name)
    )
    const checksumLines = (await readFile(join(directory, "SHA256SUMS.txt"), "utf8"))
      .trimEnd().split("\n")
    assert.deepEqual(
      checksumLines,
      allExpected.map(name => `${expected.get(name).sha256}  ${name}`)
    )
    assert.equal((await lstat(join(directory, "SHA256SUMS.txt"))).isFile(), true)
  } finally {
    await rm(root, { recursive: true, force: true })
  }

  const verifyFailures = ["missing", "extra", "empty", "directory"]
  if (process.platform !== "win32") verifyFailures.push("symlink")
  for (const invalid of verifyFailures) {
    const invalidRoot = await fixture()
    try {
      const directory = join(invalidRoot, "artifacts")
      await mkdir(directory)
      for (const [index, name] of allExpected.entries()) {
        await writeFile(join(directory, name), `artifact-${index}\n`)
      }
      if (invalid === "missing") await rm(join(directory, allExpected[0]))
      if (invalid === "extra") await writeFile(join(directory, "unexpected.txt"), "x")
      if (invalid === "empty") await writeFile(join(directory, allExpected[0]), "")
      if (invalid === "directory") await mkdir(join(directory, "unexpected"))
      if (invalid === "symlink") {
        const target = join(directory, allExpected[0])
        await rm(target)
        await symlink(join(directory, allExpected[1]), target)
      }
      assert.notEqual(
        run(invalidRoot, "verify-all", `v${version}`, "artifacts").status,
        0,
        invalid
      )
    } finally {
      await rm(invalidRoot, { recursive: true, force: true })
    }
  }
}

await testVerifyTag()
await testStage()
await testVerifyAll()
process.stdout.write("Release artifact contract tests passed.\n")
