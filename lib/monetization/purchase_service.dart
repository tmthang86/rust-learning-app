/// The store, reduced to what the "Remove ads" purchase needs. The real one
/// wraps the official in_app_purchase package; tests use a fake. These
/// types don't import the plugin, so this file also compiles for the web.
library;

enum StorePurchaseStatus { pending, purchased, restored, error, canceled }

/// One update from the store's purchase stream.
class StorePurchase {
  const StorePurchase({
    required this.productId,
    required this.status,
    this.needsCompletion = false,
    this.errorMessage,
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

  final String? errorMessage;
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

  /// True when [restore] runs silently, without asking the person to sign
  /// in to the store. Google Play's purchase query is silent, so the app
  /// restores at start there; the App Store re-delivers unfinished
  /// transactions by itself and its restore may ask for an Apple ID, so
  /// on iOS it only runs from the button.
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
