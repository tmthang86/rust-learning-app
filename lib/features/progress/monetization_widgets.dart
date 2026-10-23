import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
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
    final l10n = context.l10n;
    if (p.entitled) {
      return Card(
        child: ListTile(
          contentPadding: const EdgeInsets.all(16),
          leading: Icon(
            Icons.verified_outlined,
            color: theme.colorScheme.primary,
          ),
          title: Text(l10n.adsRemovedTitle),
          subtitle: Text(
            p.state == PurchaseFlowState.restored
                ? l10n.adsRestoredThanks
                : l10n.adsThanks,
          ),
        ),
      );
    }
    final product = p.product;
    final message = purchaseMessage(l10n, p);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.removeAdsTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(l10n.removeAdsBody),
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
                    ? l10n.removeAdsTitle
                    : l10n.removeAdsFor(product.price),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: p.busy || !p.storeAvailable ? null : p.restore,
              child: Text(l10n.restorePurchases),
            ),
          ],
        ),
      ),
    );
  }
}

/// The card's status line, in plain words (never a raw store error).
String? purchaseMessage(AppLocalizations l10n, PurchaseController p) {
  switch (p.state) {
    case PurchaseFlowState.idle:
    case PurchaseFlowState.purchased:
    case PurchaseFlowState.restored:
      if (!p.storeAvailable) {
        return l10n.purchaseStoreUnavailable;
      }
      if (p.product == null) {
        return l10n.purchaseItemMissing;
      }
      return null;
    case PurchaseFlowState.buying:
      return l10n.purchaseOpeningStore;
    case PurchaseFlowState.restoring:
      return l10n.purchaseRestoring;
    case PurchaseFlowState.pending:
      return l10n.purchasePending;
    case PurchaseFlowState.nothingToRestore:
      return l10n.purchaseNothingToRestore;
    case PurchaseFlowState.cancelled:
      return l10n.purchaseCancelled;
    case PurchaseFlowState.error:
      final error = p.error ?? StoreError.other;
      return p.errorWhileRestoring
          ? restoreErrorMessage(l10n, error)
          : storeErrorMessage(l10n, error);
  }
}

String storeErrorMessage(AppLocalizations l10n, StoreError error) =>
    switch (error) {
      StoreError.alreadyOwned => l10n.storeAlreadyOwned,
      StoreError.network => l10n.storeNetwork,
      StoreError.storeUnavailable => l10n.storeUnavailable,
      StoreError.itemUnavailable => l10n.storeItemUnavailable,
      StoreError.pendingTransaction => l10n.storePendingTransaction,
      StoreError.other => l10n.storeOther,
    };

String restoreErrorMessage(AppLocalizations l10n, StoreError error) =>
    switch (error) {
      StoreError.network => l10n.restoreNetwork,
      StoreError.storeUnavailable => l10n.storeUnavailable,
      _ => l10n.restoreOther,
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
      title: Text(context.l10n.privacyOptionsTitle),
      subtitle: Text(context.l10n.privacyOptionsSubtitle),
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
      title: Text(context.l10n.reportAdTitle),
      subtitle: Text(context.l10n.reportAdSubtitle),
      onTap: () => reportAdFrom(context, m.lastAdScreen ?? 'progress'),
    );
  }
}

