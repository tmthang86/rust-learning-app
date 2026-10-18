// Android and iOS only: imported through platform_services_io.dart.
import 'dart:io' show Platform;

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

import 'purchase_service.dart';

/// The official in_app_purchase 3.3.1 plugin (StoreKit 2 by default on
/// iOS, Play Billing Library 8 on Android). API checked against the
/// package source and README.
class StorePurchaseService implements PurchaseService {
  StorePurchaseService([InAppPurchase? iap])
    : _iap = iap ?? InAppPurchase.instance;

  final InAppPurchase _iap;

  @override
  bool get supported => true;

  @override
  bool get restoresSilently => Platform.isAndroid;

  @override
  Stream<List<StorePurchase>> get purchaseUpdates =>
      _iap.purchaseStream.map((list) => list.map(_convert).toList());

  static StorePurchase _convert(PurchaseDetails p) {
    var status = switch (p.status) {
      PurchaseStatus.pending => StorePurchaseStatus.pending,
      PurchaseStatus.purchased => StorePurchaseStatus.purchased,
      PurchaseStatus.restored => StorePurchaseStatus.restored,
      PurchaseStatus.error => StorePurchaseStatus.error,
      PurchaseStatus.canceled => StorePurchaseStatus.canceled,
    };
    // in_app_purchase_android 0.5.4 marks every purchase found by
    // restorePurchases() as restored, even one still waiting for payment
    // (see GooglePlayPurchaseDetails and restorePurchases in its source).
    // Don't grant those.
    if (p is GooglePlayPurchaseDetails &&
        p.billingClientPurchase.purchaseState !=
            PurchaseStateWrapper.purchased) {
      status = StorePurchaseStatus.pending;
    }
    return StorePurchase(
      productId: p.productID,
      status: status,
      // Never complete a purchase that isn't paid yet.
      needsCompletion:
          p.pendingCompletePurchase && status != StorePurchaseStatus.pending,
      errorMessage: p.error?.message,
      purchaseId: p.purchaseID,
      serverVerificationData: p.verificationData.serverVerificationData,
      raw: p,
    );
  }

  @override
  Future<bool> isAvailable() => _iap.isAvailable();

  @override
  Future<StoreProduct?> queryProduct(String id) async {
    final response = await _iap.queryProductDetails({id});
    if (response.error != null) {
      throw Exception(response.error!.message);
    }
    for (final p in response.productDetails) {
      if (p.id == id) {
        return StoreProduct(id: p.id, title: p.title, price: p.price, raw: p);
      }
    }
    return null;
  }

  @override
  Future<bool> buyNonConsumable(StoreProduct product) => _iap.buyNonConsumable(
    purchaseParam: PurchaseParam(
      productDetails: product.raw! as ProductDetails,
    ),
  );

  @override
  Future<void> restore() => _iap.restorePurchases();

  @override
  Future<void> complete(StorePurchase purchase) =>
      _iap.completePurchase(purchase.raw! as PurchaseDetails);
}
