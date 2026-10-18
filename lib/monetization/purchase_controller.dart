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
/// no server check yet.
///
/// Every accepted update that needs it is completed, whatever its status,
/// so Google Play doesn't refund it and the App Store doesn't keep
/// re-delivering it. Where restoring is silent (Google Play, StoreKit 2)
/// the app restores at every start and resume, so an acknowledgement that
/// failed or was cut off is retried well within Play's 3-day limit.
class PurchaseController extends ChangeNotifier {
  PurchaseController({
    required this.store,
    required this.prefs,
    this.verifier = const TrustDeviceVerifier(),
    this.restoreGrace = const Duration(seconds: 5),
    this.quietRestoreWait = const Duration(seconds: 3),
  }) : _entitled = prefs.getBool(entitlementKey) ?? false;

  static const entitlementKey = 'removeAdsEntitled';

  final PurchaseService store;
  final SharedPreferences prefs;
  final PurchaseVerifier verifier;

  /// How long a tap on Restore waits for the store's answer before saying
  /// there was nothing to restore.
  final Duration restoreGrace;

  /// How long the silent restore at start may hold up the consent form
  /// and ads, so a paying user doesn't see them.
  final Duration quietRestoreWait;

  bool _entitled;
  bool _started = false;
  bool _disposed = false;
  bool _storeAvailable = false;
  StoreProduct? _product;
  PurchaseFlowState _state = PurchaseFlowState.idle;
  StoreError? _error;
  StreamSubscription<List<StorePurchase>>? _sub;
  Future<void>? _refreshing;
  bool _quietRestoring = false;

  /// Updates are handled one batch at a time, in order.
  Future<void> _queue = Future.value();

  /// Number of update batches received so far; each batch is numbered by
  /// its arrival.
  int _batchesReceived = 0;

  /// Restores waiting for a batch: each completes once a batch numbered at
  /// or above its value has been handled, so a batch that arrived before
  /// its own restore call (an earlier purchase or error) doesn't count.
  final Map<Completer<void>, int> _batchWaiters = {};

  /// True once "Remove ads" is owned on this device.
  bool get entitled => _entitled;

  /// Whether this platform sells anything; false hides the purchase UI.
  bool get supported => store.supported;
  bool get storeAvailable => _storeAvailable;
  StoreProduct? get product => _product;
  PurchaseFlowState get state => _state;

  /// Why the last action failed, when [state] is [PurchaseFlowState.error].
  StoreError? get error => _error;

  /// True when the last error came from a restore rather than a purchase.
  bool get errorWhileRestoring => _errorWhileRestoring;
  bool _errorWhileRestoring = false;
  bool get busy =>
      _state == PurchaseFlowState.buying ||
      _state == PurchaseFlowState.restoring;

  /// Listens to the store, loads the product, and (where silent) restores.
  /// Call once at app start: purchases that finished while the app was
  /// closed arrive right away. Completes once the silent restore has been
  /// handled, or after [quietRestoreWait].
  Future<void> start() async {
    if (_started || !store.supported) return;
    _started = true;
    _sub = store.purchaseUpdates.listen(
      (updates) {
        final number = _batchesReceived++;
        _queue = _queue.then((_) => _handle(updates)).whenComplete(() {
          final done = [
            for (final e in _batchWaiters.entries)
              if (number >= e.value) e.key,
          ];
          for (final w in done) {
            _batchWaiters.remove(w);
            if (!w.isCompleted) w.complete();
          }
        });
      },
      onError: (Object e) {
        debugPrint('Purchase stream error: $e');
        if (busy) _set(PurchaseFlowState.error, error: storeErrorFrom(e));
      },
    );
    await refresh();
    await _quietRestore();
  }

  /// Call when the app comes back to the foreground.
  Future<void> onResume() async {
    if (!_started) return;
    await refresh();
    if (!busy) await _quietRestore();
  }

  /// Tries the store again if it was unreachable or the product unknown
  /// (e.g. when the Progress screen opens or the app resumes).
  Future<void> refresh() {
    if (!store.supported || (_storeAvailable && _product != null)) {
      return Future.value();
    }
    return _refreshing ??= _load().whenComplete(() => _refreshing = null);
  }

  Future<void> _load() async {
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
  }

  /// Re-reads owned purchases without asking anything, which also retries
  /// completing (acknowledging) any that weren't.
  Future<void> _quietRestore() async {
    if (!_storeAvailable || !store.restoresSilently || _quietRestoring) return;
    _quietRestoring = true;
    try {
      await _restoreAndWait(quietRestoreWait);
    } catch (e) {
      debugPrint('Silent restore failed: $e');
    } finally {
      _quietRestoring = false;
    }
  }

  /// Asks the store to restore, then waits until a batch that arrived after
  /// this call has been handled (or [timeout]).
  Future<void> _restoreAndWait(Duration timeout) async {
    final handled = Completer<void>();
    _batchWaiters[handled] = _batchesReceived;
    try {
      await store.restore();
    } catch (_) {
      _batchWaiters.remove(handled);
      rethrow;
    }
    await handled.future.timeout(timeout, onTimeout: () {});
    _batchWaiters.remove(handled);
  }

