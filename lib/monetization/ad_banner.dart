import 'package:flutter/material.dart';

import 'ads_service.dart';
import 'monetization.dart';

/// A spot for a small banner on a reading or list screen. Takes no space
/// when ads are off (web, "Remove ads", under 13, no consent).
///
/// It has space around it and an "Advertisement" label, so it isn't
/// mistaken for content or tapped by accident
/// (https://support.google.com/admob/answer/6275345).
class AdBannerSlot extends StatelessWidget {
  const AdBannerSlot({super.key, required this.placement, this.minHeight = 0});

  final AdPlacement placement;

  /// Space it takes when there is no ad (ads off, or still loading), e.g.
  /// the list's usual gap.
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final m = MonetizationScope.of(context);
    if (!m.adsEnabled) return const SizedBox.shrink();
    return m.ads.banner(placement);
  }
}

/// How a loaded banner is framed. The ad services wrap a loaded ad in it.
class AdFrame extends StatelessWidget {
  const AdFrame({super.key, required this.height, required this.child});

  final double height;
  final Widget child;

  /// Space between the ad and anything tappable.
  static const gap = 24.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: gap),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Advertisement',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(height: height, child: child),
        ],
      ),
    );
  }
}
