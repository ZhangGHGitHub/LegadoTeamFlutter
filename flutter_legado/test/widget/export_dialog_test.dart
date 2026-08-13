import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/book.dart';
import 'package:flutter_legado/src/services/export_service.dart';
import 'package:flutter_legado/src/services/rust_api.dart';
import 'package:flutter_legado/src/widgets/export_dialog.dart';

/// 伪造的导出服务，用于测试
class FakeExportService extends ExportService {
  /// 是否模拟导出失败
  bool shouldFail = false;

  /// 导出是否被调用
  bool exportCalled = false;

  /// WebDAV 上传是否被调用
  bool webdavCalled = false;

  FakeExportService() : super(RustApi());

  @override
  List<String> get supportedFormats => ['txt', 'epub', 'html'];

  @override
  List<String> get supportedEncodings => ['UTF-8', 'GBK', 'Big5'];

  @override
  Future<Map<String, dynamic>> export({
    required String bookUrl,
    required String format,
    required bool includeToc,
    String? encoding,
    int? startChapter,
    int? endChapter,
    String? fileNameTemplate,
  }) async {
    exportCalled = true;
    if (shouldFail) {
      throw const ExportException('模拟导出失败');
    }
    return {
      'success': true,
      'file_name': '测试书籍.txt',
      'data_base64': 'dGVzdA==',
    };
  }

  @override
  Future<Map<String, dynamic>> getExportInfo({
    required String bookUrl,
    required String format,
  }) async {
    return {
      'success': true,
      'file_name': '测试书籍.txt',
      'chapter_count': 100,
    };
  }

  @override
  Future<bool> webdavUpload(
    String configJson,
    String path,
    String data,
  ) async {
    webdavCalled = true;
    return true;
  }
}

void main() {
  late FakeExportService fakeExportService;
  late RustApi fakeRustApi;

  setUp(() {
    fakeExportService = FakeExportService();
    fakeRustApi = RustApi();
  });

  /// 构建测试用 Widget
  Widget buildTestWidget({
    Book? book,
    ExportService? exportService,
    RustApi? rustApi,
    String? webDavConfig,
  }) {
    // 构造测试用书籍对象
    final testBook = book ??
        const Book(
          bookUrl: 'https://example.com/book1',
          name: '测试书籍',
        );
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: ExportDialog(
            book: testBook,
            exportService: exportService ?? fakeExportService,
            rustApi: rustApi ?? fakeRustApi,
            webDavConfig: webDavConfig,
          ),
        ),
      ),
    );
  }

  /// 设置测试窗口大小并泵入 Widget（避免对话框内容溢出）
  Future<void> pumpTestWidget(
    WidgetTester tester, {
    Book? book,
    ExportService? exportService,
    RustApi? rustApi,
    String? webDavConfig,
  }) async {
    // 设置较大的测试窗口，避免 RenderFlex 溢出
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(buildTestWidget(
      book: book,
      exportService: exportService,
      rustApi: rustApi,
      webDavConfig: webDavConfig,
    ));
  }

  group('导出对话框 UI 渲染', () {
    testWidgets('显示对话框标题', (tester) async {
      await pumpTestWidget(tester);

      expect(find.text('导出测试书籍'), findsOneWidget);
    });

    testWidgets('显示格式选择器', (tester) async {
      await pumpTestWidget(tester);

      expect(find.text('导出格式'), findsOneWidget);
      expect(find.text('TXT'), findsOneWidget);
      expect(find.text('EPUB'), findsOneWidget);
      expect(find.text('HTML'), findsOneWidget);
    });

    testWidgets('显示字符编码选择器', (tester) async {
      await pumpTestWidget(tester);

      expect(find.text('字符编码'), findsOneWidget);
      // 默认选中 UTF-8
      expect(find.text('UTF-8'), findsWidgets);
    });

    testWidgets('显示 TOC 复选框', (tester) async {
      await pumpTestWidget(tester);

      expect(find.text('包含目录'), findsOneWidget);
      expect(find.text('导出时包含书籍的目录结构'), findsOneWidget);
    });

    testWidgets('显示取消和确认按钮', (tester) async {
      await pumpTestWidget(tester);

      expect(find.text('取消'), findsOneWidget);
      expect(find.text('确认'), findsOneWidget);
    });

    testWidgets('无 WebDAV 配置时不显示 WebDAV 选项', (tester) async {
      await pumpTestWidget(tester, webDavConfig: null);

      expect(find.text('上传到 WebDAV'), findsNothing);
    });

    testWidgets('有 WebDAV 配置时显示 WebDAV 选项', (tester) async {
      await pumpTestWidget(
        tester,
        webDavConfig: '{"url":"https://dav.example.com"}',
      );

      expect(find.text('上传到 WebDAV'), findsOneWidget);
      expect(find.text('导出完成后自动上传到远程服务器'), findsOneWidget);
    });
  });

  group('导出对话框交互', () {
    testWidgets('默认选中 EPUB 格式', (tester) async {
      await pumpTestWidget(tester);

      // 因为 supportedFormats 包含 epub，initState 会默认选中 epub
      final epubChip = tester.widget<ChoiceChip>(
        find.ancestor(
          of: find.text('EPUB'),
          matching: find.byType(ChoiceChip),
        ),
      );
      expect(epubChip.selected, isTrue);
    });

    testWidgets('切换格式选择', (tester) async {
      await pumpTestWidget(tester);

      // 点击 TXT 格式
      await tester.tap(find.text('TXT'));
      await tester.pump();

      final txtChip = tester.widget<ChoiceChip>(
        find.ancestor(
          of: find.text('TXT'),
          matching: find.byType(ChoiceChip),
        ),
      );
      expect(txtChip.selected, isTrue);
    });

    testWidgets('切换 TOC 复选框', (tester) async {
      await pumpTestWidget(tester);

      // 初始状态为选中
      final checkbox = tester.widget<CheckboxListTile>(
        find.byType(CheckboxListTile).first,
      );
      expect(checkbox.value, isTrue);

      // 点击取消选中
      await tester.tap(find.text('包含目录'));
      await tester.pump();

      final updatedCheckbox = tester.widget<CheckboxListTile>(
        find.byType(CheckboxListTile).first,
      );
      expect(updatedCheckbox.value, isFalse);
    });

    testWidgets('点击取消关闭对话框', (tester) async {
      await pumpTestWidget(tester);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      // 对话框应该被关闭（Navigator.pop）
      expect(find.text('导出测试书籍'), findsNothing);
    });

    testWidgets('点击确认触发导出', (tester) async {
      await pumpTestWidget(tester);

      await tester.tap(find.text('确认'));
      await tester.pump();

      // 验证导出被调用
      expect(fakeExportService.exportCalled, isTrue);

      // 等待导出完成后的延迟（1.5s）
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('导出成功后对话框自动关闭', (tester) async {
      await pumpTestWidget(tester);

      // 确认对话框存在
      expect(find.text('导出测试书籍'), findsOneWidget);

      await tester.tap(find.text('确认'));
      await tester.pump();

      // 等待导出完成 + 1.5s 延迟
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      // 对话框应已关闭
      expect(find.text('导出测试书籍'), findsNothing);
    });
  });

  group('导出对话框字符集选择', () {
    testWidgets('字符集下拉框包含所有选项', (tester) async {
      await pumpTestWidget(tester);

      // 点击下拉框展开
      await tester.tap(find.text('UTF-8').first);
      await tester.pumpAndSettle();

      // 验证所有字符集选项
      expect(find.text('GBK'), findsWidgets);
      expect(find.text('Big5'), findsWidgets);
    });
  });
}
