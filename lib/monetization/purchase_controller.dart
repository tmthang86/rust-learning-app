import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ad_config.dart';
import 'purchase_service.dart';

/// What the "Remove ads" card shows.
enum PurchaseFlowState {
  idle,

  /// Waiting for the store after a tap on Buy.
  buying,

  /// Waiting for the store after a tap on Restore.
  restoring,

  /// The store accepted the order but payment is not done yet (e.g. cash
  /// payment on Google Play, or Ask to Buy on the App Store).
  pending,

  /// Bought just now.
  purchased,

  /// Restored just now.
  restored,

  /// Restore found nothing for this store account.
  nothingToRestore,

  /// The person closed the store sheet.
  cancelled,

  error,
}

/// The one-time "Remove ads" purchase and the entitlement it unlocks.
///
/// The entitlement lives on the device (shared preferences). It is granted
/// when the store reports the product as purchased or restored and
/// [PurchaseVerifier] accepts it; see [PurchaseVerifier] for why there is
/// no server check yet. Every update that needs it is completed, whatever
/// its status, so Google Play doesn't refund it and the App Store doesn't
/// keep re-delivering it.
class PurchaseController extends ChangeNotifier {
  PurchaseController({
    required this.store,
    required this.prefs,
    this.verifier = const TrustDeviceVerifier(),
    this.restoreGrace = const Duration(seconds: 5),
  }) : _entitled = prefs.getBool(entitlementKey) ?? false;

  static const entitlementKey = 'removeAdsEntitled';

  final PurchaseService store;
  final SharedPreferences prefs;
  final PurchaseVerifier verifier;

  /// How long to wait for restored purchases after the store's restore
  /// call returns before saying there was nothing to restore. Google Play
  /// sends them right away; the App Store sends them one by one.
  final Duration restoreGrace;

  bool _entitled;
  bool _started = false;
  bool _disposed = false;
  bool _storeAvailable = false;
  StoreProduct? _product;
  PurchaseFlowState _state = PurchaseFlowState.idle;
  String? _errorMessage;
  StreamSubscription<List<StorePurchase>>? _sub;
  Completer<void>? _restoreSeen;

  /// True once "Remove ads" is owned on this device.
  bool get entitled => _entitled;

  /// Whether this platform sells anything; false hides the purchase UI.
  bool get supported => store.supported;
  bool get storeAvailable => _storeAvailable;
  StoreProduct? get product => _product;
  PurchaseFlowState get state => _state;
  String? get errorMessage => _errorMessage;
  bool get busy =>
      _state == PurchaseFlowState.buying ||
      _state == PurchaseFlowState.restoring;

  /// Listens to the store and loads the product. Call once at app start:
  /// purchases that finished while the app was closed arrive right away.
  Future<void> start() async {
    if (_started || !store.supported) return;
    _started = true;
    _sub = store.purchaseUpdates.listen(
      (updates) => unawaited(_handle(updates)),
      onError: (Object e) {
        debugPrint('Purchase stream error: $e');
        _set(PurchaseFlowState.error, message: '$e');
      },
    );
    try {
      _storeAvailable = await store.isAvailable();
      if (_storeAvailable) {
        _product = await store.queryProduct(removeAdsProductId);
      }
    } catch (e) {
      debugPrint('Store unavailable: $e');
      _storeAvailable = false;
    }
    _notify();
    if (_storeAvailable && store.restoresSilently && !_entitled) {
      try {
        await store.restore();
      } catch (e) {
        debugPrint('Silent restore failed: $e');
      }
    }
  }

  /// Opens the store's purchase sheet for "Remove ads".
  Future<void> buy() async {
    final p = _product;
    if (p == null || busy || _entitled) return;
    _set(PurchaseFlowState.buying);
    try {
      final sent = await store.buyNonConsumable(p);
      if (!sent) {
        _set(PurchaseFlowState.error, message: "The store didn't respond.");
      }
    } catch (e) {
      debugPrint('Buying failed: $e');
      _set(PurchaseFlowState.error, message: '$e');
    }
  }

  /// Restores an earlier purchase (the visible "Restore purchases" button
  /// that App Store guideline 3.1.1 requires).
  Future<void> restore() async {
    if (busy) return;
    _set(PurchaseFlowState.restoring);
    final seen = _restoreSeen = Completer<void>();
    try {
      await store.restore();
      await seen.future.timeout(restoreGrace, onTimeout: () {});
    } catch (e) {
      debugPrint('Restore failed: $e');
      _restoreSeen = null;
      _set(PurchaseFlowState.error, message: '$e');
      return;
    }
    _restoreSeen = null;
    if (_state == PurchaseFlowState.restoring) {
      _set(PurchaseFlowState.nothingToRestore);
    }
  }

  Future<void> _handle(List<StorePurchase> updates) async {
    for (final p in updates) {
      try {
        await _handleOne(p);
      } catch (e) {
        // Keep going so other updates are still completed.
        debugPrint('Handling purchase ${p.productId} failed: $e');
      }
    }
  }

  Future<void> _handleOne(StorePurchase p) async {
    if (p.status == StorePurchaseStatus.pending) {
      // Not paid yet: nothing to grant or complete. The store sends
      // another update when it settles.
      if (p.productId == removeAdsProductId) _set(PurchaseFlowState.pending);
      return;
    }
    try {
      if (p.productId == removeAdsProductId) {
        switch (p.status) {
          case StorePurchaseStatus.purchased:
          case StorePurchaseStatus.restored:
            if (await verifier.verify(p)) {
              await _grant();
              if (p.status == StorePurchaseStatus.purchased) {
                _set(PurchaseFlowState.purchased);
              } else if (_state == PurchaseFlowState.restoring) {
                // A silent restore at start says nothing.
                _set(PurchaseFlowState.restored);
              }
              final seen = _restoreSeen;
              if (seen != null && !seen.isCompleted) seen.complete();
            } else {
              _set(
                PurchaseFlowState.error,
                message: "The purchase couldn't be confirmed.",
              );
            }
          case StorePurchaseStatus.error:
            _set(PurchaseFlowState.error, message: p.errorMessage);
          case StorePurchaseStatus.canceled:
            _set(PurchaseFlowState.cancelled);
          case StorePurchaseStatus.pending:
            break; // handled above
        }
      }
    } finally {
      // Complete every update that needs it, also errors, cancellations
      // and products this app doesn't know.
      if (p.needsCompletion) {
        try {
          await store.complete(p);
        } catch (e) {
          debugPrint('completePurchase failed for ${p.productId}: $e');
        }
      }
    }
  }

  Future<void> _grant() async {
    if (_entitled) return;
    _entitled = true;
    _notify();
    await prefs.setBool(entitlementKey, true);
  }

  /// Clears a finished message (after it was shown).
  void acknowledge() {
    if (!busy && _state != PurchaseFlowState.pending) {
      _set(PurchaseFlowState.idle);
    }
  }

  void _set(PurchaseFlowState s, {String? message}) {
    _state = s;
    _errorMessage = message;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }
}
