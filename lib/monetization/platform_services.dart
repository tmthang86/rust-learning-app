// Picks the real ad, consent and store services on Android and iOS, and
// no-op ones everywhere else. The conditional import keeps
// google_mobile_ads and in_app_purchase (which import dart:io) out of the
// web build entirely.
export 'platform_services_stub.dart'
    if (dart.library.io) 'platform_services_io.dart';
