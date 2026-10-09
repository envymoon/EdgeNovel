// Format conversion only: resize the approved artwork into Windows ICO frames.
// Usage: node make_windows_icon.cjs approved.png app_icon.ico
const fs = require('node:fs');
const sharp = require('sharp');

async function main() {
  const [source, output] = process.argv.slice(2);
  if (!source || !output) throw new Error('Provide source PNG and destination ICO');
  const sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256];
  const frames = await Promise.all(sizes.map(size =>
    sharp(source).resize(size, size, { fit: 'contain', background: '#00000000' }).png().toBuffer(),
  ));
  const header = Buffer.alloc(6 + sizes.length * 16);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(sizes.length, 4);
  let offset = header.length;
  frames.forEach((frame, i) => {
    const at = 6 + i * 16;
    header[at] = sizes[i] % 256;
    header[at + 1] = sizes[i] % 256;
    header.writeUInt16LE(1, at + 4);
    header.writeUInt16LE(32, at + 6);
    header.writeUInt32LE(frame.length, at + 8);
    header.writeUInt32LE(offset, at + 12);
    offset += frame.length;
  });
  fs.writeFileSync(output, Buffer.concat([header, ...frames]));
  console.log(`Created ${sizes.length} icon sizes (${offset} bytes)`);
}
main().catch(error => { console.error(error); process.exitCode = 1; });
