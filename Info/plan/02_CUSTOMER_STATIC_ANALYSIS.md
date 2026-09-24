# 02 — Customer APK Static Analysis (Verified redBus Reference)

## Scope

This document records static evidence observed from the supplied `in.redbus.android` package. It is evidence about the **client**, not the hidden production backend.

## Application scale / UI evidence

- Base APK contains **636 layout XML resources** under `res/layout/`.
- The client contains both modern Kotlin/Jetpack Compose-style components (`*Kt`, Compose UI classes) and legacy Android XML/layout components.
- Customer code is highly modular, with named feature, core, network, data store, repository, reducer, side-effect, and UI-state packages.

## Major customer functional areas directly visible in class/package names

### Authentication
Observed examples include:

- `com/redbus/feature/authentication/ui/ContextualLoginActivityV2Kt`
- `EnterOTPScreenKt`
- `OTPRetryOptionsKt`
- `SkipLoginPopupKt`
- `AuthenticationFlowReducerKt`
- `SendOTPFlowReducerKt`
- `EnterOTPFlowReducerKt`
- `SmsRetrieverSideEffect`
- `SMSBroadcastReceiver`

**Inference:** phone/OTP-based onboarding is a first-class authentication path.

### Home / personalization
Observed examples include:

- `HomeViewModel`
- `SearchWidgetKt`
- `PromoComponentKt`
- `OffersCardComponentKt`
- `RecentTripCardComponentKt`
- `UpcomingTripComponentKt`
- `PreferredRoutesOrPreviouslyBookedComponentKt`
- `ResumeBookingComponentKt`
- `PaymentReminderComponentKt`
- `RefundStatusComponentKt`
- `ReferAndEarnComponentKt`
- `LanguageSwitchComponentKt`
- `TopDestinationsComponentKt`
- `RTCComponentKt` / `RTCV2ComponentKt`

### Search results (SRP)
Observed package `com/redbus/feature/srp` contains a large set of components and `SrpActivity`, including:

- filters/contextual filters
- alternate routes/dates
- best-seller / boosted inventory sections
- offer/promo containers
- bus tuple/service cards
- sorting and result-state components
- country-specific SRP variants

### Bus details / seat selection
Observed examples include:

- `BusDetailsScreenCommonKt`
- `BusDetailsScreenIND`
- `BusRouteINDKt`
- `AmenitiesComponentKt`
- `AmenitiesScreenKt`
- `BoardingAndDroppingScreenKt`
- `SeatLayoutDetailsScreenKt`
- `SeatLayoutHeaderComponentKt`
- `SeatDetailTabViewKt`
- `SeatLayoutUtilitiesKt`
- `SeatViewReducerHelper`

### Seat-lock / checkout
Observed package `com/redbus/core/seatLock` contains:

- `SeatLockSelectionViewKt`
- `SeatLockInfoBottomSheetKt`
- `SeatLockPaymentSelectionBottomSheetKt`
- `PayNowComponentKt`
- `PayNowBottomBarKt`
- `PayNowProgressComponentKt`
- `PaymentProgressStaticScreenKt`
- `CountDownTimerKt`

**Inference:** the customer client has a dedicated temporary seat-lock/checkout concept with a countdown and payment progression state.

### Payment
Observed:

- `com/redbus/core/network/payment/repository/PaymentRepository`
- `PaymentNetworkDataStore`
- `PaymentRepository` methods/strings such as `createOrder`, `getOrderInfo`, `releaseSeats`, `getOrderStatus`, `getBookingStatus`, `getOrderDetails`, `releaseWallet`, `createOfflinePayment`
- `redpay/foundationv2` and `redpay/foundationv3`
- Juspay assets/endpoints are present in the client

**Inference:** order lifecycle and payment state are separate server concepts, and seat release is an explicit operation.

### Post-booking / trip / ticket
Observed:

- `BusBuddyActivity`
- country-specific `BusBuddyIND`, `BusBuddyIDN`, `BusBuddyLATAM`, `BusBuddySGMY`, `BusBuddyVNM`
- `PDFDownloadHelper`
- trip repositories and `TripDao_Impl`
- `TripDatabase`
- `TripRepository$getTicketDetailsV2`
- QR-code ticket detail activity

**Inference:** a booked trip/ticket is represented as a durable local domain object and post-booking experience is a substantial feature module.

### Cancellation / rescheduling
Observed network package:

`com/redbus/core/network/rescheduleCancel/RescheduleCancellationDataStore`

Observed layout names include:

- `cancellation_refund_activity`
- `cancellation_refund_fragment`
- `date_change_activity`-related layouts
- `date_change_reschedule_bottomsheet`
- passenger-selection/date-change layouts

### Live tracking
Observed:

- `LiveTrackingNetworkDataStore`
- `LocationTrackerForegroundService`
- `PushLocationService`
- tracking-related classes and endpoints

**Inference:** live tracking is integrated into the trip lifecycle and can use foreground location services.

### Profile / wallet / support
Observed network stores include:

- `ProfileDataStore`
- `UserProfileDataStore`
- `PassengerInfoDataStore`
- `ProfilePaymentsDataStore`
- `RefundAccountsDataStore`
- `TaxDetailsDataStore`
- `GstDetailDataStore`
- `WalletDataStore`
- `WalletNetworkDataStore`
- `AccountDeactivationDataStore`
- `LogoutDataStore`
- `ReportAnIssueApiService`
- `FeedbackDataStore`

### Deep links
Observed classes include:

- `DeepLinkingActivity`
- `DeeplinkDispatchActivity`
- `DeeplinkDispatchViewModel`
- `DeeplinkDispatchRepository`
- `DeeplinkApiService`
- `GetFullUrlFromShortUrl`
- `GetBusInventoryContext`
- `submitCampaignContext`
- `ActivitiesDeeplinkSeoResolver`

**Inference:** deep links are a deliberate product capability and may resolve to specific bus/inventory or content contexts.

## Local persistence evidence

Observed:

- `TripDatabase`
- `TripDao_Impl`
- AndroidX Room classes
- AndroidX DataStore Preferences classes

**Inference:** the customer app uses both relational local persistence for trip-related data and preference-style local state. Do not reproduce redBus's local schema literally; implement the minimum robust Thirty8 cache/offline state required by the workflows.

## Architecture evidence

Repeated patterns include:

- `ViewModel`
- `RepositoryImpl`
- `NetworkDataStore`
- `DataStore`
- `Reducer`
- `SideEffect`
- `Navigation`
- UI-state helpers

**Inference:** a modular state-management / unidirectional-flow architecture is appropriate for Thirty8. The agent should use an equivalent maintainable pattern rather than blindly copying implementation internals.
