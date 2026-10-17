import 'package:flutter_test/flutter_test.dart';
import 'package:novel/feedback_page.dart';
import 'package:novel/storage_page.dart';

void main() {
  test('each robot gets the body it takes', () {
    expect(
      feedbackBody('https://open.feishu.cn/open-apis/bot/v2/hook/x', 'hi'),
      {
        'msg_type': 'text',
        'content': {'text': 'hi'},
      },
    );
    expect(
      feedbackBody('https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=x', 'hi'),
      {
        'msgtype': 'text',
        'text': {'content': 'hi'},
      },
    );
  });

  test('the message says where it came from, and who to answer', () {
    expect(
      feedbackText(body: ' 好用 \n', contact: '', version: '1.2.0', system: 'ios'),
      '挚阅反馈 · 1.2.0 · ios\n\n好用',
    );
    expect(
      feedbackText(body: '好用', contact: ' qq 123 ', version: '1.2.0', system: 'windows'),
      '挚阅反馈 · 1.2.0 · windows\n联系：qq 123\n\n好用',
    );
  });

  test('sizes read as people say them', () {
    expect(formatStorageBytes(400 * 1024), '0.4 MB');
    expect(formatStorageBytes(35 << 20), '35 MB');
    expect(formatStorageBytes(1229 << 20), '1.2 GB');
  });
}
