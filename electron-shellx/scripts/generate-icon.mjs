import { deflateSync } from "node:zlib";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const outputDir = new URL("../build/icon.iconset/", import.meta.url);
mkdirSync(outputDir, { recursive: true });

const sizes = [16, 32, 64, 128, 256, 512, 1024];

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let index = 0; index < 8; index += 1) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type, data = Buffer.alloc(0)) {
  const name = Buffer.from(type, "ascii");
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  name.copy(out, 4);
  data.copy(out, 8);
  out.writeUInt32BE(crc32(Buffer.concat([name, data])), 8 + data.length);
  return out;
}

function writePNG(path, width, height, rgba) {
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y += 1) {
    const row = y * (width * 4 + 1);
    raw[row] = 0;
    rgba.copy(raw, row + 1, y * width * 4, (y + 1) * width * 4);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 6;
  header[10] = 0;
  header[11] = 0;
  header[12] = 0;
  writeFileSync(path, Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND")
  ]));
}

function mix(a, b, t) {
  return Math.round(a + (b - a) * t);
}

function roundedAlpha(x, y, size, radius) {
  const min = radius;
  const max = size - radius;
  const cx = x < min ? min : x > max ? max : x;
  const cy = y < min ? min : y > max ? max : y;
  const distance = Math.hypot(x - cx, y - cy);
  return Math.max(0, Math.min(1, radius + 0.5 - distance));
}

function blendPixel(rgba, width, x, y, color, alpha) {
  if (x < 0 || y < 0 || x >= width || y >= width || alpha <= 0) return;
  const idx = (y * width + x) * 4;
  const a = alpha * (rgba[idx + 3] / 255);
  rgba[idx] = mix(rgba[idx], color[0], a);
  rgba[idx + 1] = mix(rgba[idx + 1], color[1], a);
  rgba[idx + 2] = mix(rgba[idx + 2], color[2], a);
}

function stampCircle(rgba, width, cx, cy, radius, color, opacity) {
  const minX = Math.floor(cx - radius - 1);
  const maxX = Math.ceil(cx + radius + 1);
  const minY = Math.floor(cy - radius - 1);
  const maxY = Math.ceil(cy + radius + 1);
  for (let y = minY; y <= maxY; y += 1) {
    for (let x = minX; x <= maxX; x += 1) {
      const distance = Math.hypot(x + 0.5 - cx, y + 0.5 - cy);
      const alpha = Math.max(0, Math.min(1, radius + 0.75 - distance)) * opacity;
      blendPixel(rgba, width, x, y, color, alpha);
    }
  }
}

function drawWave(rgba, width, color, radius, opacity, offset = 0) {
  for (let i = 0; i <= 180; i += 1) {
    const t = i / 180;
    const x = width * (0.26 + 0.48 * t) + offset;
    const y = width * (0.5 + 0.18 * Math.sin(Math.PI * 2 * (t - 0.12))) + offset;
    stampCircle(rgba, width, x, y, radius, color, opacity);
  }
}

function render(size) {
  const scale = size <= 128 ? 3 : 1;
  const high = size * scale;
  const highRGBA = Buffer.alloc(high * high * 4);
  const radius = high * 0.22;

  for (let y = 0; y < high; y += 1) {
    for (let x = 0; x < high; x += 1) {
      const alpha = roundedAlpha(x + 0.5, y + 0.5, high, radius);
      const t = Math.max(0, Math.min(1, (x + y) / (high * 1.4)));
      const mid = t < 0.55 ? t / 0.55 : (t - 0.55) / 0.45;
      const c1 = [51, 143, 255];
      const c2 = [148, 87, 255];
      const c3 = [32, 220, 188];
      const color = t < 0.55
        ? [mix(c1[0], c2[0], mid), mix(c1[1], c2[1], mid), mix(c1[2], c2[2], mid)]
        : [mix(c2[0], c3[0], mid), mix(c2[1], c3[1], mid), mix(c2[2], c3[2], mid)];
      const idx = (y * high + x) * 4;
      highRGBA[idx] = color[0];
      highRGBA[idx + 1] = color[1];
      highRGBA[idx + 2] = color[2];
      highRGBA[idx + 3] = Math.round(alpha * 255);

    }
  }

  drawWave(highRGBA, high, [0, 0, 0], high * 0.05, 0.22, high * 0.014);
  drawWave(highRGBA, high, [255, 255, 255], high * 0.046, 1);

  const rgba = Buffer.alloc(size * size * 4);
  for (let y = 0; y < size; y += 1) {
    for (let x = 0; x < size; x += 1) {
      const acc = [0, 0, 0, 0];
      for (let sy = 0; sy < scale; sy += 1) {
        for (let sx = 0; sx < scale; sx += 1) {
          const idx = ((y * scale + sy) * high + (x * scale + sx)) * 4;
          acc[0] += highRGBA[idx];
          acc[1] += highRGBA[idx + 1];
          acc[2] += highRGBA[idx + 2];
          acc[3] += highRGBA[idx + 3];
        }
      }
      const out = (y * size + x) * 4;
      rgba[out] = Math.round(acc[0] / (scale * scale));
      rgba[out + 1] = Math.round(acc[1] / (scale * scale));
      rgba[out + 2] = Math.round(acc[2] / (scale * scale));
      rgba[out + 3] = Math.round(acc[3] / (scale * scale));
    }
  }
  return rgba;
}

for (const size of sizes) {
  const png = render(size);
  if ([16, 32, 128, 256, 512].includes(size)) writePNG(join(outputDir.pathname, `icon_${size}x${size}.png`), size, size, png);
  if ([32, 64, 256, 512, 1024].includes(size)) writePNG(join(outputDir.pathname, `icon_${size / 2}x${size / 2}@2x.png`), size, size, png);
}
