import 'package:flutter/material.dart';

import '../../monetization/ad_banner.dart';
import '../../monetization/monetization.dart';
import '../../monetization/purchase_controller.dart';
import '../../monetization/purchase_service.dart';

/// The one-time "Remove ads" purchase, with a visible "Restore purchases"
/// button (App Store guideline 3.1.1).
///
/// Shown only to people who would see ads, or as "Ads removed" to people
/// who own it ([Monetization.showRemoveAdsCard]): never on the web, never
/// to someone under 13, and nothing links to outside payment.
class RemoveAdsCard extends StatefulWidget {
  const RemoveAdsCard({super.key});

  @override
  State<RemoveAdsCard> createState() => _RemoveAdsCardState();
}

class _RemoveAdsCardState extends State<RemoveAdsCard> {
  @override
  void initState() {
    super.initState();
    // Try the store again if it was unreachable at start.
    MonetizationScope.read(context).purchases.refresh();
  }

  @override
  Widget build(BuildContext context) {
    // Monetization passes on every change of its PurchaseController.
    final m = MonetizationScope.of(context);
    if (!m.showRemoveAdsCard) return const SizedBox.shrink();
    final p = m.purchases;
    final theme = Theme.of(context);
    if (p.entitled) {
      return Card(
        child: ListTile(
          contentPadding: const EdgeInsets.all(16),
          leading: Icon(
            Icons.verified_outlined,
            color: theme.colorScheme.primary,
          ),
          title: const Text('Ads removed'),
          subtitle: Text(
            p.state == PurchaseFlowState.restored
                ? 'Your purchase was restored. Thank you!'
                : 'Thank you for supporting the app.',
          ),
        ),
      );
    }
    final product = p.product;
    final message = purchaseMessage(p);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Remove ads', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text(
              'A one-time purchase. Lessons and running code stay free '
              'either way.',
            ),
            if (message != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  message,
                  style: TextStyle(
                    color: p.state == PurchaseFlowState.error
                        ? theme.colorScheme.error
                        : null,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed:
                  product == null ||
                      p.busy ||
                      p.state == PurchaseFlowState.pending
                  ? null
                  : p.buy,
              child: Text(
                product == null
                    ? 'Remove ads'
                    : 'Remove ads for ${product.price}',
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: p.busy || !p.storeAvailable ? null : p.restore,
              child: const Text('Restore purchases'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The card's status line, in plain words (never a raw store error).
String? purchaseMessage(PurchaseController p) {
  switch (p.state) {
    case PurchaseFlowState.idle:
    case PurchaseFlowState.purchased:
    case PurchaseFlowState.restored:
      if (!p.storeAvailable) {
        return "The store isn't available right now.";
      }
      if (p.product == null) {
        return "This purchase isn't available right now.";
      }
      return null;
    case PurchaseFlowState.buying:
      return 'Opening the store…';
    case PurchaseFlowState.restoring:
      return 'Checking for earlier purchases…';
    case PurchaseFlowState.pending:
      return 'Your purchase is pending. Ads will be removed once the '
          'store confirms it.';
    case PurchaseFlowState.nothingToRestore:
      return 'No earlier purchase was found for this store account.';
    case PurchaseFlowState.cancelled:
      return 'Purchase cancelled.';
    case PurchaseFlowState.error:
      final error = p.error ?? StoreError.other;
      return p.errorWhileRestoring
          ? restoreErrorMessage(error)
          : storeErrorMessage(error);
  }
}

String storeErrorMessage(StoreError error) => switch (error) {
  StoreError.alreadyOwned =>
    'You already own this. Tap "Restore purchases" to get it back.',
  StoreError.network =>
    "Couldn't reach the store. Check your connection and try again.",
  StoreError.storeUnavailable =>
    "Purchases aren't available on this device or account.",
  StoreError.itemUnavailable =>
    "This purchase isn't available right now. Please try again later.",
  StoreError.pendingTransaction =>
    'An earlier purchase is still being processed. Please try again in a '
        'moment.',
  StoreError.other => "The purchase didn't go through. Please try again.",
};

String restoreErrorMessage(StoreError error) => switch (error) {
  StoreError.network =>
    "Couldn't reach the store to check for earlier purchases. Check your "
        'connection and try again.',
  StoreError.storeUnavailable =>
    "Purchases aren't available on this device or account.",
  _ => "Couldn't check for earlier purchases. Please try again.",
};

/// Lets the learner change their ad privacy choices. Shown only when UMP
/// says the app must offer it.
class PrivacyOptionsTile extends StatelessWidget {
  const PrivacyOptionsTile({super.key});

  @override
  Widget build(BuildContext context) {
    final m = MonetizationScope.of(context);
    if (!m.privacyOptionsRequired) return const SizedBox.shrink();
    return ListTile(
      leading: const Icon(Icons.privacy_tip_outlined),
      title: const Text('Privacy options'),
      subtitle: const Text('Change your choices about ads and data.'),
      onTap: m.showPrivacyOptions,
    );
  }
}

/// "Report an ad" (App Store guideline 2.5.18), shown only while ads are
/// on. The report names the screen of the last banner seen, since nothing
/// tappable sits next to a banner.
class ReportAdTile extends StatelessWidget {
  const ReportAdTile({super.key});

  @override
  Widget build(BuildContext context) {
    final m = MonetizationScope.of(context);
    if (!m.adsEnabled) return const SizedBox.shrink();
    return ListTile(
      leading: const Icon(Icons.flag_outlined),
      title: const Text('Report an ad'),
      subtitle: const Text('Tell us about an ad that seemed inappropriate.'),
      onTap: () => reportAdFrom(context, m.lastAdScreen ?? 'progress'),
    );
  }
}