  /// Opens the store's purchase sheet for "Remove ads".
  Future<void> buy() async {
    final p = _product;
    if (p == null || busy || _entitled) return;
    _set(PurchaseFlowState.buying);
    try {
      final sent = await store.buyNonConsumable(p);
      if (!sent && _state == PurchaseFlowState.buying) {
        _set(PurchaseFlowState.error, error: StoreError.other);
      }
    } catch (e) {
      debugPrint('Buying failed: $e');
      _set(PurchaseFlowState.error, error: storeErrorFrom(e));
    }
  }

  /// Restores an earlier purchase (the visible "Restore purchases" button
  /// that App Store guideline 3.1.1 requires). If nothing turns up, asks
  /// the store to sync with its servers first (App Store) and tries once
  /// more.
  Future<void> restore() async {
    if (busy) return;
    _set(PurchaseFlowState.restoring);
    try {
      await _restoreAndWait(restoreGrace);
      if (!_entitled && _state == PurchaseFlowState.restoring) {
        await store.syncWithStore();
        await _restoreAndWait(restoreGrace);
      }
    } catch (e) {
      debugPrint('Restore failed: $e');
      if (!_entitled) _set(PurchaseFlowState.error, error: storeErrorFrom(e));
      return;
    }
    if (_state == PurchaseFlowState.restoring) {
      _set(
        _entitled ? PurchaseFlowState.restored : PurchaseFlowState.nothingToRestore,
      );
    }
  }

  Future<void> _handle(List<StorePurchase> updates) async {
    for (final p in updates) {
      try {
        await _handleOne(p);
      } catch (e) {
        // Keep going so other updates are still handled.
        debugPrint('Handling purchase ${p.productId} failed: $e');
      }
    }
  }

  Future<void> _handleOne(StorePurchase p) async {
    if (p.productId.isEmpty) {
      // in_app_purchase_android 0.5.4 reports a cancelled purchase, and a
      // billing error that came with no purchase (item already owned,
      // service unavailable, ...), as an update with an empty product id
      // (_getPurchaseDetailsFromResult). It belongs to the buy in progress.
      _onBuyFailed(p);
      return;
    }
    if (p.status == StorePurchaseStatus.pending) {
      // Not paid yet: nothing to grant or complete. The store sends
      // another update when it settles.
      if (p.productId == removeAdsProductId) _set(PurchaseFlowState.pending);
      return;
    }
    if (p.productId == removeAdsProductId) {
      switch (p.status) {
        case StorePurchaseStatus.purchased:
        case StorePurchaseStatus.restored:
          if (!await verifier.verify(p)) {
            // Not completed on purpose: a purchase that fails the check is
            // left for the store to refund (Play does after 3 days). With a
            // server check (see PurchaseVerifier) a temporary failure
            // should be retried rather than treated as a rejection.
            debugPrint('Purchase ${p.purchaseId} failed verification');
            _set(PurchaseFlowState.error, error: StoreError.other);
            return;
          }
          await _grant();
          if (p.status == StorePurchaseStatus.purchased) {
            _set(PurchaseFlowState.purchased);
          } else if (_state == PurchaseFlowState.buying) {
            // Already owned, found while buying (e.g. by a restore).
            _set(PurchaseFlowState.restored);
          }
          // A restore the person asked for reports itself when it ends; a
          // silent one says nothing.
        case StorePurchaseStatus.error:
          debugPrint('Purchase error: ${p.errorMessage}');
          _onBuyFailed(p);
        case StorePurchaseStatus.canceled:
          _onBuyFailed(p);
        case StorePurchaseStatus.pending:
          break; // handled above
      }
    }
    // Complete every accepted update that needs it, also errors,
    // cancellations and products this app doesn't know.
    if (p.needsCompletion) {
      try {
        await store.complete(p);
      } catch (e) {
        // Retried by the next silent restore (start or resume).
        debugPrint('completePurchase failed for ${p.productId}: $e');
      }
    }
  }

  void _onBuyFailed(StorePurchase p) {
    if (p.status == StorePurchaseStatus.canceled) {
      // Also while pending: a declined Ask to Buy or an abandoned cash
      // payment ends as a cancellation.
      if (_state == PurchaseFlowState.buying ||
          _state == PurchaseFlowState.pending) {
        _set(PurchaseFlowState.cancelled);
      }
      return;
    }
    if (p.status != StorePurchaseStatus.error) return;
    final kind = p.error ?? storeErrorFrom(p.errorMessage);
    debugPrint('Store error: ${p.errorMessage}');
    if (kind == StoreError.alreadyOwned) {
      // Google Play says this account owns it already: fetch it.
      _set(PurchaseFlowState.idle);
      unawaited(restore());
      return;
    }
    if (_state == PurchaseFlowState.buying ||
        _state == PurchaseFlowState.pending ||
        p.productId.isNotEmpty) {
      _set(PurchaseFlowState.error, error: kind);
    }
  }

  Future<void> _grant() async {
    if (_entitled) return;
    _entitled = true;
    _notify();
    await prefs.setBool(entitlementKey, true);
  }

  void _set(PurchaseFlowState s, {StoreError? error}) {
    if (s == PurchaseFlowState.error) {
      _errorWhileRestoring = _state == PurchaseFlowState.restoring;
    }
    _state = s;
    _error = error;
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
