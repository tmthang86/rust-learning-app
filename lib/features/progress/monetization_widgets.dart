import 'package:flutter/material.dart';

import '../../monetization/monetization.dart';
import '../../monetization/purchase_controller.dart';

/// The one-time "Remove ads" purchase, with a visible "Restore purchases"
/// button (App Store guideline 3.1.1). Only on platforms with a store:
/// nothing is sold on the web, and nothing links to outside payment.
class RemoveAdsCard extends StatelessWidget {
  const RemoveAdsCard({super.key});

  @override
  Widget build(BuildContext context) {
    // Monetization passes on every change of its PurchaseController.
    final p = MonetizationScope.of(context).purchases;
    if (!p.supported) return const SizedBox.shrink();
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
    final message = _message(p);
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

  static String? _message(PurchaseController p) {
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
        final detail = p.errorMessage;
        return detail == null || detail.isEmpty
            ? "The purchase didn't go through. Please try again."
            : "The purchase didn't go through: $detail";
    }
  }
}

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
