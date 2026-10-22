import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, readdir, rm, symlink, link, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createHash, randomBytes } from 'node:crypto';
import { extractVerifiedArtifact, verifyIpa, hashVerifiedFile, safeZipName } from '../experimental/cloud-build/cloud-artifact.mjs';
import { zip, fixtureIpa } from './cloud-build-fixture.mjs';
const sha = x => createHash('sha256').update(x).digest('hex');
async function context(t, archive = zip([{ name: 'Fixture.ipa', data: fixtureIpa(), method: 8 }])) {
  const home = await realpath(await mkdtemp(join(tmpdir(), 'dsh-artifact-'))), source = join(home, 'artifact.zip'), output = join(home, 'output');
  await writeFile(source, archive);
  t.after(async () => {
    if ((await readdir(home)).includes('output')) assert(!(await readdir(output)).some(n => n.startsWith('.ipa-part-')));
    await rm(home, { recursive: true, force: true });
  });
  const args = { archive: source, directory: output, expectedSize: archive.length, expectedSha256: sha(archive) };
  return { home, source, output, args, extract: more => extractVerifiedArtifact({ ...args, ...more }) };
}
test('real TapGame official IPA passes every CRC and Payload check, retains exact known hash', async t => {
  const path = resolve('tests/fixtures/cloud-build/TapGame_unsigned.ipa');
  const ipa = await readFile(path);
  assert.equal(ipa.length, 45306); assert.equal(sha(ipa), 'e07179577a9272ca04898eb91e47730c18b5cb60490097091c2a0e2d1ecf1c4d');
  const f = await context(t, zip([{ name: 'build/TapGame_unsigned.ipa', data: ipa, method: 8 }, { name: 'note.txt', data: 'metadata' }]));
  const result = await f.extract();
  assert.equal(result.sha256, sha(ipa)); assert.equal(result.bytes, ipa.length);
  assert.equal(result.entries, 5); assert(result.artifact_zip_crc_verified && result.payload_structure_verified);
  assert.deepEqual(await readFile(result.path), ipa);
});
test('binary payload above old 8 MiB limit streams intact and cached no-clobber extraction is repeatable', async t => {
  const data = randomBytes(9 * 1024 * 1024 + 19), ipa = fixtureIpa([{ name: 'Payload/Fixture.app/large.bin', data, method: 8 }]);
  const f = await context(t, zip([{ name: 'large.ipa', data: ipa }]));
  const first = await f.extract(), second = await f.extract();
  assert(first.bytes > 8 * 1024 ** 2); assert.equal(first.sha256, sha(ipa)); assert.equal(second.path, first.path);
  assert.deepEqual(await readFile(first.path), ipa);
});
test('all ZIP paths reject traversal, absolute, drive, slash aliases and Unicode normalization aliases', () => {
  for (const path of ['../x','a/../x','/x','C:/x','a\\x','a//x','./x','a/./x','a /x','a./x','e\u0301/x','a\x00/x'])
    assert.throws(() => safeZipName(path));
});
for (const [name, entries] of [
  ['traversal', [{ name: '../Fixture.ipa', data: fixtureIpa() }]],
  ['case alias', [{ name: 'a.ipa', data: fixtureIpa() }, { name: 'A.IPA', data: fixtureIpa() }]],
  ['symlink', [{ name: 'a.ipa', data: fixtureIpa(), mode: 0xa1ff }]],
  ['file directory collision', [{ name: 'dir', data: 'x' }, { name: 'dir/a.ipa', data: fixtureIpa() }]],
  ['missing IPA', [{ name: 'readme.txt', data: 'not an IPA' }]],
  ['multiple IPA', [{ name: 'a.ipa', data: fixtureIpa() }, { name: 'b.ipa', data: fixtureIpa() }]],
]) test(`reject ${name} without publishing an IPA`, async t => {
  const f = await context(t, zip(entries)); await assert.rejects(f.extract());
  assert.deepEqual(await readdir(f.output), []);
});
test('multiple files may explicitly select one exact IPA member', async t => {
  const f = await context(t, zip([{ name: 'a.ipa', data: fixtureIpa() }, { name: 'b.ipa', data: fixtureIpa() }]));
  const result = await f.extract({ ipaMember: 'b.ipa' }); assert.equal(result.name, 'b.ipa');
});
test('corrupt CRC in unselected extra file still rejects the entire outer ZIP', async t => {
  const data = zip([{ name: 'a.ipa', data: fixtureIpa() }, { name: 'extra.txt', data: 'controlled' }]);
  const marker = data.indexOf(Buffer.from('controlled')); data[marker] ^= 1;
  const f = await context(t, data); await assert.rejects(f.extract(), /zip_crc_mismatch/);
});
test('mismatched official digest or byte count prevents extraction', async t => {
  const f = await context(t);
  await assert.rejects(f.extract({ expectedSha256: '0'.repeat(64) }), /artifact_digest_mismatch/);
  await assert.rejects(f.extract({ expectedSize: f.args.expectedSize + 1 }), /artifact_digest_mismatch/);
});
test('central/local mismatch, truncated and overlapping ZIP entries reject', async t => {
  const original = zip([{ name: 'a.ipa', data: fixtureIpa() }, { name: 'extra', data: 'x' }]);
  for (const kind of ['local', 'truncated', 'overlap']) {
    const data = Buffer.from(original);
    if (kind === 'local') data[30] ^= 1;
    if (kind === 'overlap') {
      let at = data.indexOf(Buffer.from('504b0102', 'hex')); at = data.indexOf(Buffer.from('504b0102', 'hex'), at + 4);
      data.writeUInt32LE(0, at + 42);
    }
    const f = await context(t, kind === 'truncated' ? data.subarray(0, data.length - 1) : data);
    await assert.rejects(f.extract());
  }
});
test('existing different IPA is preserved byte for byte', async t => {
  const f = await context(t); await mkdir(f.output); const path = join(f.output, 'Fixture.ipa');
  await writeFile(path, 'existing signed file'); await assert.rejects(f.extract(), /existing_ipa_preserved/);
  assert.equal(await readFile(path, 'utf8'), 'existing signed file');
});
test('archive and output parent symlinks and hardlinked input are refused', async t => {
  const f = await context(t), alias = join(f.home, 'alias.zip');
  await symlink(f.source, alias); await assert.rejects(f.extract({ archive: alias }), /unsafe_file/);
  await link(f.source, join(f.home, 'hard.zip')); await assert.rejects(f.extract(), /unsafe_file/);
  await mkdir(join(f.home, 'real')); await symlink(join(f.home, 'real'), f.output);
  await assert.rejects(f.extract(), /unsafe_file/);
});
test('inner IPA must have one app, an Info.plist and a Mach-O executable', async t => {
  for (const entries of [[{ name: 'a.txt', data: 'x' }],
    [{ name: 'Payload/A.app/Info.plist', data: 'bplist00x' }]]) {
    const f = await context(t, zip([{ name: 'invalid.ipa', data: zip(entries) }]));
    await assert.rejects(f.extract(), /invalid_ipa_payload/);
  }
});
test('abort never publishes an incomplete IPA', async t => {
  const f = await context(t), controller = new AbortController(); controller.abort();
  await assert.rejects(f.extract({ signal: controller.signal }), /cancelled/);
});
