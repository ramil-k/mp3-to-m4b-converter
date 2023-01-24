#!/usr/bin/env node

// prerequired ffmpeg with libfdk_aac.
// brew install ffmpeg --with-chromaprint --with-fdk-aac --with-libass --with-librsvg --with-libsoxr --with-libssh --with-tesseract --with-libvidstab --with-opencore-amr --with-openh264 --with-openjpeg --with-openssl --with-rtmpdump --with-rubberband --with-sdl2 --with-snappy --with-tools --with-webp --with-x265 --with-xz --with-zeromq --with-zimg

const { exec, spawn } = require('child_process');
const { promisify } = require('util');
const { readdir, writeFile, unlink, createReadStream, createWriteStream, rename, readFile } = require('fs');
const { basename, resolve } = require('path');
const { PassThrough } = require('stream');

const ls = promisify(readdir), 
write = promisify(writeFile),
run = promisify(exec),
rm = promisify(unlink),
mv = promisify(rename),
cat = promisify(readFile);

(async () => {
  const directory = resolve('.'),
  files = await mp3s(directory);
  
  const lengths = await extractLength(files);
  
  const meta = await extractMeta(lengths);

  const m4a = await toM4a(`${directory}.m4a`, files);
  
  await writeMetaAndRename(`${directory}.m4a`, meta, `${directory}.meta.m4a`);
  
  mv(`${directory}.meta.m4a`, `${directory}.m4b`);
  
  rm(`${directory}.m4a`);  
})().catch(console.error);

async function extractMeta(lengths) {
  if (!lengths.length) {
    return;
  };
  
  const allMeta = await Promise.all(lengths.map(async ({ file, length }) => {
    await run(`ffmpeg -i  "${file}" -f ffmetadata  "${file}.meta"`);
    
    const meta = await cat(`${file}.meta`, { encoding: 'UTF8' });
    
    await rm(`${file}.meta`);
    
    return {file, length, meta};
  }));
  
  const stringifiedMetadata = stringifyMetadata(allMeta);
  
  return stringifiedMetadata;
}

async function mp3s(directory) {
  const files = await ls(directory);
  return files.filter(file => /^.*\.mp3$/.test(file));
}

async function extractLength(files) {
  return Promise.all(files.map(async file => {
    const info = await run(`afinfo -r "${file}"`);
    const sec = info.stdout.split('\n').filter(str => str.startsWith('estimated duration: '))[0].replace('estimated duration: ', '').replace(' sec', '');
    return { file, length: Math.round(parseFloat(sec) * 1000) };
  }));
}

function stringifyMetadata(allMeta) {
  const initial = {
    meta: allMeta[0].meta, 
    duration: 0,
  };
  
  const final = allMeta.reduce(({ meta: prevMeta, duration }, { file, meta: fileMeta, length }) => {
    const title = file.substr(0, file.length - 4);
    
    const meta = `${prevMeta}
    
    [CHAPTER]
    TIMEBASE=1/1000
    START=${duration}
    END=${duration + length}
    title=${title}`;
    
    return {
      meta, 
      duration: duration + length
    };
  }, initial);
  
  return final.meta.split('\n').map(str => str.trim()).join('\n');
}

async function writeMetaAndRename(m4a, meta, m4b) {
  await write(`${m4a}.meta`, meta);
  
  await run(`ffmpeg -i "${m4a}" -i "${m4a}.meta" -map_metadata 1 -codec copy "${m4b}"`);
  
  await rm(`${m4a}.meta`);
}
async function toM4a(m4a, files) {
  await (new Promise(async resolve => {
    const concating = spawn(`ffmpeg`, [
      `-i`, `pipe:0`,
      `-y`, 
      `-c:a`, `libfdk_aac`, 
      m4a,
    ]);
    
    // concating.stderr.pipe(createWriteStream(`${m4a}_err`), { end: true });
    // concating.stdout.pipe(createWriteStream(`${m4a}_log`), { end: true });
    
    concating.stderr.pipe(process.stderr, {end: false});
    concating.stdout.pipe(process.stdout, {end: false});
    
    for(let file of files) {
      await (new Promise(resolve => {
        console.log(file);
        const stream = createReadStream(file);
        stream.pipe(concating.stdin, { end: false });
        stream.on('close', () => {
          resolve(file);
        });
      }));
    }
    
    concating.on('close', (code) => {
      console.log(`child process exited with code ${code}`);
      resolve(m4a);
    });
    
    concating.stdin.end();
  }));
  
  return m4a;
}