/// "Report an ad", which App Store guideline 2.5.18 requires of apps with
/// ads: people must be able to report inappropriate or age-inappropriate
/// ads.
///
/// Reports go by email to [adReportEmail], or to a web form at
/// [adReportUrl] when that is set. Both come from `--dart-define`; the
/// default address is a placeholder to replace before release (see
/// docs/ads-and-purchases.md).
library;

const adReportEmail = String.fromEnvironment(
  'AD_REPORT_EMAIL',
  defaultValue: 'ads-report@example.com',
);
const adReportUrl = String.fromEnvironment('AD_REPORT_URL');

/// The link that opens a report for an ad seen on [screen] at [time].
///
/// A mailto link with the details filled in, or [url] with them as query
/// parameters. Spaces are written as %20, not +, since some mail apps
/// show a + literally.
Uri adReportUri({
  required DateTime time,
  required String screen,
  required List<String> adUnits,
  String email = adReportEmail,
  String url = adReportUrl,
}) {
  final when = time.toUtc().toIso8601String();
  final units = adUnits.join(', ');
  if (url.isNotEmpty) {
    final base = Uri.parse(url);
    return base.replace(
      queryParameters: {
        ...base.queryParameters,
        'time': when,
        'screen': screen,
        'adUnits': units,
      },
    );
  }
  final body =
      'Please describe the ad (what it showed, why it seems '
      'inappropriate):\n\n\n'
      '---\nTime: $when\nScreen: $screen\nAd units: $units\n';
  return Uri.parse(
    'mailto:$email'
    '?subject=${Uri.encodeComponent('Report an ad')}'
    '&body=${Uri.encodeComponent(body)}',
  );
}
