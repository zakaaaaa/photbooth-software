// Ukur biaya pengolahan foto DSLR di package:image (Dart murni), tahap demi
// tahap — ini yang menentukan berapa lama jeda setelah jepret di camera_page.
//
// Jalankan:  dart run tools/bench_image.dart [path.jpg]
import 'dart:io';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  final path = args.isNotEmpty
      ? args[0]
      : '${Platform.environment['TEMP']}\\edsdk_test\\capture.jpg';
  final file = File(path);
  if (!file.existsSync()) {
    print('File tidak ada: $path');
    exit(1);
  }

  final bytes = file.readAsBytesSync();
  print('sumber: $path  (${(bytes.length / 1024 / 1024).toStringAsFixed(2)} MB)');

  final total = Stopwatch()..start();

  final swDecode = Stopwatch()..start();
  var image = img.decodeImage(bytes);
  swDecode.stop();
  if (image == null) {
    print('decode gagal');
    exit(1);
  }
  print('decode        ${swDecode.elapsedMilliseconds.toString().padLeft(6)}ms   '
      '${image.width}x${image.height}');

  final swResize = Stopwatch()..start();
  if (image.width > 3000 || image.height > 3000) {
    image = image.width > image.height
        ? img.copyResize(image, width: 3000)
        : img.copyResize(image, height: 3000);
  }
  swResize.stop();
  print('resize→3000   ${swResize.elapsedMilliseconds.toString().padLeft(6)}ms   '
      '${image.width}x${image.height}');

  final swFlip = Stopwatch()..start();
  final flipped = img.flipHorizontal(image);
  swFlip.stop();
  print('flip          ${swFlip.elapsedMilliseconds.toString().padLeft(6)}ms');

  final swEnc = Stopwatch()..start();
  final out = img.encodeJpg(flipped, quality: 98);
  swEnc.stop();
  print('encode q98    ${swEnc.elapsedMilliseconds.toString().padLeft(6)}ms   '
      '${(out.length / 1024 / 1024).toStringAsFixed(2)} MB');

  total.stop();
  print('─────────────────────────');
  print('TOTAL         ${total.elapsedMilliseconds.toString().padLeft(6)}ms');
}
