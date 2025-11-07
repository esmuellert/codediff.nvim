#!/usr/bin/env node
/**
 * Version bumping utility for vscode-diff.nvim
 * Semantic versioning: MAJOR.MINOR.PATCH
 */

import { readFileSync, writeFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { execSync } from 'child_process';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

function bumpVersion(level) {
  const versionFile = join(__dirname, '..', 'VERSION');
  
  // Read current version
  const current = readFileSync(versionFile, 'utf8').trim();
  
  let [major, minor, patch] = current.split('.').map(Number);
  
  // Bump according to level
  switch (level) {
    case 'major':
      major += 1;
      minor = 0;
      patch = 0;
      break;
    case 'minor':
      minor += 1;
      patch = 0;
      break;
    case 'patch':
      patch += 1;
      break;
    default:
      console.error(`Error: Unknown level '${level}'`);
      console.log('Usage: bump_version.mjs [major|minor|patch]');
      process.exit(1);
  }
  
  const newVersion = `${major}.${minor}.${patch}`;
  
  // Write new version
  writeFileSync(versionFile, newVersion + '\n');
  
  console.log(`✓ Bumped version: ${current} → ${newVersion}`);
  
  // Auto-commit VERSION file
  try {
    execSync('git add VERSION', { stdio: 'inherit' });
    execSync(`git commit -m "chore: bump version to ${newVersion}"`, { stdio: 'inherit' });
    console.log(`✓ Committed VERSION file`);
    console.log('\nNext steps:');
    console.log(`  git tag v${newVersion}`);
    console.log(`  git push && git push --tags`);
  } catch (error) {
    console.error('\n⚠️  Failed to auto-commit. Please commit manually:');
    console.log(`  git add VERSION`);
    console.log(`  git commit -m 'chore: bump version to ${newVersion}'`);
    console.log(`  git tag v${newVersion}`);
    console.log(`  git push && git push --tags`);
  }
  
  return newVersion;
}

// Main
if (process.argv.length < 3) {
  console.log('Usage: bump_version.mjs [major|minor|patch]');
  console.log('\nExamples:');
  console.log('  bump_version.mjs patch  # 0.3.0 → 0.3.1 (bug fixes)');
  console.log('  bump_version.mjs minor  # 0.3.0 → 0.4.0 (new features)');
  console.log('  bump_version.mjs major  # 0.3.0 → 1.0.0 (breaking changes)');
  process.exit(1);
}

bumpVersion(process.argv[2]);
