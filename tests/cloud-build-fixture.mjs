import { deflateRawSync } from 'node:zlib';
import { crc32 } from '../experimental/cloud-build/cloud-artifact.mjs';
export function zip(entries) {
  const local = [], central = []; let offset = 0;
  for (const item of entries) {
    const name = Buffer.from(item.name), data = Buffer.from(item.data ?? ''), method = item.method ?? 0;
    const compressed = method === 8 ? deflateRawSync(data) : data, crc = crc32(data);
    const header = Buffer.alloc(30); header.writeUInt32LE(0x04034b50); header.writeUInt16LE(20, 4);
    header.writeUInt16LE(0x800, 6); header.writeUInt16LE(method, 8); header.writeUInt32LE(crc, 14);
    header.writeUInt32LE(compressed.length, 18); header.writeUInt32LE(data.length, 22); header.writeUInt16LE(name.length, 26);
    const record = Buffer.alloc(46); record.writeUInt32LE(0x02014b50); record.writeUInt16LE(0x314, 4); record.writeUInt16LE(20, 6);
    record.writeUInt16LE(0x800, 8); record.writeUInt16LE(method, 10); record.writeUInt32LE(crc, 16);
    record.writeUInt32LE(compressed.length, 20); record.writeUInt32LE(data.length, 24); record.writeUInt16LE(name.length, 28);
    record.writeUInt32LE(((item.mode ?? (item.name.endsWith('/') ? 0x41ed : 0x81a4)) * 65536) >>> 0, 38);
    record.writeUInt32LE(offset, 42);
    local.push(header, name, compressed); central.push(record, name); offset += header.length + name.length + compressed.length;
  }
  const directory = Buffer.concat(central), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, directory, end]);
}
export function fixtureIpa(extra = []) {
  const executable = Buffer.alloc(64); executable.writeUInt32LE(0xfeedfacf);
  return zip([{ name: 'Payload/' }, { name: 'Payload/Fixture.app/' },
    { name: 'Payload/Fixture.app/Info.plist', data: 'bplist00controlled structure fixture only' },
    { name: 'Payload/Fixture.app/Fixture', data: executable }, ...extra]);
}
