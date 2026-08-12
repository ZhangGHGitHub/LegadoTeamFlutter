import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/services/app_update_service.dart';

void main() {
  group('AppUpdate version helpers', () {
    test('normalizeLegadoVersionName', () {
      expect(normalizeLegadoVersionName('3.23.080312'), '3.23080312');
      expect(normalizeLegadoVersionName('3.26080322'), '3.26080322');
      expect(normalizeLegadoVersionName('2.0.38'), '2.0.38');
    });

    test('compareReleaseVersions', () {
      expect(compareReleaseVersions('2.0.39', '2.0.38'), greaterThan(0));
      expect(compareReleaseVersions('2.0.38', '2.0.38'), 0);
      expect(compareReleaseVersions('2.0.37', '2.0.38'), lessThan(0));
    });

    test('CDN / backup URL', () {
      expect(
        resolveAppUpdateDownloadUrl('app.apk', 'https://gh/app.apk'),
        'https://cdn.mgz.la/app/app.apk',
      );
      expect(
        resolveAppUpdateDownloadUrl('app_._.apk', 'https://gh/app_._.apk'),
        'https://gh/app_._.apk',
      );
      expect(
        resolveAppUpdateBackupUrl(
          'https://cdn.mgz.la/app/a.apk',
          'https://gh/a.apk',
        ),
        'https://gh/a.apk',
      );
      expect(
        resolveAppUpdateBackupUrl('https://gh/a.apk', 'https://gh/a.apk'),
        isNull,
      );
    });

    test('inferAppVariant', () {
      expect(
        inferAppVariant('legado_app_release.apk', false),
        AppVariant.betaRelease,
      );
      expect(
        inferAppVariant('legado_app_releaseA.apk', false),
        AppVariant.betaReleaseA,
      );
      expect(inferAppVariant('legado.apk', false), AppVariant.official);
    });
  });
}
