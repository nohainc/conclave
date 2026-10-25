import 'package:conclave_app/src/features/common/dictation/speech_dictation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('concatenates separate desktop segments', () {
    expect(mergeSpeechResults(['hello world', ' how are you']),
        'hello world how are you');
  });

  test('keeps segments without spaces intact', () {
    expect(mergeSpeechResults(['你好', '世界']), '你好世界');
  });

  test('collapses cumulative Android results', () {
    expect(
        mergeSpeechResults(
            ['hello', 'hello how', 'Hello how are', 'hello how are you']),
        'hello how are you');
  });

  test('skips a repeated trailing segment', () {
    expect(mergeSpeechResults(['hello world', 'world']), 'hello world');
  });

  test('ignores empty segments', () {
    expect(mergeSpeechResults(['', ' hi ', '']), 'hi');
  });
}
