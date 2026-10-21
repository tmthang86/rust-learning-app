import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'ad_report.dart';
import 'ads_service.dart';
import 'monetization.dart';

/// Opens the ad report; if nothing can open it, says where to write.
Future<void> reportAdFrom(BuildContext context, String screen) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  final opened = await MonetizationScope.read(context).reportAd(
    screen,
    subject: l10n.adReportSubject,
    intro: l10n.adReportIntro,
  );
  if (!opened) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          adReportUrl.isNotEmpty
              ? l10n.adReportViaUrl(adReportUrl)
              : l10n.adReportViaEmail(adReportEmail),
        ),
      ),
    );
  }
}

/// A spot for a small banner on a reading or list screen. Takes no space
/// when ads are off (web, "Remove ads", under 13, no consent).
///
/// While ads are on it reserves the banner's full height before the ad
/// loads, and keeps it if loading fails, so content never jumps under a
/// tap. It has space around it and an "Advertisement" label, so it isn't
/// mistaken for content or tapped by accident
/// (https://support.google.com/admob/answer/6275345). Nothing tappable sits
/// next to it; ads are reported from Progress → "Report an ad" (App Store
/// guideline 2.5.18), which names the screen of the last banner seen.
///
/// It stays alive while scrolled out of view, so scrolling doesn't throw
/// away and re-request the ad.
class AdBannerSlot extends StatefulWidget {
  const AdBannerSlot({super.key, required this.placement});

  final AdPlacement placement;

  /// Height reserved for the ad itself. The real banner asks AdMob for an
  /// inline adaptive ad no taller than this.
  static const adHeight = 60.0;

  /// Space between the ad and anything tappable.
  static const gap = 24.0;

  @override
  State<AdBannerSlot> createState() => _AdBannerSlotState();
}

class _AdBannerSlotState extends State<AdBannerSlot>
    with AutomaticKeepAliveClientMixin {
  bool _adsEnabled = false;

  @override
  bool get wantKeepAlive => _adsEnabled;

  @override
  Widget build(BuildContext context) {
    final m = MonetizationScope.of(context);
    if (m.adsEnabled != _adsEnabled) {
      _adsEnabled = m.adsEnabled;
      updateKeepAlive();
    }
    super.build(context);
    if (!_adsEnabled) return const SizedBox.shrink();
    m.lastAdScreen = widget.placement.name;
    final theme = Theme.of(context);
    final label = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AdBannerSlot.gap),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(context.l10n.advertisement, style: label),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: AdBannerSlot.adHeight,
            child: Center(child: m.ads.banner(widget.placement)),
          ),
        ],
      ),
    );
  }
}
