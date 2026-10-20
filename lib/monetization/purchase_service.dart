/// The store, reduced to what the "Remove ads" purchase needs. The real one
/// wraps the official in_app_purchase package; tests use a fake. These
/// types don't import the plugin, so this file also compiles for the web.
library;

enum StorePurchaseStatus { pending, purchased, restored, error, canceled }

/// Why a store action failed, in terms the UI can explain in plain words.
enum StoreError {
  /// Google Play: the account already owns the product (restore it).
  alreadyOwned,

  /// No connection, or the store service didn't answer.
  network,

  /// The store app or billing isn't available on this device/account.
  storeUnavailable,

  /// The product isn't on sale (not set up, or not in this country).
  itemUnavailable,

  /// An earlier purchase of the same product is still being processed.
  pendingTransaction,

  other,
}

/// Maps a store error code or message to a [StoreError].
///
/// in_app_purchase_android 0.5.4 puts the BillingResponse name in the
/// error message ("BillingResponse.itemAlreadyOwned", see
/// _getPurchaseDetailsFromResult in its source); StoreKit 2 errors arrive
/// as PlatformException codes such as "storekit_duplicate_product_object".
StoreError storeErrorFrom(Object? codeOrMessage) {
  final s = '$codeOrMessage';
  bool has(String part) => s.contains(part);
  if (has('itemAlreadyOwned')) return StoreError.alreadyOwned;
  if (has('serviceUnavailable') ||
      has('serviceDisconnected') ||
      has('serviceTimeout') ||
      has('networkError') ||
      has('SocketException')) {
    return StoreError.network;
  }
  if (has('billingUnavailable') || has('featureNotSupported')) {
    return StoreError.storeUnavailable;
  }
  if (has('itemUnavailable') || has('storekit2_failed_to_fetch_product')) {
    return StoreError.itemUnavailable;
  }
  if (has('storekit_duplicate_product_object')) {
    return StoreError.pendingTransaction;
  }
  return StoreError.other;
}

/// One update from the store's purchase stream.
class StorePurchase {
  const StorePurchase({
    required this.productId,
    required this.status,
    this.needsCompletion = false,
    this.errorMessage,
    this.error,
    this.purchaseId,
    this.serverVerificationData,
    this.raw,
  });

  final String productId;
  final StorePurchaseStatus status;

  /// in_app_purchase's `pendingCompletePurchase`: `completePurchase` must
  /// be called, or Google Play refunds the purchase after 3 days and the
  /// App Store keeps re-delivering it (in_app_purchase 3.3.1 README).
  final bool needsCompletion;

  /// The store's own error text, for logs only (not shown to people).
  final String? errorMessage;

  /// The error in plain terms; set for error updates.
  final StoreError? error;
  final String? purchaseId;

  /// Purchase token (Play) or signed transaction (App Store), for a future
  /// server check; see [PurchaseVerifier].
  final String? serverVerificationData;

  /// The plugin's own object, passed back to complete the purchase.
  final Object? raw;
}

/// A product as the store describes it, with a localised price.
class StoreProduct {
  const StoreProduct({
    required this.id,
    required this.title,
    required this.price,
    this.raw,
  });

  final String id;
  final String title;
  final String price;
  final Object? raw;
}

abstract class PurchaseService {
  /// False where the app sells nothing (web, desktop): no purchase UI.
  bool get supported;

  /// True when [restore] runs without asking the person anything, so the
  /// app can run it at every start and resume. Google Play's purchase
  /// query is silent, and so is StoreKit 2's restore, which reads
  /// Transaction.currentEntitlements (see restorePurchases in
  /// in_app_purchase_storekit 0.4.14, InAppPurchasePlugin+StoreKit2.swift).
  bool get restoresSilently;

  /// Purchase updates; listen from app start so none are missed.
  Stream<List<StorePurchase>> get purchaseUpdates;

  /// Whether the store can be reached.
  Future<bool> isAvailable();

  /// Details for [id], or null if the store doesn't know it.
  Future<StoreProduct?> queryProduct(String id);

  /// Starts buying a non-consumable product. The result arrives on
  /// [purchaseUpdates]. Returns false if the request wasn't sent.
  Future<bool> buyNonConsumable(StoreProduct product);

  /// Asks the store to re-deliver owned products as `restored` updates.
  Future<void> restore();

  /// Tells the store the purchase was delivered.
  Future<void> complete(StorePurchase purchase);

  /// Asks the store to refresh this account's purchases from its servers,
  /// for when a restore found nothing. StoreKit 2's AppStore.sync(), which
  /// may ask for the Apple ID password; nothing on Google Play.
  Future<void> syncWithStore();
}

/// No store (web, desktop).
class NoPurchaseService implements PurchaseService {
  const NoPurchaseService();

  @override
  bool get supported => false;
  @override
  bool get restoresSilently => false;
  @override
  Stream<List<StorePurchase>> get purchaseUpdates => const Stream.empty();
  @override
  Future<bool> isAvailable() async => false;
  @override
  Future<StoreProduct?> queryProduct(String id) async => null;
  @override
  Future<bool> buyNonConsumable(StoreProduct product) async => false;
  @override
  Future<void> restore() async {}
  @override
  Future<void> complete(StorePurchase purchase) async {}
  @override
  Future<void> syncWithStore() async {}
}

/// Decides whether a purchased or restored update is genuine before the
/// entitlement is granted.
///
/// At launch there is no server check: it would need a Cloud Function, and
/// Cloud Functions need Firebase's paid Blaze plan. [TrustDeviceVerifier]
/// trusts the store's on-device result instead. The trade-off: a tampered
/// device could fake a purchase and lose ads for free, and a refund isn't
/// noticed. For a one-time "Remove ads" item that risk is small.
///
/// To add a server check later, implement this with a call to a function
/// that verifies [StorePurchase.serverVerificationData] with the Play
/// Developer API or the App Store Server API, and pass it to
/// `PurchaseController(verifier: ...)` in main.dart.
abstract class PurchaseVerifier {
  Future<bool> verify(StorePurchase purchase);
}

class TrustDeviceVerifier implements PurchaseVerifier {
  const TrustDeviceVerifier();

  @override
  Future<bool> verify(StorePurchase purchase) async => true;
}
