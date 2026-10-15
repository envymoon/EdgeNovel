import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'model_download.dart';

/// One file the cover generator needs, where it is hosted and what it must hash
/// to. The model is on Hugging Face (and its mainland mirror), the engine is a
/// GitHub release (and its proxy); see experiments/anime-cover-model.
class ImageFile {
  const ImageFile(this.name, this.bytes, this.sha256, this.urls);

  final String name;
  final int bytes;
  final String sha256;
  final List<String> urls;
}

const _hf = 'ianhaimo/edgenovel-anime-cover/resolve/main';
const _release =
    'github.com/envymoon/EdgeNovel/releases/download/image-engine-1';

/// The model and its decoder, downloaded one after the other.
const imageModelFiles = [
  ImageFile(
    'anime-cover-q5_0.gguf',
    728811248,
    'cb8c8ce181c2665c022c2a4211e9d593e705026ac07c3d474377921f19c00d38',
    [
      'https://huggingface.co/$_hf/anime-cover-q5_0.gguf',
      'https://hf-mirror.com/$_hf/anime-cover-q5_0.gguf',
    ],
  ),
  ImageFile(
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
const imageEngineZip = ImageFile(
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

String _join(String dir, String name) => '$dir${Platform.pathSeparator}$name';

/// Where a file downloads to before it is checked. Not a .gguf, so the app
/// never takes a half-downloaded model for the real one.
File _download(String dir, ImageFile f) =>
    File(_join(dir, '${f.name}.download'));

Future<void> _check(File file, ImageFile f) async {
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
  ImageFile f,
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

/// Bytes already fetched of the model, from an earlier, unfinished try.
Future<int> pendingImageModelBytes(String dir) async {
  var n = 0;
  for (final f in imageModelFiles) {
    final done = File(_join(dir, f.name));
    if (await done.exists()) continue;
    n += await ResumableFileDownload.pendingBytes(_download(dir, f));
  }
  return n;
}

/// Downloads the model and its decoder into [dir]. [onProgress] gets the share
/// of both together.
Future<void> downloadImageModel(
  String dir,
  ResumableFileDownload transfer,
  void Function(double) onProgress,
) async {
  final total = imageModelFiles.fold<int>(0, (n, f) => n + f.bytes);
  var before = 0;
  for (final f in imageModelFiles) {
    await _fetch(dir, f, transfer, (got) => onProgress((before + got) / total));
    before += f.bytes;
  }
}

/// Throws away a model download that was stopped halfway.
Future<void> discardImageModelDownload(String dir) async {
  for (final f in imageModelFiles) {
    await ResumableFileDownload.discard(_download(dir, f));
  }
}

/// Downloads the engine and unpacks it into [dir]/[imageEngineFolder].
Future<void> downloadImageEngine(
  String dir,
  void Function(double) onProgress,
) async {
  final transfer = ResumableFileDownload();
  final zip = await _fetch(
    dir,
    imageEngineZip,
    transfer,
    (got) => onProgress(got / imageEngineZip.bytes),
  );
  try {
    final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
    final into = Directory(_join(dir, imageEngineFolder));
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
    await zip.delete();
  }
}
