import { performance } from 'node:perf_hooks'

const files = Array.from({ length: 20000 }, (_, index) => `src/module-${index % 80}/feature-${index}.ts`)
const query = 'modfeat'
const started = performance.now()
let matches = 0
for (const file of files) {
  let position = 0
  for (const char of query) {
    position = file.toLowerCase().indexOf(char, position)
    if (position < 0) break
    position += 1
  }
  if (position >= 0) matches += 1
}
const elapsed = performance.now() - started
console.log(`fuzzy-index benchmark: ${files.length} paths, ${matches} matches, ${elapsed.toFixed(1)} ms`)
if (elapsed > 1500) process.exitCode = 1
