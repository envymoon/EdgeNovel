import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'model_download.dart';

/// One file an engine or its model is made of, where it is hosted and what it
/// must hash to. Models are on Hugging Face (and its mainland mirror), engines
/// are GitHub releases (and a proxy); see experiments/.
class HostedFile {
  const HostedFile(this.name, this.bytes, this.sha256, this.urls);

  final String name;
  final int bytes;
  final String sha256;
  final List<String> urls;
}

const _hf = 'ianhaimo/edgenovel-anime-cover/resolve/main';
const _release =
    'github.com/envymoon/EdgeNovel/releases/download/image-engine-1';

/// The cover model and its decoder, downloaded one after the other.
const imageModelFiles = [
  HostedFile(
    'anime-cover-q5_0.gguf',
    728811248,
    'cb8c8ce181c2665c022c2a4211e9d593e705026ac07c3d474377921f19c00d38',
    [
      'https://huggingface.co/$_hf/anime-cover-q5_0.gguf',
      'https://hf-mirror.com/$_hf/anime-cover-q5_0.gguf',
    ],
  ),
  HostedFile(
    'taesd.safetensors',
    9793292,
    'db169d69145ec4ff064e49d99c95fa05d3eb04ee453de35824a6d0f325513549',
    [
      'https://huggingface.co/$_hf/taesd.safetensors',
      'https://hf-mirror.com/$_hf/taesd.safetensors',
    ],
  ),
];

/// sd-cli with its licences and the patch it was built with.
const imageEngineZip = HostedFile(
  'sd-cli-windows-x64-vulkan.zip',
  28852031,
  '808eed80fa7ee8d5879107baf518a14b688789869924a49930147f9b9ff9dbae',
  [
    'https://$_release/sd-cli-windows-x64-vulkan.zip',
    'https://ghfast.top/https://$_release/sd-cli-windows-x64-vulkan.zip',
  ],
);

/// The folder in the image dir the engine is unpacked into. Deleting the
/// engine removes it whole.
const imageEngineFolder = 'sd-cli';

const _qwen = 'ianhaimo/edgenovel-qwen-tts/resolve/main';
const _ttsRelease =
    'github.com/envymoon/EdgeNovel/releases/download/tts-engine-1';

/// The read-aloud voice: Qwen3-TTS 0.6B CustomVoice, its talker and its codec.
/// The codec is the decoder alone; the encoder is only for cloning a voice.
const ttsModelFiles = [
  HostedFile(
    'qwen-talker-0.6b-customvoice-Q8_0.gguf',
    968588544,
    '4eb38675c736ed6ac72012846ac8d6ef80e5af8bc05726870f0b3a6569588519',
    [
      'https://huggingface.co/$_qwen/qwen-talker-0.6b-customvoice-Q8_0.gguf',
      'https://hf-mirror.com/$_qwen/qwen-talker-0.6b-customvoice-Q8_0.gguf',
    ],
  ),
  HostedFile(
    'qwen-tokenizer-12hz-dec-Q8_0.gguf',
    201291104,
    '72b05f6436093f4698fc7b2e69d726a26008c78d2cf7007413e39e9f4cd6b556',
    [
      'https://huggingface.co/$_qwen/qwen-tokenizer-12hz-dec-Q8_0.gguf',
      'https://hf-mirror.com/$_qwen/qwen-tokenizer-12hz-dec-Q8_0.gguf',
    ],
  ),
];

/// qwentts.cpp's tts-server with its licences and the patch it was built with;
/// see experiments/qwen-tts.
const ttsEngineZip = HostedFile(
  'qwen-tts-windows-x64-vulkan.zip',
  15035191,
  '0136150d59508435d4e52526a898270e488c53ebc2edd6140d3be073561acc75',
  [
    'https://$_ttsRelease/qwen-tts-windows-x64-vulkan.zip',
    'https://ghfast.top/https://$_ttsRelease/qwen-tts-windows-x64-vulkan.zip',
  ],
);

const ttsEngineFolder = 'qwen-tts';

String _join(String dir, String name) => '$dir${Platform.pathSeparator}$name';

/// Where a file downloads to before it is checked. Not a .gguf, so the app
/// never takes a half-downloaded model for the real one.
File _download(String dir, HostedFile f) =>
    File(_join(dir, '${f.name}.download'));

Future<void> _check(File file, HostedFile f) async {
  final digest = await sha256.bind(file.openRead()).first;
  if (digest.toString() != f.sha256) {
    await file.delete();
    throw '${f.name} 校验失败，请重新下载';
  }
}

/// Fetches [f] into [dir] under its own name, resuming what an earlier try
/// left, and checks it before it takes that name.
Future<File> _fetch(
  String dir,
  HostedFile f,
  ResumableFileDownload transfer,
  void Function(int received) onProgress,
) async {
  final done = File(_join(dir, f.name));
  if (await done.exists() && await done.length() == f.bytes) return done;
  final part = _download(dir, f);
  await transfer.downloadFirst(
    f.urls,
    part,
    onProgress: (received, _) => onProgress(received),
  );
  await _check(part, f);
  if (await done.exists()) await done.delete();
  return part.rename(done.path);
}

/// Bytes already fetched of [files], from an earlier, unfinished try.
Future<int> pendingDownloadBytes(String dir, List<HostedFile> files) async {
  var n = 0;
  for (final f in files) {
    final done = File(_join(dir, f.name));
    if (await done.exists()) continue;
    n += await ResumableFileDownload.pendingBytes(_download(dir, f));
  }
  return n;
}

/// Downloads [files] into [dir], one after the other. [onProgress] gets the
/// share of all of them together.
Future<void> downloadHostedFiles(
  String dir,
  List<HostedFile> files,
  ResumableFileDownload transfer,
  void Function(double) onProgress,
) async {
  final total = files.fold<int>(0, (n, f) => n + f.bytes);
  var before = 0;
  for (final f in files) {
    await _fetch(dir, f, transfer, (got) => onProgress((before + got) / total));
    before += f.bytes;
  }
}

/// Throws away a download of [files] that was stopped halfway.
Future<void> discardHostedDownload(String dir, List<HostedFile> files) async {
  for (final f in files) {
    await ResumableFileDownload.discard(_download(dir, f));
  }
}

/// Downloads an engine [zip] and unpacks it into [dir]/[folder].
Future<void> downloadEngineZip(
  String dir,
  HostedFile zip,
  String folder,
  void Function(double) onProgress,
) async {
  final transfer = ResumableFileDownload();
  final file = await _fetch(
    dir,
    zip,
    transfer,
    (got) => onProgress(got / zip.bytes),
  );
  try {
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    final into = Directory(_join(dir, folder));
    for (final f in archive) {
      if (!f.isFile) continue;
      final name = f.name.replaceAll('\\', '/');
      if (name.startsWith('/') || name.split('/').contains('..')) {
        throw '引擎压缩包包含非法路径';
      }
      final out = File(_join(into.path, name));
      await out.create(recursive: true);
      await out.writeAsBytes(f.content as List<int>);
    }
  } finally {
    await file.delete();
  }
}
