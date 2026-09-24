# Thirty8 — Complete Audit & Revised Development Plan

**Date:** 2026-09-21
**Purpose:** Pre-development audit comparing APK references against existing build plan, with Supabase-specific architecture and implementation-ready revision.

---

## TABLE OF CONTENTS

- [A. APK Feature Inventory](#a-apk-feature-inventory)
- [B. Current Plan Assessment](#b-current-plan-assessment)
- [C. Missing Features & Gaps](#c-missing-features--gaps)
- [D. Required Modifications](#d-required-modifications)
- [E. Supabase Architecture](#e-supabase-architecture)
- [F. Final Development Plan](#f-final-development-plan)
- [G. Pre-Build Checklist](#g-pre-build-checklist)

---

# A. APK Feature Inventory

Complete inventory of features, screens, workflows, and components found in both APK references.

## A.1 Customer App (redBus v82.5.5 — `in.redbus.android`)

### A.1.1 Authentication & Onboarding

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| C-AUTH-01 | Phone number entry | `ContextualLoginActivityV2Kt` | Primary auth method |
| C-AUTH-02 | OTP verification | `EnterOTPScreenKt`, `SMSBroadcastReceiver` | Auto-read SMS OTP |
| C-AUTH-03 | OTP retry/alternative | `OTPRetryOptionsKt` | Resend OTP, voice OTP |
| C-AUTH-04 | Skip login | `SkipLoginPopupKt` | Browse without login, booking requires auth |
| C-AUTH-05 | Login state management | `AuthenticationFlowReducerKt`, `SendOTPFlowReducerKt`, `EnterOTPFlowReducerKt` | Reducer-based flow |
| C-AUTH-06 | SMS retrieval | `SmsRetrieverSideEffect` | Auto-detect OTP |
| C-AUTH-07 | Account suspension/error | Error states in auth flow | Blocked account handling |
| C-AUTH-08 | Referral entry | Referral code during signup | Refer-and-earn integration |
| C-AUTH-09 | Email/Google login | `GmailAuthProvider` | `com.redbus.auth.core.gmail` |
| C-AUTH-10 | Biometric auth | `USE_BIOMETRIC`, `USE_FINGERPRINT` permissions | App lock/re-auth |
| C-AUTH-11 | Onboarding tutorial | `onboarding_1.webp` to `onboarding_4.webp` | First-launch walkthrough |

### A.1.2 Home Screen & Personalization

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| C-HOME-01 | Search widget | `SearchWidgetKt` | Source/destination/date quick search |
| C-HOME-02 | Promo/offers cards | `PromoComponentKt`, `OffersCardComponentKt` | Banner promotions |
| C-HOME-03 | Recent trips | `RecentTripCardComponentKt` | Quick rebook |
| C-HOME-04 | Upcoming trips | `UpcomingTripComponentKt` | Active booking display |
| C-HOME-05 | Preferred routes | `PreferredRoutesOrPreviouslyBookedComponentKt` | Personalized suggestions |
| C-HOME-06 | Resume booking | `ResumeBookingComponentKt` | Incomplete booking recovery |
| C-HOME-07 | Payment reminder | `PaymentReminderComponentKt` | Pending payment alerts |
| C-HOME-08 | Refund status | `RefundStatusComponentKt` | Refund progress display |
| C-HOME-09 | Refer & earn | `ReferAndEarnComponentKt` | Referral program entry |
| C-HOME-10 | Language switch | `LanguageSwitchComponentKt` | 29 locales supported |
| C-HOME-11 | Top destinations | `TopDestinationsComponentKt` | Popular route suggestions |
| C-HOME-12 | RTC (Road Transport Corporation) | `RTCComponentKt` / `RTCV2ComponentKt` | Government bus services |
| C-HOME-13 | Country-specific config | `bus_preference_v2_*.json` (IND, IDN, KHM, MYS, PER, SGP, VNM, COL) | Multi-market support |

### A.1.3 Search & Results (SRP)

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| C-SRCH-01 | City/location picker | `LocationPickerActivity` | Autocomplete, recent, popular |
| C-SRCH-02 | Travel date selector | Date picker in search | Calendar with fare hints |
| C-SRCH-03 | Search results list | `SrpActivity` | Bus cards with fares |
| C-SRCH-04 | Alternate dates/routes | SRP components | Flex date suggestions |
| C-SRCH-05 | Filters | Filter chips in SRP | Bus type, departure time, amenities, price range |
| C-SRCH-06 | Sort | Sort sheet | Price, departure time, rating, duration |
| C-SRCH-07 | Empty/error/oops states | SRP state components | No results found handling |
| C-SRCH-08 | Best-seller/boosted inventory | SRP components | Promoted listings |
| C-SRCH-09 | Offer/promo containers in SRP | SRP components | Inline offers |
| C-SRCH-10 | Country-specific SRP variants | SRP package per country | Different UIs per market |
| C-SRCH-11 | Bus tuple/service cards | SRP bus cards | Operator name, bus type, timings, fare, seats available |

### A.1.4 Bus Details & Seat Selection

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| C-BUS-01 | Bus details screen | `BusDetailsScreenCommonKt`, `BusDetailsScreenIND` | Country-specific layouts |
| C-BUS-02 | Route information | `BusRouteINDKt` | Intermediate stops |
| C-BUS-03 | Amenities | `AmenitiesComponentKt`, `AmenitiesScreenKt` | WiFi, charging, blankets, etc. |
| C-BUS-04 | Boarding & dropping points | `BoardingAndDroppingScreenKt` | Location selection with map |
| C-BUS-05 | Seat layout/map | `SeatLayoutDetailsScreenKt`, `SeatLayoutHeaderComponentKt` | Interactive seat map |
| C-BUS-06 | Seat detail tab | `SeatDetailTabViewKt` | Seat info expansion |
| C-BUS-07 | Seat legend | Seat layout components | Visual state guide |
| C-BUS-08 | Seat states (available, booked, blocked, ladies) | Seat layout resources | Color/icon-coded |
| C-BUS-09 | Multi-seat selection | Seat selection logic | Multiple passengers |
| C-BUS-10 | Fare update on selection | Fare summary components | Dynamic price calculation |
| C-BUS-11 | Bus photos/gallery | Gallery layouts | Operator bus images |
| C-BUS-12 | Ratings & reviews | `RatingAndReviewActivity` | Passenger ratings |
| C-BUS-13 | Cancellation policy display | Cancellation policy in bus details | Policy terms shown pre-booking |

### A.1.5 Seat Lock & Checkout

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| C-LOCK-01 | Temporary seat hold | `SeatLockSelectionViewKt` | Server-side lock |
| C-LOCK-02 | Hold countdown timer | `CountDownTimerKt` | Time-limited lock |
| C-LOCK-03 | Lock info bottom sheet | `SeatLockInfoBottomSheetKt` | Hold details display |
| C-LOCK-04 | Payment selection during lock | `SeatLockPaymentSelectionBottomSheetKt` | Choose payment within hold |
| C-LOCK-05 | Pay now bar | `PayNowComponentKt`, `PayNowBottomBarKt` | CTA during hold |
| C-LOCK-06 | Payment progress | `PayNowProgressComponentKt`, `PaymentProgressStaticScreenKt` | Processing states |
| C-LOCK-07 | Seat release on timeout/expiry | Hold state machine | Auto-release held seats |
| C-LOCK-08 | Seat release on payment failure | `releaseSeats` in PaymentRepository | Explicit release API |

### A.1.6 Passenger Information

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| C-PASS-01 | Primary passenger details | CustInfoActivity components | Name, age, gender, phone |
| C-PASS-02 | Multiple passengers | Multi-passenger forms | Group booking |
| C-PASS-03 | Saved/co-passengers | `CoPaxListActivity` | Quick-select saved passengers |
| C-PASS-04 | Contact details | Email, phone for notifications | Booking confirmations |
| C-PASS-05 | Gender-specific rules | Seat gender constraints | Ladies seat assignment |
| C-PASS-06 | Add-ons / insurance | Add-on components | Optional travel insurance |
| C-PASS-07 | Fare breakup | Fare summary | Itemized cost display |
| C-PASS-08 | Coupon/offer application | Promo components | Discount codes |
| C-PASS-09 | GST/tax details | `GstDetailActivity`, `TaxDetailsActivity` | Business traveler tax info |

### A.1.7 Payment

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| C-PAY-01 | Order creation | `createOrder` in PaymentRepository | Server-side order |
| C-PAY-02 | Multiple payment methods | `PaymentRedirectionActivity` | UPI, cards, wallets, netbanking |
| C-PAY-03 | Payment SDK integration | JusPay assets (`in.juspay.hyperpay`, etc.) | Third-party payment processing |
| C-PAY-04 | UPI payment | JusPay UPI module | UPI intent and collect |
| C-PAY-05 | Wallet payment | `WalletActivity`, `WalletDataStore` | redBus wallet / RedPay |
| C-PAY-06 | RedPay integration | `redpay/foundationv2`, `redpay/foundationv3` | Proprietary payment layer |
| C-PAY-07 | Processing state | Payment progress components | Loading/processing UI |
| C-PAY-08 | Payment success | `PaymentRedirectionActivity` | Confirmation redirect |
| C-PAY-09 | Payment failure/retry | Payment error states | Retry flow |
| C-PAY-10 | Pending status | `getOrderStatus`, `getBookingStatus` | Polling for confirmation |
| C-PAY-11 | Seat release on failure | `releaseSeats` API | Inventory recovery |
| C-PAY-12 | Offline payment | `createOfflinePayment`, `OfflineVoucherDetailsActivity` | Pay-at-bus option |
| C-PAY-13 | Google Pay | `google_pay_inapp_api_config.properties` | Google Pay integration |
| C-PAY-14 | Simpl (Buy Now Pay Later) | `SimplActivity` | BNPL option |
| C-PAY-15 | Payment reminder notification | `PaymentReminderPNService` | Remind pending payments |

### A.1.8 Post-Booking & Ticket

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| C-TICK-01 | Booking confirmation | Booking confirmation screen | Success page |
| C-TICK-02 | Ticket summary | `ticket_details_view.xml` | All booking details |
| C-TICK-03 | QR code ticket | QR ticket activity | Scannable ticket |
| C-TICK-04 | Passenger details on ticket | Ticket components | Per-passenger info |
| C-TICK-05 | Seat details on ticket | Ticket components | Assigned seats |
| C-TICK-06 | Boarding/drop details | Ticket components | Pickup/drop locations & times |
| C-TICK-07 | PDF download | `PDFDownloadHelper` | Ticket as PDF |
| C-TICK-08 | Share ticket | Share components | Send ticket via apps |
| C-TICK-09 | Trip status | Trip status components | Live trip state |

### A.1.9 My Trips

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| C-TRIP-01 | Upcoming trips | My Trips tabs | Future bookings |
| C-TRIP-02 | Active/in-progress trips | Trip state management | Currently traveling |
| C-TRIP-03 | Completed trips | Trip history | Past journeys |
| C-TRIP-04 | Cancelled trips | Trip filtering | Cancelled bookings |
| C-TRIP-05 | Booking detail | Booking detail screen | Full booking view |
| C-TRIP-06 | Refund status | Refund status components | Post-cancellation tracking |
| C-TRIP-07 | Rebook/reschedule | Reschedule components | Change date/route |

### A.1.10 Cancellation & Refund

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| C-CANC-01 | Cancellation preview | `cancellation-preview` API | Show refund amount before cancel |
| C-CANC-02 | Cancellation policy | Policy display | Sliding scale refund |
| C-CANC-03 | Passenger selection for cancel | `cancellation_refund_fragment` | Partial cancellation |
| C-CANC-04 | Cancellation confirmation | `CancellationActivity` | Confirm cancel action |
| C-CANC-05 | Refund to original payment | Refund flow | Auto-refund |
| C-CANC-06 | Bank NEFT refund | `BankNeftActivity` | Manual bank transfer refund |
| C-CANC-07 | Refund status tracking | `BusBookingFailedRefundDetailsActivity` | Refund progress |
| C-CANC-08 | Reschedule (date change) | `date_change_activity`, `date_change_reschedule_bottomsheet` | Change travel date |
| C-CANC-09 | Reschedule options | `RescheduleCancellationDataStore` | Alternative date/route selection |

### A.1.11 Live Tracking (Bus Buddy)

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| C-TRCK-01 | Live bus tracking | `BusBuddyActivity` | Real-time map |
| C-TRCK-02 | Country-specific tracking | `BusBuddyIND`, `BusBuddyIDN`, `BusBuddyLATAM`, etc. | Per-market UI |
| C-TRCK-03 | Vehicle location sharing | `GpsLocationSharingService` | Operator shares location |
| C-TRCK-04 | Foreground location service | `LocationTrackerForegroundService` | Background tracking |
| C-TRCK-05 | Push location service | `PushLocationService` | Location push to server |
| C-TRCK-06 | Round trip booking from tracking | `RoundTripBookingActivity` | Book return from live view |
| C-TRCK-07 | Vehicle tracking activity | `VehicleTrackingActivity` | Dedicated tracking screen |

### A.1.12 Profile & Account

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| C-PROF-01 | Profile view/edit | `PersonalInfoActivity` | Name, email, gender |
| C-PROF-02 | Saved passengers | `CoPaxListActivity` | Manage co-passengers |
| C-PROF-03 | Saved payment methods | `ProfilePaymentsActivity` | Stored cards/wallets |
| C-PROF-04 | GST details | `GstDetailActivity` | GSTIN for business travel |
| C-PROF-05 | Tax details | `TaxDetailsActivity` | Tax information |
| C-PROF-06 | Bank NEFT refund accounts | `RefundAccountsActivity` | Saved bank accounts for refunds |
| C-PROF-07 | Account settings | `AccountSettingsActivity` | Account management |
| C-PROF-08 | About us | `AboutUsV2Activity` | App information |
| C-PROF-09 | Notification permissions | `NotificationPermissionActivity` | Push notification opt-in |
| C-PROF-10 | Account deactivation | `AccountDeactivationDataStore` | Account deletion/deactivation |
| C-PROF-11 | Logout | `LogoutDataStore` | Sign out |

### A.1.13 Wallet & Rewards

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| C-WALT-01 | Wallet balance | `WalletActivity` | View balance |
| C-WALT-02 | Wallet transactions | `WalletDataStore` | Transaction history |
| C-WALT-03 | Wallet top-up | Wallet components | Add money |
| C-WALT-04 | Wallet payment | Wallet as payment method | Pay from wallet |
| C-WALT-05 | Wallet release | `releaseWallet` in PaymentRepository | Release on failure |
| C-WALT-06 | Refer and earn | `ReferAndEarnActivity` | Referral rewards |
| C-WALT-07 | Gamification/streaks | `GamificationActivity`, `TripRewardActivity`, `ViewAllStreaksActivity` | Engagement features |
| C-WALT-08 | Scratch cards | `ScratchCardsActivity` | Reward scratch cards |

### A.1.14 Notifications

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| C-NOTI-01 | Push notifications | `POST_NOTIFICATIONS` permission | FCM/MoEngage |
| C-NOTI-02 | Rich push notifications | `moe_rich_push_*` layouts | MoEngage rich push |
| C-NOTI-03 | Live journey notifications | `PreJourneyLiveNotificationService` | Pre-departure alerts |
| C-NOTI-04 | Waiting room notifications | `WaitingRoomLiveNotificationService` | At boarding point |
| C-NOTI-05 | Payment reminder notifications | `PaymentReminderPNService` | Pending payment alerts |
| C-NOTI-06 | Offline voucher push | `OfflineVoucherPushNotificationService` | Voucher notifications |
| C-NOTI-07 | Notification opt-out actions | `OptOutActionReceiver`, dismiss receivers | User control |

### A.1.15 Additional Features (Beyond Core Booking)

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| C-EXTR-01 | ONDC Auto (ride-hailing) | `OndcAutoSearchActivity`, `OndcSelectLocationOnMapActivity`, `RideDetailsActivity` | Auto/rickshaw booking |
| C-EXTR-02 | Hotels | `HotelsSRPActivity`, `HotelAutoSearchActivity`, `HotelMapExplorerActivity`, `HotelBuddyActivity` | Hotel booking |
| C-EXTR-03 | City Bus (ONDC) | `CityBusPreBookingActivity`, `CityBusPostBookingActivity` | City bus booking |
| C-EXTR-04 | Rail pass | `RailPassDetailsActivity`, `RailPassPaymentSuccessActivity` | Train/rail features |
| C-EXTR-05 | Things to Do (KMP) | `ActivityDetailsActivity`, `BlogsListingActivity`, `CartActivity`, `CheckoutActivity` | Activities/experiences |
| C-EXTR-06 | Gift cards | `GiftCardsActivity` | Gift card purchase |
| C-EXTR-07 | RedTV (video content) | `RedTvActivity` | Video content feature |
| C-EXTR-08 | KOL videos | `KOLHomeScreenActivity` | Influencer video content |
| C-EXTR-09 | Group chat | `GroupChatActivity` | In-trip group messaging |
| C-EXTR-10 | Voice AI (Vani) | `VaniActivity` | Voice assistant |
| C-EXTR-11 | Panorama view | `PanoramaViewActivity` | Bus interior 360° view |
| C-EXTR-12 | Ratings & reviews | `RatingAndReviewActivity`, `AudioTranscriptionDialogActivity` | Post-trip rating with AI transcription |
| C-EXTR-13 | Deep linking | `DeepLinkingActivity`, `DeeplinkDispatchActivity` | URL-based navigation |
| C-EXTR-14 | WebView | `WebViewActivity` | In-app web content |
| C-EXTR-15 | Wearable support | `WearDataLayerListenerService` | Smartwatch integration |
| C-EXTR-16 | Map SDK | `RedbusMapSdkProvider` | Custom map implementation |
| C-EXTR-17 | Screen capture detection | `DETECT_SCREEN_CAPTURE`, `DETECT_SCREEN_RECORDING` | Security feature |
| C-EXTR-18 | Multi-language (29 locales) | Language assets | Comprehensive localization |

### A.1.16 Permissions Summary (Customer)

| Category | Permissions |
|----------|-------------|
| Location | `ACCESS_COARSE_LOCATION`, `ACCESS_FINE_LOCATION` |
| Camera | `CAMERA` |
| Audio | `RECORD_AUDIO`, `MODIFY_AUDIO_SETTINGS` |
| Contacts | `READ_CONTACTS`, `GET_ACCOUNTS` |
| Calendar | `READ_CALENDAR`, `WRITE_CALENDAR` |
| Phone | `READ_PHONE_STATE`, `READ_BASIC_PHONE_STATE` |
| SMS | `READ_SMS`, `RECEIVE_SMS` |
| Network | `INTERNET`, `ACCESS_WIFI_STATE`, `ACCESS_NETWORK_STATE` |
| Notifications | `POST_NOTIFICATIONS` |
| Background | `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, `FOREGROUND_SERVICE_LOCATION`, `FOREGROUND_SERVICE_SPECIAL_USE`, `RECEIVE_BOOT_COMPLETED`, `WAKE_LOCK` |
| Security | `USE_BIOMETRIC`, `USE_FINGERPRINT` |
| System | `SYSTEM_ALERT_WINDOW`, `VIBRATE`, `REORDER_TASKS` |
| Ads/Analytics | `AD_ID`, `ACCESS_ADSERVICES_ATTRIBUTION`, `ACCESS_ADSERVICES_AD_ID`, `ACCESS_ADSERVICES_TOPICS` |

---

## A.2 Operator App (redBus Plus v2.0.6 — `redbus.rbplus.android`)

### A.2.1 Authentication & Setup

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| O-AUTH-01 | Login | `LoginActivity` | Email/phone + password |
| O-AUTH-02 | Sign up | `SignUpActivity` | New operator registration |
| O-AUTH-03 | Forgot password | `ForgotPasswordActivity` | Password recovery |
| O-AUTH-04 | Onboarding tutorial | `OnBoardingActivity`, onboarding layouts | First-time walkthrough |
| O-AUTH-05 | Language selection | `LanguageActivity` | Multi-language |
| O-AUTH-06 | Privacy policy | `PrivacyPolicy` | Legal terms |

### A.2.2 Dashboard & Navigation

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| O-HOME-01 | Home/dashboard | `Home` activity | Main operator view |
| O-HOME-02 | Navigation drawer | `NavigationDrawerFragment` | Side menu navigation |
| O-HOME-03 | Profile update | `UpdateProfile` | Operator profile management |

### A.2.3 Service & Trip Management

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| O-SVC-01 | Route/city search | `SearchActivity`, `CityPicker` | Find routes and services |
| O-SVC-02 | Calendar/date selection | `CalendarActivity` | Trip date picker |
| O-SVC-03 | Service listing | `MyService` model | Operator's services |
| O-SVC-04 | Trip listing | Service/trip adapters | Trips by date/route |

### A.2.4 Booking & Reservation

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| O-BKNG-01 | Seat selection | `SeatActivity`, `seat_activity.xml` | Choose seats for booking |
| O-BKNG-02 | Seat layout view | `seat_view.xml`, `seat_list_item.xml`, deck layouts | Interactive seat map |
| O-BKNG-03 | Quick booking | `quick_booking_dialog.xml` | Fast booking flow |
| O-BKNG-04 | Passenger details | `PassengerActivity`, `activity_passenger.xml` | Passenger information entry |
| O-BKNG-05 | Booking history | `fragment_bookings.xml`, `booking_history_ticket_fragment.xml` | Past/upcoming bookings |
| O-BKNG-06 | Boarding & dropping points | `BoardingAndDropping`, `boarding_dropping_point.xml` | Select stops |

### A.2.5 Ticket & Manifest

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| O-TICK-01 | Ticket view | `TicketActivity`, `activity_ticket.xml` | View issued ticket |
| O-TICK-02 | Generate manifest | `GenerateManifest`, `manifest_activity.xml` | Create boarding manifest |
| O-TICK-03 | Driver manifest | `DriverManifest`, `driver_manifest_spinner_text_view.xml` | Driver's copy |
| O-TICK-04 | Manifest fragment | `ManifestFragmentNew` | Manifest list view |
| O-TICK-05 | Print ticket | `PrintActivity`, `print_ticket.xml`, `printer_main.xml` | Physical ticket printing |
| O-TICK-06 | Print options | `print_options_layout.xml` | Print configuration |
| O-TICK-07 | QR scanner | `QRScanner` | Scan ticket QR codes |
| O-TICK-08 | Cancellation dialog | `cancellation_dialog.xml` | Cancel bookings |

### A.2.6 Financial

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| O-FIN-01 | Wallet | `fragment_wallet_new.xml` | Operator wallet balance |
| O-FIN-02 | Statements | `fragment_statement.xml` | Transaction statements |
| O-FIN-03 | Fare details | Fare model fields | baseFare, totalFare, serviceCharge, serviceTax |

### A.2.7 Operator App Additional

| # | Feature | Evidence | Notes |
|---|---------|----------|-------|
| O-EXTR-01 | Seat layout deck view | `fragment_deck_layout.xml`, `fragment_seat_layout.xml` | Multi-deck buses |
| O-EXTR-02 | Reservation management | `reservation` layouts | Reserved seats handling |
| O-EXTR-03 | Booking lookup | Search functionality | Find bookings by reference |
| O-EXTR-04 | Live tracking flag | `liveTrackingAvailable` field | Enable/disable tracking per trip |

### A.2.8 Permissions & Integrations (Operator)

| Feature | Evidence | Notes |
|---------|----------|-------|
| Camera (QR scan) | `QRScanner` activity | QR code scanning |
| Firebase | `redbus-plus.firebaseio.com` | Real-time data/sync |
| Gamooga | Push notification service | Operator push notifications |
| Printer integration | Print layouts/activity | Bluetooth/thermal printer |

---

## A.3 Feature Count Summary

| Category | Customer App | Operator App |
|----------|-------------|-------------|
| Authentication | 11 features | 6 features |
| Home/Dashboard | 13 features | 3 features |
| Search | 11 features | 2 features |
| Bus Details/Seat | 13 features | 3 features |
| Seat Lock/Checkout | 8 features | 0 (handled differently) |
| Passenger Info | 9 features | 1 feature |
| Payment | 15 features | 1 feature |
| Post-Booking/Ticket | 9 features | 5 features |
| My Trips | 7 features | 1 feature |
| Cancellation/Refund | 9 features | 1 feature |
| Live Tracking | 7 features | 1 feature |
| Profile/Account | 11 features | 1 feature |
| Wallet/Rewards | 8 features | 2 features |
| Notifications | 7 features | 0 |
| Additional Features | 18 features | 4 features |
| **TOTAL** | **156 features** | **31 features** |

---

# B. Current Plan Assessment

What the existing plan covers correctly and comprehensively.

## B.1 Well-Covered Areas (Plan is Solid)

### B.1.1 Core Domain Model (File 05)
**Status: CORRECT and COMPLETE**

The shared domain model correctly identifies:
- `users`, `roles`, `user_roles`, `operators`, `operator_users`
- `buses`, `bus_layouts`, `seats`
- `routes`, `route_stops`, `boarding_points`, `dropping_points`
- `services`, `trips`, `trip_stops`, `trip_staff`
- `trip_seats`, `seat_holds`, `inventory_events`
- `passengers`, `bookings`, `booking_items`, `booking_status_history`, `tickets`
- `orders`, `payments`, `payment_attempts`, `refunds`, `refund_events`
- `trip_manifests`, `manifest_passengers`, `boarding_events`, `qr_verifications`
- `fare_rules`, `cancellation_policies`, `coupons`, `promotions`
- `notifications`, `notification_preferences`, `support_cases`, `audit_logs`

**Assessment:** This is comprehensive and aligns well with both APKs. No major entities missing for core bus booking.

### B.1.2 Seat State Machine (File 08)
**Status: CORRECT**

The seat state machine accurately models:
- `AVAILABLE → HELD → BOOKED` (success path)
- `HELD → AVAILABLE` (release/expiry)
- `BOOKED → CANCELLED → REFUND_PENDING → REFUNDED`
- `BOOKED → BOARDED`

The concurrency algorithm (SELECT FOR UPDATE) is correct for Supabase/PostgreSQL.

### B.1.3 Booking State Machine (File 08)
**Status: CORRECT**

Correctly models: `DRAFT → HOLD_CREATED → ORDER_CREATED → PAYMENT_PENDING → CONFIRMING → CONFIRMED` with failure branches.

### B.1.4 RBAC Matrix (File 09)
**Status: MOSTLY CORRECT**

The 5-role model (Customer, Operator Admin, Operator Staff, Driver/Conductor, Platform Admin) covers the primary access patterns observed in both APKs.

### B.1.5 API Contract (File 07)
**Status: PARTIALLY COMPLETE**

Correctly defines:
- Authentication endpoints
- Search endpoints
- Seat locking endpoints
- Booking/payment flow
- Cancellation/refund
- Operator fleet management
- Operator booking management
- Manifest/boarding

### B.1.6 Database Schema (File 06)
**Status: MOSTLY CORRECT for core tables**

Covers 20+ core tables with proper PK/FK, unique constraints, and indexes. The seat uniqueness constraint `UNIQUE(trip_id, seat_id)` is correctly specified.

### B.1.7 Build Order (Files 13, 14)
**Status: LOGICAL**

The 12-step build checklist follows a sensible dependency order.

---

## B.2 Areas with Partial Coverage

### B.2.1 Customer UI Workflow Inventory (File 03)
**Status: INCOMPLETE**

Covers 9 journeys (A through I) which map well to the core booking flow. However, it misses:
- Live tracking detailed workflows
- Wallet/rewards workflows
- Multi-language switching UX
- Deep linking behavior
- Offline/low-network states
- Gamification/streaks engagement features

### B.2.2 Operator Analysis (File 04)
**Status: INCOMPLETE**

Identifies major activities but misses:
- Detailed manifest generation workflow
- QR scanning verification flow
- Printer integration specifics
- Wallet/statement transaction flow
- Quick booking vs regular booking differences
- Boarding point management details

### B.2.3 UI Design System (File 10)
**Status: BASIC but INCOMPLETE**

Lists core components but lacks:
- Component specifications (sizes, spacing, typography)
- Color tokens and theme definition
- Animation/transition specifications
- Responsive layout rules
- Accessibility requirements
- Dark mode considerations

### B.2.4 Evidence Traceability (File 12)
**Status: MINIMAL**

Only 13 entries in the matrix. Should be expanded to cover every feature in the inventory.

---

# C. Missing Features & Gaps

Features present in the APK but missing from the plan, or inadequately addressed.

## C.1 Critical Missing Features

### C.1.1 Multi-Market / Multi-Country Support
**APK Evidence:** 29 locales, country-specific configs (IND, IDN, KHM, MYS, PER, SGP, VNM, COL), country-specific seat layouts, country-specific BusBuddy variants.
**Plan Coverage:** None. The plan assumes India-only.
**Impact:** HIGH — This is a core architectural decision.

**What needs to be added:**
- Country/region entity in database
- Locale/language preference per user
- Country-specific fare rules and currencies
- Country-specific boarding/dropping point formats
- Country-specific payment methods
- Localized UI strings (i18n framework)
- Country-specific bus types and classifications

### C.1.2 Multi-Language / Localization (i18n)
**APK Evidence:** 29 locales including Hindi, Bengali, Marathi, Kannada, Tamil, Telugu, Spanish, Indonesian, Khmer, Malay, Vietnamese, Chinese.
**Plan Coverage:** Mentioned in RBAC matrix but no implementation plan.
**Impact:** HIGH

**What needs to be added:**
- Translation string tables
- RTL support (if needed)
- Locale detection and switching
- Date/time/number formatting per locale
- Localized error messages

### C.1.3 Offline / Low-Network Handling
**APK Evidence:** Local `TripDatabase` (Room), `TripDao`, DataStore preferences, cached trip data.
**Plan Coverage:** Not addressed.
**Impact:** MEDIUM-HIGH

**What needs to be added:**
- Offline ticket viewing (cached)
- Offline QR code display
- Sync-on-reconnect strategy
- Network state detection
- Optimistic UI updates

### C.1.4 Push Notification Architecture
**APK Evidence:** MoEngage SDK, FCM, rich push notifications, live journey notifications, payment reminders, waiting room notifications.
**Plan Coverage:** "Notifications" mentioned in domain model but no detailed architecture.
**Impact:** HIGH

**What needs to be added:**
- Push notification service (FCM integration)
- Notification templates per event type
- Notification preferences per user
- Rich notification support (images, actions)
- Live journey notification triggers
- Payment reminder scheduling
- Notification delivery tracking

### C.1.5 Payment Gateway Integration Details
**APK Evidence:** JusPay SDK, UPI intent/collect, Google Pay, Simpl BNPL, wallet, offline payment.
**Plan Coverage:** Basic payment adapter mentioned, but no detailed integration architecture.
**Impact:** HIGH

**What needs to be added:**
- Payment provider adapter pattern
- UPI flow (intent + collect)
- Card payment flow
- Netbanking flow
- Wallet integration
- BNPL (Buy Now Pay Later) option
- Offline payment handling
- Payment reconciliation
- Webhook verification
- Idempotent payment processing

### C.1.6 PDF Ticket Generation
**APK Evidence:** `PDFDownloadHelper`, PDF generation for tickets.
**Plan Coverage:** Not addressed.
**Impact:** MEDIUM

**What needs to be added:**
- Server-side PDF generation
- PDF template design
- PDF storage and retrieval
- Share/download functionality

## C.2 Missing Customer Features

### C.2.1 Gamification & Engagement
**APK Evidence:** `GamificationActivity`, `TripRewardActivity`, `ViewAllStreaksActivity`, `ScratchCardsActivity`, streaks system.
**Plan Coverage:** Not addressed.
**Impact:** MEDIUM (engagement feature)

### C.2.2 Ratings & Reviews
**APK Evidence:** `RatingAndReviewActivity`, `AudioTranscriptionDialogActivity` (AI transcription of reviews).
**Plan Coverage:** Not addressed.
**Impact:** MEDIUM

### C.2.3 Refer & Earn
**APK Evidence:** `ReferAndEarnActivity`, referral code entry during signup.
**Plan Coverage:** Not addressed.
**Impact:** MEDIUM (growth feature)

### C.2.4 Gift Cards
**APK Evidence:** `GiftCardsActivity`.
**Plan Coverage:** Not addressed.
**Impact:** LOW-MEDIUM

### C.2.5 Deep Linking
**APK Evidence:** `DeepLinkingActivity`, `DeeplinkDispatchActivity`, deep link resolution.
**Plan Coverage:** Not addressed.
**Impact:** MEDIUM

### C.2.6 Group Chat (In-Trip)
**APK Evidence:** `GroupChatActivity`, `GroupChatPermissionChangedReceiver`.
**Plan Coverage:** Not addressed.
**Impact:** LOW (advanced feature)

### C.2.7 Voice AI Assistant
**APK Evidence:** `VaniActivity`, voice entry sound.
**Plan Coverage:** Not addressed.
**Impact:** LOW (advanced feature, likely not needed for MVP)

### C.2.8 Panorama Bus View
**APK Evidence:** `PanoramaViewActivity`, panorama renderer library.
**Plan Coverage:** Not addressed.
**Impact:** LOW

### C.2.9 RTC (Government Bus) Integration
**APK Evidence:** `RTCComponentKt`, `RTCV2ComponentKt`.
**Plan Coverage:** Not addressed.
**Impact:** MEDIUM (if targeting government bus operators)

### C.2.10 Resume Booking
**APK Evidence:** `ResumeBookingComponentKt`.
**Plan Coverage:** Not addressed.
**Impact:** MEDIUM (UX improvement)

### C.2.11 Payment Reminder for Pending Bookings
**APK Evidence:** `PaymentReminderComponentKt`, `PaymentReminderPNService`.
**Plan Coverage:** Not addressed.
**Impact:** MEDIUM (revenue recovery)

### C.2.12 Saved Payment Methods
**APK Evidence:** `ProfilePaymentsActivity`.
**Plan Coverage:** Not addressed (wallet mentioned but not saved cards).
**Impact:** MEDIUM

### C.2.13 GST/Tax Details for Business Travelers
**APK Evidence:** `GstDetailActivity`, `TaxDetailsActivity`.
**Plan Coverage:** Not addressed.
**Impact:** LOW-MEDIUM

### C.2.14 Bank NEFT Refund
**APK Evidence:** `BankNeftActivity`, `RefundAccountsActivity`.
**Plan Coverage:** Basic refund mentioned, but not bank-specific refund flow.
**Impact:** MEDIUM

### C.2.15 Screen Capture/Recording Detection
**APK Evidence:** `DETECT_SCREEN_CAPTURE`, `DETECT_SCREEN_RECORDING` permissions.
**Plan Coverage:** Not addressed.
**Impact:** LOW (security feature)

## C.3 Missing Operator Features

### C.3.1 Printer Integration
**APK Evidence:** `PrintActivity`, `printer_main.xml`, `print_ticket.xml`, `print_options_layout.xml`. Thermal/Bluetooth printer support.
**Plan Coverage:** Not addressed.
**Impact:** HIGH for operator app

### C.3.2 Driver Manifest (Detailed)
**APK Evidence:** `DriverManifest`, `GenerateManifest`, detailed manifest layouts.
**Plan Coverage:** Basic manifest mentioned but not the detailed driver handoff workflow.
**Impact:** HIGH

### C.3.3 Quick Booking vs Regular Booking
**APK Evidence:** `quick_booking_dialog.xml` — operators can make fast bookings without full passenger details.
**Plan Coverage:** Not distinguished.
**Impact:** MEDIUM

### C.3.4 Wallet & Statement Details
**APK Evidence:** `fragment_wallet_new.xml`, `fragment_statement.xml` — operator financial views.
**Plan Coverage:** Basic wallet mentioned but no statement/transaction detail architecture.
**Impact:** MEDIUM

### C.3.5 Operator Onboarding Flow
**APK Evidence:** `OnBoardingActivity`, onboarding item layouts — first-time operator setup.
**Plan Coverage:** Not addressed as a distinct flow.
**Impact:** MEDIUM

## C.4 Missing Infrastructure

### C.4.1 Analytics & Event Tracking
**APK Evidence:** `AnalyticsEngineProvider`, Google Analytics, GTM container, MoEngage, Firebase Analytics.
**Plan Coverage:** Not addressed.
**Impact:** MEDIUM

### C.4.2 A/B Testing & Feature Flags
**APK Evidence:** Country config JSON, feature splits (ferry, gamification, redTv, waterways as separate APKs).
**Plan Coverage:** Not addressed.
**Impact:** MEDIUM

### C.4.3 Crash Reporting & Monitoring
**APK Evidence:** Firebase Crashlytics (`firebase_crashlytics_keep.xml`).
**Plan Coverage:** Not addressed.
**Impact:** MEDIUM

### C.4.4 App Update Mechanism
**APK Evidence:** Configuration/update checks in Journey A.
**Plan Coverage:** Not addressed.
**Impact:** LOW

### C.4.5 Security: Data Encryption, Certificate Pinning
**APK Evidence:** `SecurityInstanceProvider`, `rbdatasecurity` package.
**Plan Coverage:** Basic security in RBAC matrix, but no transport security details.
**Impact:** MEDIUM

### C.4.6 Admin Web Panel (Detailed)
**APK Evidence:** Admin functionality not in APK (separate web app).
**Plan Coverage:** Mentioned in build order but no detailed spec.
**Impact:** HIGH

---

# D. Required Modifications

Specific changes required in the existing plan.

## D.1 Database Schema Modifications (File 06)

### D.1.1 Add `countries` table
**Current:** Not present.
**Required:**
```sql
CREATE TABLE countries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code VARCHAR(3) UNIQUE NOT NULL,       -- ISO 3166-1 alpha-3
  name VARCHAR(100) NOT NULL,
  phone_code VARCHAR(10),
  currency_code VARCHAR(3),              -- ISO 4217
  currency_symbol VARCHAR(5),
  locale VARCHAR(10) DEFAULT 'en',
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);
```

### D.1.2 Add `languages` table
**Current:** Not present.
**Required:**
```sql
CREATE TABLE languages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code VARCHAR(10) UNIQUE NOT NULL,      -- e.g., 'en', 'hi', 'es'
  name VARCHAR(100) NOT NULL,
  is_rtl BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true
);
```

### D.1.3 Add `user_languages` table
**Current:** Not present.
**Required:**
```sql
CREATE TABLE user_languages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id) ON DELETE CASCADE,
  language_id UUID REFERENCES languages(id),
  is_primary BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, language_id)
);
```

### D.1.4 Add `currencies` table
**Current:** Not present.
**Required:**
```sql
CREATE TABLE currencies (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code VARCHAR(3) UNIQUE NOT NULL,       -- ISO 4217
  name VARCHAR(50) NOT NULL,
  symbol VARCHAR(5),
  decimal_places SMALLINT DEFAULT 2,
  is_active BOOLEAN DEFAULT true
);
```

### D.1.5 Add `notification_templates` table
**Current:** `notifications` table exists but no template system.
**Required:**
```sql
CREATE TABLE notification_templates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type VARCHAR(50) NOT NULL,       -- 'booking_confirmed', 'payment_pending', etc.
  channel VARCHAR(20) NOT NULL,          -- 'push', 'sms', 'email', 'in_app'
  language_id UUID REFERENCES languages(id),
  subject VARCHAR(200),
  body_template TEXT NOT NULL,           -- Handlebars/template syntax
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(event_type, channel, language_id)
);
```

### D.1.6 Add `notification_logs` table
**Current:** Not present.
**Required:**
```sql
CREATE TABLE notification_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id),
  template_id UUID REFERENCES notification_templates(id),
  channel VARCHAR(20) NOT NULL,
  subject VARCHAR(200),
  body TEXT,
  status VARCHAR(20) DEFAULT 'pending',  -- pending, sent, delivered, failed
  provider_message_id VARCHAR(200),
  error_message TEXT,
  sent_at TIMESTAMPTZ,
  delivered_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);
```

### D.1.7 Add `saved_payment_methods` table
**Current:** Not present.
**Required:**
```sql
CREATE TABLE saved_payment_methods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id) ON DELETE CASCADE,
  provider VARCHAR(50) NOT NULL,         -- 'razorpay', 'payu', 'juspay'
  method_type VARCHAR(30) NOT NULL,      -- 'card', 'upi', 'netbanking'
  provider_token VARCHAR(200),           -- Tokenized reference
  display_name VARCHAR(100),             -- "HDFC **** 1234"
  metadata JSONB,                        -- masked card details, UPI ID, etc.
  is_default BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
```

### D.1.8 Add `referral_programs` and `referrals` tables
**Current:** Not present.
**Required:**
```sql
CREATE TABLE referral_programs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(100) NOT NULL,
  referrer_reward_cents INTEGER NOT NULL,
  referee_reward_cents INTEGER NOT NULL,
  max_referrals_per_user INTEGER,
  valid_from TIMESTAMPTZ,
  valid_until TIMESTAMPTZ,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE referrals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_user_id UUID REFERENCES users(id),
  referee_user_id UUID REFERENCES users(id),
  program_id UUID REFERENCES referral_programs(id),
  referral_code VARCHAR(20) NOT NULL,
  status VARCHAR(20) DEFAULT 'pending',  -- pending, qualified, rewarded
  rewarded_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(referee_user_id)
);
```

### D.1.9 Add `ratings_reviews` table
**Current:** Not present.
**Required:**
```sql
CREATE TABLE ratings_reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id),
  trip_id UUID REFERENCES trips(id),
  operator_id UUID REFERENCES operators(id),
  rating SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  review_text TEXT,
  review_audio_url TEXT,
  is_anonymous BOOLEAN DEFAULT false,
  is_approved BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);
```

### D.1.10 Add `gift_cards` table
**Current:** Not present.
**Required:**
```sql
CREATE TABLE gift_cards (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code VARCHAR(20) UNIQUE NOT NULL,
  initial_amount_cents INTEGER NOT NULL,
  balance_cents INTEGER NOT NULL,
  purchaser_user_id UUID REFERENCES users(id),
  recipient_user_id UUID REFERENCES users(id),
  recipient_email VARCHAR(200),
  recipient_phone VARCHAR(20),
  status VARCHAR(20) DEFAULT 'active',   -- active, used, expired
  valid_until TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);
```

### D.1.11 Add `feature_flags` table
**Current:** Not present.
**Required:**
```sql
CREATE TABLE feature_flags (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key VARCHAR(100) UNIQUE NOT NULL,
  description TEXT,
  is_enabled BOOLEAN DEFAULT false,
  target_countries UUID[],               -- country IDs
  target_percentage INTEGER DEFAULT 100, -- percentage rollout
  metadata JSONB,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
```

### D.1.12 Modify `operators` table
**Current:** Missing country_id.
**Required additions:**
```sql
ALTER TABLE operators ADD COLUMN country_id UUID REFERENCES countries(id);
ALTER TABLE operators ADD COLUMN default_currency_id UUID REFERENCES currencies(id);
ALTER TABLE operators ADD COLUMN logo_url TEXT;
ALTER TABLE operators ADD COLUMN website_url TEXT;
ALTER TABLE operators ADD COLUMN description TEXT;
ALTER TABLE operators ADD COLUMN rating_avg NUMERIC(3,2);
ALTER TABLE operators ADD COLUMN rating_count INTEGER DEFAULT 0;
```

### D.1.13 Modify `buses` table
**Current:** Missing photo/gallery fields.
**Required additions:**
```sql
ALTER TABLE buses ADD COLUMN photo_urls TEXT[];
ALTER TABLE buses ADD COLUMN amenities JSONB;  -- ["wifi", "charging", "blanket", ...]
ALTER TABLE buses ADD COLUMN total_seats INTEGER;
ALTER TABLE buses ADD COLUMN deck_count SMALLINT DEFAULT 1;
```

### D.1.14 Modify `trips` table
**Current:** Missing fare/currency fields.
**Required additions:**
```sql
ALTER TABLE trips ADD COLUMN currency_id UUID REFERENCES currencies(id);
ALTER TABLE trips ADD COLUMN min_fare_cents INTEGER;
ALTER TABLE trips ADD COLUMN max_fare_cents INTEGER;
ALTER TABLE trips ADD COLUMN available_seats INTEGER;
ALTER TABLE trips ADD COLUMN live_tracking_enabled BOOLEAN DEFAULT false;
ALTER TABLE trips ADD COLUMN live_tracking_url TEXT;
```

### D.1.15 Modify `bookings` table
**Current:** Missing source/device tracking.
**Required additions:**
```sql
ALTER TABLE bookings ADD COLUMN source_app VARCHAR(20);  -- 'customer', 'operator', 'admin'
ALTER TABLE bookings ADD COLUMN device_info JSONB;
ALTER TABLE bookings ADD COLUMN ip_address INET;
ALTER TABLE bookings ADD COLUMN boarding_point_name VARCHAR(200);
ALTER TABLE bookings ADD COLUMN dropping_point_name VARCHAR(200);
```

## D.2 API Contract Modifications (File 07)

### D.2.1 Add localization endpoints
```
GET /languages
GET /countries
GET /locales/{countryCode}/translations
```

### D.2.2 Add notification endpoints
```
GET /notifications
PATCH /notifications/{id}/read
PUT /notifications/preferences
GET /notifications/preferences
```

### D.2.3 Add profile management endpoints
```
GET /profile
PUT /profile
GET /profile/saved-passengers
POST /profile/saved-passengers
DELETE /profile/saved-passengers/{id}
GET /profile/saved-payment-methods
DELETE /profile/saved-payment-methods/{id}
GET /profile/gst-details
PUT /profile/gst-details
```

### D.2.4 Add wallet endpoints
```
GET /wallet/balance
GET /wallet/transactions
POST /wallet/top-up
```

### D.2.5 Add ratings/reviews endpoints
```
POST /trips/{tripId}/reviews
GET /operators/{operatorId}/reviews
```

### D.2.6 Add referral endpoints
```
GET /referrals/code
GET /referrals/history
GET /referrals/rewards
```

### D.2.7 Add deep link resolution endpoint
```
GET /deeplinks/resolve?url=
```

### D.2.8 Add admin endpoints (detailed)
```
GET /admin/operators
POST /admin/operators/{id}/approve
GET /admin/users
GET /admin/bookings
GET /admin/refunds
POST /admin/refunds/{id}/process
GET /admin/audit-logs
GET /admin/feature-flags
PUT /admin/feature-flags/{key}
GET /admin/dashboard/stats
GET /admin/reports/revenue
GET /admin/reports/bookings
```

## D.3 RBAC Modifications (File 09)

### D.3.1 Add finance role
The plan mentions finance role in refund flow but not in the RBAC matrix. Add:
- `platform_finance` — can process refunds, view financial reports, manage settlements

### D.3.2 Expand operator staff granularity
Currently "limited" is vague. Define specific permissions:
- `operator_staff` with sub-roles: `operator_booking_agent`, `operator_driver`, `operator_conductor`

## D.4 Build Order Modifications (File 14)

### D.4.1 Add internationalization step
After Step 3 (Database), add:
- **Step 3.5** — i18n framework: translation tables, locale detection, RTL support

### D.4.2 Add notification infrastructure step
After Step 4 (Authentication), add:
- **Step 4.5** — Notification infrastructure: FCM setup, template system, preferences

### D.4.3 Add analytics step
After Step 12 (QA), add:
- **Step 13** — Analytics & monitoring: event tracking, crash reporting, A/B testing framework

---

# E. Supabase Architecture

Complete Supabase-specific backend architecture replacing the PostgreSQL plan.

## E.1 Why Supabase

- Managed PostgreSQL with real-time subscriptions
- Built-in authentication (phone OTP, email, social)
- Row Level Security (RLS) built-in
- Edge Functions for custom logic
- Storage for files (PDFs, images)
- Real-time for live tracking
- Auto-generated REST API from schema
- Dashboard for admin

## E.2 Database Schema (Supabase PostgreSQL)

### E.2.1 Core Tables

All tables use UUID primary keys and `created_at`/`updated_at` timestamps.

**Identity & Auth:**
```sql
-- Extends Supabase auth.users
CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  phone VARCHAR(20) UNIQUE,
  email VARCHAR(200) UNIQUE,
  name VARCHAR(200),
  avatar_url TEXT,
  preferred_language_id UUID REFERENCES languages(id),
  preferred_currency_id UUID REFERENCES currencies(id),
  country_id UUID REFERENCES countries(id),
  status VARCHAR(20) DEFAULT 'active',
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
  role VARCHAR(30) NOT NULL,  -- 'customer', 'operator_admin', 'operator_staff', 'driver', 'conductor', 'platform_admin', 'platform_support', 'platform_finance'
  operator_id UUID REFERENCES operators(id),
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, role, operator_id)
);
```

**Operators:**
```sql
CREATE TABLE public.operators (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  legal_name VARCHAR(200) NOT NULL,
  display_name VARCHAR(200),
  registration_no VARCHAR(100),
  contact_phone VARCHAR(20),
  contact_email VARCHAR(200),
  country_id UUID REFERENCES countries(id),
  default_currency_id UUID REFERENCES currencies(id),
  logo_url TEXT,
  website_url TEXT,
  description TEXT,
  rating_avg NUMERIC(3,2) DEFAULT 0,
  rating_count INTEGER DEFAULT 0,
  settlement_config JSONB DEFAULT '{}',
  status VARCHAR(20) DEFAULT 'pending', -- pending, active, suspended, rejected
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
```

**Fleet:**
```sql
CREATE TABLE public.buses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id UUID REFERENCES operators(id) ON DELETE CASCADE,
  registration_number VARCHAR(50) NOT NULL,
  display_name VARCHAR(200),
  bus_type VARCHAR(50),       -- 'ac', 'non_ac', 'sleeper', 'seater', 'mini'
  classification VARCHAR(50), -- 'luxury', 'standard', 'economy'
  photo_urls TEXT[],
  amenities JSONB DEFAULT '[]',
  total_seats INTEGER,
  deck_count SMALLINT DEFAULT 1,
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(operator_id, registration_number)
);

CREATE TABLE public.bus_layouts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bus_id UUID REFERENCES buses(id) ON DELETE CASCADE,
  layout_name VARCHAR(100),
  version INTEGER DEFAULT 1,
  layout_json JSONB NOT NULL,  -- seat positions, deck config
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE public.seats (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bus_layout_id UUID REFERENCES bus_layouts(id) ON DELETE CASCADE,
  seat_code VARCHAR(20) NOT NULL,
  row_no SMALLINT,
  column_no SMALLINT,
  deck SMALLINT DEFAULT 1,
  seat_type VARCHAR(30),      -- 'standard', 'sleeper', 'ladies', 'premium'
  gender_rule VARCHAR(20),    -- 'any', 'female_only'
  is_active BOOLEAN DEFAULT true,
  UNIQUE(bus_layout_id, seat_code)
);
```

**Geography:**
```sql
CREATE TABLE public.countries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code VARCHAR(3) UNIQUE NOT NULL,
  name VARCHAR(100) NOT NULL,
  phone_code VARCHAR(10),
  currency_code VARCHAR(3),
  currency_symbol VARCHAR(5),
  locale VARCHAR(10) DEFAULT 'en',
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE public.cities (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  country_id UUID REFERENCES countries(id),
  name VARCHAR(200) NOT NULL,
  state VARCHAR(200),
  latitude NUMERIC(10,7),
  longitude NUMERIC(10,7),
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_cities_name ON cities USING gin(name gin_trgm_ops);
CREATE INDEX idx_cities_country ON cities(country_id);

CREATE TABLE public.routes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id UUID REFERENCES operators(id) ON DELETE CASCADE,
  source_city_id UUID REFERENCES cities(id),
  destination_city_id UUID REFERENCES cities(id),
  distance_km NUMERIC(8,2),
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(operator_id, source_city_id, destination_city_id)
);

CREATE TABLE public.boarding_points (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  route_id UUID REFERENCES routes(id) ON DELETE CASCADE,
  name VARCHAR(200) NOT NULL,
  address TEXT,
  latitude NUMERIC(10,7),
  longitude NUMERIC(10,7),
  sequence_no SMALLINT,
  is_active BOOLEAN DEFAULT true
);

CREATE TABLE public.dropping_points (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  route_id UUID REFERENCES routes(id) ON DELETE CASCADE,
  name VARCHAR(200) NOT NULL,
  address TEXT,
  latitude NUMERIC(10,7),
  longitude NUMERIC(10,7),
  sequence_no SMALLINT,
  is_active BOOLEAN DEFAULT true
);
```

**Schedule:**
```sql
CREATE TABLE public.services (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id UUID REFERENCES operators(id) ON DELETE CASCADE,
  route_id UUID REFERENCES routes(id),
  bus_id UUID REFERENCES buses(id),
  service_code VARCHAR(50),
  service_name VARCHAR(200),
  default_departure_time TIME,
  default_arrival_offset_minutes INTEGER,
  status VARCHAR(20) DEFAULT 'active',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE public.trips (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  service_id UUID REFERENCES services(id),
  operator_id UUID REFERENCES operators(id),
  route_id UUID REFERENCES routes(id),
  bus_id UUID REFERENCES buses(id),
  travel_date DATE NOT NULL,
  departure_at TIMESTAMPTZ NOT NULL,
  arrival_at TIMESTAMPTZ,
  currency_id UUID REFERENCES currencies(id),
  min_fare_cents INTEGER,
  max_fare_cents INTEGER,
  available_seats INTEGER,
  live_tracking_enabled BOOLEAN DEFAULT false,
  live_tracking_url TEXT,
  status VARCHAR(20) DEFAULT 'scheduled', -- scheduled, boarding, departed, in_transit, arrived, cancelled
  booking_open_at TIMESTAMPTZ,
  booking_close_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_trips_route_date ON trips(route_id, travel_date, status);
CREATE INDEX idx_trips_operator ON trips(operator_id, travel_date);
```

**Inventory:**
```sql
CREATE TABLE public.trip_seats (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id UUID REFERENCES trips(id) ON DELETE CASCADE,
  seat_id UUID REFERENCES seats(id),
  status VARCHAR(20) DEFAULT 'available', -- available, held, booked, blocked, cancelled, boarded
  hold_id UUID,
  booking_item_id UUID,
  passenger_id UUID,
  fare_cents INTEGER,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(trip_id, seat_id)
);
CREATE INDEX idx_trip_seats_status ON trip_seats(trip_id, status);

CREATE TABLE public.seat_holds (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id UUID REFERENCES trips(id),
  user_id UUID REFERENCES profiles(id),
  hold_token VARCHAR(100) UNIQUE NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  status VARCHAR(20) DEFAULT 'active', -- active, consumed, expired, released
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_seat_holds_expiry ON seat_holds(expires_at) WHERE status = 'active';

CREATE TABLE public.fare_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id UUID REFERENCES trips(id) ON DELETE CASCADE,
  seat_type VARCHAR(30),
  base_fare_cents INTEGER NOT NULL,
  tax_rate NUMERIC(5,4) DEFAULT 0,
  service_fee_cents INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);
```

**Bookings:**
```sql
CREATE TABLE public.passengers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_user_id UUID REFERENCES profiles(id),
  name VARCHAR(200) NOT NULL,
  age SMALLINT,
  gender VARCHAR(10),
  phone VARCHAR(20),
  id_type VARCHAR(30),
  id_number VARCHAR(100),
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE public.bookings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_reference VARCHAR(20) UNIQUE NOT NULL,
  customer_user_id UUID REFERENCES profiles(id),
  operator_id UUID REFERENCES operators(id),
  trip_id UUID REFERENCES trips(id),
  boarding_point_id UUID REFERENCES boarding_points(id),
  dropping_point_id UUID REFERENCES dropping_points(id),
  boarding_point_name VARCHAR(200),
  dropping_point_name VARCHAR(200),
  status VARCHAR(30) DEFAULT 'draft',
  source_app VARCHAR(20),  -- 'customer', 'operator', 'admin'
  currency_id UUID REFERENCES currencies(id),
  subtotal_cents INTEGER,
  tax_total_cents INTEGER,
  service_fee_total_cents INTEGER,
  discount_total_cents INTEGER,
  grand_total_cents INTEGER,
  booked_at TIMESTAMPTZ,
  device_info JSONB,
  ip_address INET,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_bookings_customer ON bookings(customer_user_id, status);
CREATE INDEX idx_bookings_trip ON bookings(trip_id, status);

CREATE TABLE public.booking_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id UUID REFERENCES bookings(id) ON DELETE CASCADE,
  trip_seat_id UUID REFERENCES trip_seats(id),
  passenger_id UUID REFERENCES passengers(id),
  base_fare_cents INTEGER,
  tax_amount_cents INTEGER,
  service_charge_cents INTEGER,
  discount_amount_cents INTEGER,
  total_amount_cents INTEGER,
  UNIQUE(booking_id, trip_seat_id)
);

CREATE TABLE public.booking_status_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id UUID REFERENCES bookings(id) ON DELETE CASCADE,
  from_status VARCHAR(30),
  to_status VARCHAR(30) NOT NULL,
  reason TEXT,
  actor_user_id UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ DEFAULT now()
);
```

**Payments:**
```sql
CREATE TABLE public.orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id UUID REFERENCES bookings(id),
  order_reference VARCHAR(50) UNIQUE NOT NULL,
  status VARCHAR(30) DEFAULT 'created',
  amount_cents INTEGER NOT NULL,
  currency_id UUID REFERENCES currencies(id),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE public.payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID REFERENCES orders(id),
  provider VARCHAR(50),          -- 'razorpay', 'payu', 'stripe'
  provider_transaction_id VARCHAR(200),
  method VARCHAR(30),            -- 'card', 'upi', 'netbanking', 'wallet'
  status VARCHAR(30) DEFAULT 'pending',
  amount_cents INTEGER NOT NULL,
  paid_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE public.refunds (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id UUID REFERENCES payments(id),
  booking_id UUID REFERENCES bookings(id),
  amount_cents INTEGER NOT NULL,
  status VARCHAR(30) DEFAULT 'pending',
  provider_reference VARCHAR(200),
  refund_type VARCHAR(20),  -- 'original_method', 'bank_neft'
  bank_details JSONB,       -- for NEFT refunds
  processed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
```

**Operations:**
```sql
CREATE TABLE public.trip_manifests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id UUID REFERENCES trips(id),
  generated_at TIMESTAMPTZ DEFAULT now(),
  generated_by UUID REFERENCES profiles(id),
  status VARCHAR(20) DEFAULT 'active'
);

CREATE TABLE public.manifest_passengers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  manifest_id UUID REFERENCES trip_manifests(id) ON DELETE CASCADE,
  booking_item_id UUID REFERENCES booking_items(id),
  boarding_status VARCHAR(20) DEFAULT 'expected', -- expected, boarded, no_show
  boarded_at TIMESTAMPTZ,
  verified_by UUID REFERENCES profiles(id)
);

CREATE TABLE public.qr_verifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id UUID,
  booking_id UUID REFERENCES bookings(id),
  verified_by UUID REFERENCES profiles(id),
  device_id VARCHAR(200),
  result VARCHAR(20),  -- 'valid', 'invalid', 'already_used', 'expired'
  reason TEXT,
  verified_at TIMESTAMPTZ DEFAULT now()
);
```

**Engagement:**
```sql
CREATE TABLE public.notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  title VARCHAR(200),
  body TEXT,
  channel VARCHAR(20),  -- 'push', 'in_app', 'sms', 'email'
  event_type VARCHAR(50),
  entity_type VARCHAR(50),
  entity_id UUID,
  is_read BOOLEAN DEFAULT false,
  metadata JSONB DEFAULT '{}',
  sent_at TIMESTAMPTZ DEFAULT now(),
  read_at TIMESTAMPTZ
);
CREATE INDEX idx_notifications_user ON notifications(user_id, is_read, sent_at DESC);

CREATE TABLE public.notification_preferences (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  event_type VARCHAR(50) NOT NULL,
  channel VARCHAR(20) NOT NULL,
  is_enabled BOOLEAN DEFAULT true,
  UNIQUE(user_id, event_type, channel)
);

CREATE TABLE public.ratings_reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES profiles(id),
  trip_id UUID REFERENCES trips(id),
  operator_id UUID REFERENCES operators(id),
  rating SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  review_text TEXT,
  is_anonymous BOOLEAN DEFAULT false,
  is_approved BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);
```

**Referrals:**
```sql
CREATE TABLE public.referral_programs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(100) NOT NULL,
  referrer_reward_cents INTEGER NOT NULL,
  referee_reward_cents INTEGER NOT NULL,
  max_referrals_per_user INTEGER,
  valid_from TIMESTAMPTZ,
  valid_until TIMESTAMPTZ,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE public.referrals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_user_id UUID REFERENCES profiles(id),
  referee_user_id UUID REFERENCES profiles(id),
  program_id UUID REFERENCES referral_programs(id),
  referral_code VARCHAR(20) NOT NULL,
  status VARCHAR(20) DEFAULT 'pending',
  rewarded_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(referee_user_id)
);
```

**Saved Payment Methods:**
```sql
CREATE TABLE public.saved_payment_methods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  provider VARCHAR(50) NOT NULL,
  method_type VARCHAR(30) NOT NULL,
  provider_token VARCHAR(200),
  display_name VARCHAR(100),
  metadata JSONB DEFAULT '{}',
  is_default BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
```

**Feature Flags:**
```sql
CREATE TABLE public.feature_flags (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key VARCHAR(100) UNIQUE NOT NULL,
  description TEXT,
  is_enabled BOOLEAN DEFAULT false,
  target_countries UUID[],
  target_percentage INTEGER DEFAULT 100,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
```

**Audit:**
```sql
CREATE TABLE public.audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_user_id UUID REFERENCES profiles(id),
  operator_id UUID REFERENCES operators(id),
  entity_type VARCHAR(50) NOT NULL,
  entity_id UUID NOT NULL,
  action VARCHAR(50) NOT NULL,
  before_json JSONB,
  after_json JSONB,
  request_id VARCHAR(100),
  ip_address INET,
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_audit_entity ON audit_logs(entity_type, entity_id);
CREATE INDEX idx_audit_actor ON audit_logs(actor_user_id, created_at DESC);
```

## E.3 Row Level Security (RLS) Policies

### E.3.1 Enable RLS on all tables
```sql
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE operators ENABLE ROW LEVEL SECURITY;
ALTER TABLE buses ENABLE ROW LEVEL SECURITY;
ALTER TABLE trips ENABLE ROW LEVEL SECURITY;
ALTER TABLE trip_seats ENABLE ROW LEVEL SECURITY;
ALTER TABLE seat_holds ENABLE ROW LEVEL SECURITY;
ALTER TABLE bookings ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE refunds ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
-- ... enable on ALL tables
```

### E.3.2 Key RLS Policies

**Profiles:**
```sql
-- Users can read/update their own profile
CREATE POLICY "Users can view own profile" ON profiles
  FOR SELECT USING (auth.uid() = id);

CREATE POLICY "Users can update own profile" ON profiles
  FOR UPDATE USING (auth.uid() = id);

-- Admin can view all profiles
CREATE POLICY "Admin can view all profiles" ON profiles
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'platform_admin')
  );
```

**Operators:**
```sql
-- Operator admins can view their own operator
CREATE POLICY "Operator admin can view own operator" ON operators
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'operator_admin' AND operator_id = operators.id)
  );

-- Public can view active operators
CREATE POLICY "Public can view active operators" ON operators
  FOR SELECT USING (status = 'active');
```

**Trips:**
```sql
-- Public can view scheduled trips (for search)
CREATE POLICY "Public can view scheduled trips" ON trips
  FOR SELECT USING (status IN ('scheduled', 'boarding'));

-- Operator can manage their own trips
CREATE POLICY "Operator can manage own trips" ON trips
  FOR ALL USING (
    EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role IN ('operator_admin', 'operator_staff') AND operator_id = trips.operator_id)
  );
```

**Trip Seats:**
```sql
-- Public can view seat availability
CREATE POLICY "Public can view seat availability" ON trip_seats
  FOR SELECT USING (true);

-- Only backend service can modify seat status (via service role key)
-- RLS for seat modifications should use service_role, not anon/authenticated
```

**Bookings:**
```sql
-- Customers can view their own bookings
CREATE POLICY "Customers can view own bookings" ON bookings
  FOR SELECT USING (customer_user_id = auth.uid());

-- Operator can view bookings for their trips
CREATE POLICY "Operator can view own trip bookings" ON bookings
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role IN ('operator_admin', 'operator_staff') AND operator_id = bookings.operator_id)
  );

-- Admin can view all bookings
CREATE POLICY "Admin can view all bookings" ON bookings
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'platform_admin')
  );
```

**Notifications:**
```sql
-- Users can view their own notifications
CREATE POLICY "Users can view own notifications" ON notifications
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "Users can update own notifications" ON notifications
  FOR UPDATE USING (user_id = auth.uid());
```

**Seat Holds:**
```sql
-- Users can view their own holds
CREATE POLICY "Users can view own holds" ON seat_holds
  FOR SELECT USING (user_id = auth.uid());
```

## E.4 Authentication Setup

### E.4.1 Supabase Auth Configuration
- Enable **Phone OTP** authentication (primary for customers)
- Enable **Email/Password** authentication (for operators)
- Enable **Google OAuth** (optional, for customers)
- Configure OTP expiry (5 minutes)
- Configure rate limiting (5 OTP per phone per hour)

### E.4.2 Auth Flow
```text
Customer:
  1. Enter phone number
  2. POST /auth/v1/otp (send OTP via Supabase)
  3. User receives SMS
  4. POST /auth/v1/verify (verify OTP)
  5. Receive JWT access_token + refresh_token
  6. JWT contains user_id, role claims

Operator:
  1. Enter email + password
  2. POST /auth/v1/token?grant_type=password
  3. Receive JWT access_token + refresh_token
  4. JWT contains user_id, role, operator_id claims
```

### E.4.3 Custom Claims via JWT
Use Supabase Edge Function to add custom claims to JWT:
```json
{
  "sub": "user-uuid",
  "role": "authenticated",
  "app_metadata": {
    "provider": "phone",
    "roles": ["customer"],
    "operator_id": null
  },
  "user_metadata": {
    "name": "John Doe",
    "phone": "+919876543210"
  }
}
```

## E.5 Edge Functions

### E.5.1 Required Edge Functions

| Function | Purpose | Trigger |
|----------|---------|---------|
| `hold-seats` | Create seat hold with TTL | HTTP request from app |
| `release-expired-holds` | Cron job to release expired holds | Supabase cron (pg_cron) |
| `create-booking` | Convert hold to confirmed booking | HTTP request |
| `process-payment` | Initiate payment with provider | HTTP request |
| `handle-payment-webhook` | Process payment provider callbacks | HTTP request |
| `confirm-booking` | Finalize booking after payment success | Called by webhook handler |
| `cancel-booking` | Process cancellation + refund | HTTP request |
| `generate-manifest` | Create boarding manifest for trip | HTTP request |
| `verify-qr` | Validate QR code for boarding | HTTP request |
| `send-notification` | Dispatch push/SMS/email notifications | Called by other functions |
| `resolve-deeplink` | Resolve deep link URLs | HTTP request |
| `generate-pdf-ticket` | Generate PDF ticket for download | HTTP request |
| `process-refund` | Initiate refund to payment provider | Called by cancel function |
| `cleanup-expired-seats` | Cron: release expired holds | pg_cron every minute |

### E.5.2 Edge Function: hold-seats (Pseudocode)
```typescript
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

serve(async (req) => {
  const { tripId, seatIds, ttlSeconds = 300 } = await req.json()
  const supabase = createClient(DENO_URL, SERVICE_ROLE_KEY)

  // 1. Begin transaction
  // 2. SELECT trip_seats WHERE trip_id = ? AND seat_id IN (?) FOR UPDATE
  // 3. Verify all seats are AVAILABLE or expired HELD
  // 4. Create seat_hold record with expiry
  // 5. UPDATE trip_seats SET status = 'held', hold_id = ?
  // 6. Return hold token + expiry

  const { data: hold, error } = await supabase.rpc('create_seat_hold', {
    p_trip_id: tripId,
    p_seat_ids: seatIds,
    p_ttl_seconds: ttlSeconds
  })

  return new Response(JSON.stringify(hold), {
    headers: { 'Content-Type': 'application/json' }
  })
})
```

### E.5.3 Database Function: create_seat_hold (PL/pgSQL)
```sql
CREATE OR REPLACE FUNCTION create_seat_hold(
  p_trip_id UUID,
  p_seat_ids UUID[],
  p_ttl_seconds INTEGER DEFAULT 300
) RETURNS JSONB AS $$
DECLARE
  v_hold_id UUID;
  v_hold_token VARCHAR(100);
  v_expires_at TIMESTAMPTZ;
  v_seat RECORD;
  v_available_count INTEGER := 0;
  v_result JSONB;
BEGIN
  -- Generate hold token
  v_hold_token := encode(gen_random_bytes(24), 'hex');
  v_expires_at := now() + (p_ttl_seconds || ' seconds')::INTERVAL;

  -- Lock and check seats
  FOR v_seat IN
    SELECT ts.id, ts.status, ts.hold_id
    FROM trip_seats ts
    WHERE ts.trip_id = p_trip_id
    AND ts.seat_id = ANY(p_seat_ids)
    FOR UPDATE OF ts
  LOOP
    IF v_seat.status = 'available' THEN
      v_available_count := v_available_count + 1;
    ELSIF v_seat.status = 'held' THEN
      -- Check if hold is expired
      IF EXISTS (
        SELECT 1 FROM seat_holds sh
        WHERE sh.id = v_seat.hold_id
        AND sh.expires_at < now()
        AND sh.status = 'active'
      ) THEN
        v_available_count := v_available_count + 1;
      ELSE
        RAISE EXCEPTION 'Seat is held by another user';
      END IF;
    ELSE
      RAISE EXCEPTION 'Seat is not available: %', v_seat.status;
    END IF;
  END LOOP;

  -- Verify all requested seats are available
  IF v_available_count != array_length(p_seat_ids, 1) THEN
    RAISE EXCEPTION 'Not all seats are available';
  END IF;

  -- Create hold record
  INSERT INTO seat_holds (trip_id, user_id, hold_token, expires_at, status)
  VALUES (p_trip_id, auth.uid(), v_hold_token, v_expires_at, 'active')
  RETURNING id INTO v_hold_id;

  -- Update seat statuses
  UPDATE trip_seats
  SET status = 'held',
      hold_id = v_hold_id,
      updated_at = now()
  WHERE trip_id = p_trip_id
  AND seat_id = ANY(p_seat_ids);

  -- Return result
  v_result := jsonb_build_object(
    'hold_id', v_hold_id,
    'hold_token', v_hold_token,
    'expires_at', v_expires_at,
    'seat_ids', p_seat_ids
  );

  RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

## E.6 Storage Buckets

| Bucket | Purpose | Access |
|--------|---------|--------|
| `bus-photos` | Bus exterior/interior images | Public read, operator write |
| `operator-logos` | Operator company logos | Public read, admin write |
| `user-avatars` | User profile pictures | Public read, owner write |
| `ticket-pdfs` | Generated PDF tickets | Auth read (own bookings), system write |
| `receipts` | Payment receipts | Auth read (own), system write |
| `support-attachments` | Support ticket attachments | Auth write (own), admin read |
| `city-images` | City/destination images | Public read, admin write |

## E.7 Real-Time Subscriptions

Use Supabase Real-Time for:

| Subscription | Table | Purpose |
|-------------|-------|---------|
| Seat availability | `trip_seats` | Live seat map updates |
| Booking status | `bookings` | Customer sees status changes |
| Trip status | `trips` | Operator sees trip state |
| Live tracking | Custom channel | Bus location updates |
| Notifications | `notifications` | Real-time notification delivery |
| Manifest updates | `manifest_passengers` | Operator sees boarding status |

## E.8 pg_cron Jobs

| Job | Schedule | Purpose |
|-----|----------|---------|
| `release-expired-holds` | Every 1 minute | `UPDATE seat_holds SET status = 'expired' WHERE status = 'active' AND expires_at < now()` |
| `cleanup-held-seats` | Every 1 minute | `UPDATE trip_seats SET status = 'available', hold_id = NULL WHERE status = 'held' AND hold_id IN (SELECT id FROM seat_holds WHERE status = 'expired')` |
| `close-booking-window` | Every 5 minutes | `UPDATE trips SET status = 'boarding' WHERE status = 'scheduled' AND booking_close_at < now()` |
| `daily-trip-status` | Every 1 hour | Update trip statuses based on departure/arrival times |

## E.9 External APIs Still Needed

Even with Supabase, these external services are required:

| Service | Purpose | Provider Options |
|---------|---------|-----------------|
| Payment Gateway | Process payments | Razorpay, PayU, Stripe |
| SMS Provider | Send OTPs (Supabase has built-in, but may need backup) | Twilio, MSG91, Gupshup |
| Push Notifications | FCM delivery | Firebase Admin SDK via Edge Functions |
| Maps | Location display, routing | **Custom GPS coordinate matching (free)** — match live lat/long with predefined boarding/dropping point coordinates to detect station arrival; no external map API required |
| PDF Generation | Ticket PDFs | Puppeteer in Edge Function, or external API |
| Email | Booking confirmations | SendGrid, Resend |
| Analytics | Event tracking | PostHog, Mixpanel, or custom |
| Crash Reporting | Error monitoring | Sentry |

---

# F. Final Development Plan

Step-by-step implementation plan for AI coding agent.

## Phase 1: Project Setup (Day 1-2)

### Step 1.1: Initialize Monorepo
```
thirty8/
├── apps/
│   ├── customer_app/          # Flutter (Dart)
│   ├── operator_app/          # Flutter (Dart)
│   └── admin_web/             # Next.js or React
├── supabase/
│   ├── migrations/            # SQL migration files
│   ├── functions/             # Edge Functions (TypeScript/Deno)
│   ├── seed/                  # Seed data
│   └── config.toml            # Supabase configuration
├── packages/
│   ├── shared_types/          # Shared TypeScript/Dart types
│   └── ui_kit/                # Shared UI components
├── docs/
└── README.md
```

### Step 1.2: Create Supabase Project
- Initialize Supabase project
- Set up environment variables
- Configure auth providers (phone OTP, email)
- Create storage buckets

### Step 1.3: Database Migrations
Create migration files in order:
1. `001_countries_languages_currencies.sql`
2. `002_profiles_user_roles.sql`
3. `003_operators.sql`
4. `004_buses_bus_layouts_seats.sql`
5. `005_cities_routes_boarding_dropping.sql`
6. `006_services_trips.sql`
7. `007_trip_seats_seat_holds_fare_rules.sql`
8. `008_passengers_bookings_booking_items.sql`
9. `009_orders_payments_refunds.sql`
10. `010_trip_manifests_manifest_passengers_qr.sql`
11. `011_notifications_notification_preferences.sql`
12. `012_ratings_reviews_referrals.sql`
13. `013_saved_payment_methods_feature_flags.sql`
14. `014_audit_logs.sql`
15. `015_rls_policies.sql`
16. `016_indexes.sql`
17. `017_database_functions.sql` (seat hold, booking creation, etc.)
18. `018_triggers.sql` (updated_at, audit logging)
19. `019_seed_data.sql` (countries, cities, languages, currencies)

### Step 1.4: Seed Data
- Insert countries (India, Indonesia, Cambodia, Malaysia, Peru, Singapore, Vietnam, Colombia)
- Insert languages (29 locales)
- Insert currencies
- Insert sample cities per country
- Insert sample operator with buses, routes, services, trips
- Insert sample seat layouts

## Phase 2: Authentication (Day 3-4)

### Step 2.1: Supabase Auth Setup
- Configure phone OTP provider
- Configure email/password for operators
- Set up JWT claims with role and operator_id
- Create `auth_hooks` Edge Function for custom claims

### Step 2.2: Customer Auth Flow
- Phone number input screen
- OTP send via Supabase `auth.signInWithOtp({ phone })`
- OTP verification screen
- Auto-read SMS (Android SMS Retriever API)
- Session management (token refresh)
- Skip login option (browse-only mode)

### Step 2.3: Operator Auth Flow
- Email + password login
- Password reset flow
- Session management
- Multi-device handling

### Step 2.4: Profile Creation
- On first login, create profile in `profiles` table
- Assign `customer` role via trigger or Edge Function
- On operator signup, create profile + assign `operator_admin` role

## Phase 3: Core Backend (Day 5-10)

### Step 3.1: Edge Functions — Seat Hold & Release
- `hold-seats` function with PL/pgSQL
- `release-expired-holds` via pg_cron
- Concurrency handling with SELECT FOR UPDATE
- TTL enforcement

### Step 3.2: Edge Functions — Booking Flow
- `create-booking` — convert hold to booking
- `confirm-booking` — after payment success
- `cancel-booking` — with refund logic
- Idempotency for all mutations

### Step 3.3: Edge Functions — Payment Integration
- `process-payment` — initiate with provider
- `handle-payment-webhook` — receive callbacks
- Payment adapter pattern (Razorpay/PayU/Stripe)
- Idempotent webhook processing

### Step 3.4: Edge Functions — Search
- City autocomplete (trigram search)
- Route search
- Trip search with filters
- Seat availability in search results

### Step 3.5: Edge Functions — Operator Operations
- `generate-manifest` — create boarding manifest
- `verify-qr` — validate ticket QR
- `mark-boarded` — update passenger boarding status
- Operator trip management CRUD

### Step 3.6: Edge Functions — Notifications
- Push notification dispatch (FCM)
- Notification template rendering
- Notification preferences enforcement
- Notification logging

### Step 3.7: Edge Functions — PDF Generation
- PDF ticket template
- Generate PDF with booking details + QR code
- Store in Supabase Storage
- Return download URL

## Phase 4: Customer App (Day 11-25)

### Step 4.1: Flutter Project Setup
- Initialize Flutter project
- Set up Supabase Flutter SDK
- Configure routing (GoRouter or similar)
- Set up state management (Riverpod or Bloc)
- Create theme/design system

### Step 4.2: Home Screen
- Search widget (source, destination, date)
- Promo/offer banners
- Recent trips
- Upcoming trips
- Top destinations
- Language switcher

### Step 4.3: Search Flow
- City picker (autocomplete, recent, popular)
- Date picker (calendar)
- Search results page (SRP)
- Filters (bus type, departure time, amenities, price)
- Sort (price, time, rating, duration)
- Empty/error states

### Step 4.4: Bus Details & Seat Selection
- Bus details screen (operator info, amenities, photos, ratings)
- Route map with stops
- Boarding/dropping point selection (with map)
- Seat layout/map
- Seat legend
- Multi-seat selection
- Fare calculation
- Cancellation policy display

### Step 4.5: Seat Lock & Checkout
- Seat hold countdown timer
- Hold info display
- Passenger details form (primary + co-passengers)
- Saved passenger selection
- Fare breakup
- Coupon/offer code
- GST details (optional)
- Payment method selection

### Step 4.6: Payment
- Order creation
- Payment SDK integration (Razorpay/PayU)
- UPI flow
- Card flow
- Netbanking flow
- Wallet balance display
- Payment processing state
- Payment success/failure handling
- Retry on failure

### Step 4.7: Post-Booking
- Booking confirmation screen
- Ticket summary
- QR code display
- PDF download
- Share ticket
- Boarding pass

### Step 4.8: My Trips
- Upcoming trips tab
- Active trips tab
- Completed trips tab
- Cancelled trips tab
- Booking detail screen
- Trip status

### Step 4.9: Cancellation & Refund
- Cancellation preview (refund amount)
- Cancellation policy display
- Partial cancellation (per passenger)
- Cancellation confirmation
- Refund status tracking
- Bank NEFT refund option

### Step 4.10: Live Tracking (Bus Buddy)
- Live map with bus location
- ETA display
- Boarding point navigation
- Round-trip booking from tracking

### Step 4.11: Profile & Account
- Profile view/edit
- Saved passengers management
- Saved payment methods
- Wallet balance & transactions
- GST details
- Refund bank accounts
- Language preference
- Notification preferences
- Account settings
- About us
- Logout

### Step 4.12: Notifications
- In-app notification center
- Push notification handling
- Notification preferences screen
- Deep link handling from notifications

### Step 4.13: Referral & Rewards
- Referral code display
- Share referral code
- Referral history
- Rewards/credits display

### Step 4.14: Ratings & Reviews
- Post-trip rating screen
- Review submission
- View operator ratings

### Step 4.15: Localization
- i18n framework setup
- String translation files (at minimum: English, Hindi, Spanish)
- RTL support preparation
- Locale-aware date/time/number formatting

## Phase 5: Operator App (Day 26-35)

### Step 5.1: Flutter Project Setup
- Initialize operator Flutter project
- Supabase integration
- Auth flow (email/password)
- Navigation (drawer-based)

### Step 5.2: Dashboard
- Home screen with today's trips
- Quick stats (bookings, revenue, seats filled)
- Navigation drawer

### Step 5.3: Fleet Management
- Bus listing
- Bus details
- Seat layout editor
- Amenities configuration
- Bus photo upload

### Step 5.4: Route & Service Management
- Route creation/editing
- Boarding/dropping point management
- Service (schedule) creation
- Trip scheduling (date-based)
- Recurring schedule support

### Step 5.5: Trip Operations
- Today's trips list
- Trip detail view
- Seat inventory view
- Boarding chart
- Passenger manifest

### Step 5.6: Booking
- Search services
- Regular booking flow
- Quick booking dialog
- Passenger details entry
- Fare computation
- Payment collection (cash/wallet)
- Ticket issuance

### Step 5.7: Manifest & Boarding
- Generate manifest
- Driver manifest (simplified)
- Print manifest
- Boarding/dropping point view
- Mark passenger boarded
- No-show handling

### Step 5.8: QR Scanning
- Camera-based QR scanner
- Verify ticket validity
- Mark as boarded on scan
- Handle invalid/expired/already-used QR

### Step 5.9: Ticket Printing
- Printer integration (Bluetooth/thermal)
- Print layout configuration
- Print preview
- Print options

### Step 5.10: Financial
- Wallet balance
- Transaction statements
- Trip-level revenue
- Settlement history

### Step 5.11: Profile & Settings
- Operator profile management
- Staff management
- Language selection
- Onboarding tutorial

## Phase 6: Admin Web Panel (Day 36-42)

### Step 6.1: Project Setup
- Next.js/React project
- Supabase JS client
- Auth (email/password)
- Layout (sidebar navigation)

### Step 6.2: Dashboard
- KPI cards (total bookings, revenue, active operators, etc.)
- Revenue chart
- Booking trend chart
- Recent activity feed

### Step 6.3: Operator Management
- Operator listing
- Operator approval workflow
- Operator details view
- Suspend/activate operators
- View operator fleet

### Step 6.4: User Management
- User listing
- User details
- Role management
- Account suspension

### Step 6.5: Trip & Booking Oversight
- Trip listing with filters
- Booking listing with filters
- Booking detail view
- Refund processing

### Step 6.6: Financial
- Revenue reports
- Refund queue
- Settlement tracking
- Payment reconciliation

### Step 6.7: Content Management
- City management
- Route management
- Feature flag management
- Notification template management

### Step 6.8: Audit & Support
- Audit log viewer
- Support case management
- System configuration

## Phase 7: Testing & QA (Day 43-50)

### Step 7.1: Unit Tests
- Seat hold/release logic
- Booking state transitions
- Payment idempotency
- Cancellation/refund calculation
- RLS policy verification

### Step 7.2: Integration Tests
- End-to-end booking flow
- Concurrent seat booking (race condition)
- Payment webhook handling
- QR verification flow
- Operator booking flow

### Step 7.3: E2E Tests
- Customer: search → select → hold → pay → ticket
- Operator: login → manage fleet → create trip → book → manifest → board
- Admin: approve operator → monitor bookings → process refunds

### Step 7.4: Security Tests
- RLS bypass attempts
- Operator isolation verification
- Payment amount tampering
- QR replay attacks
- Authentication bypass attempts

### Step 7.5: Performance Tests
- Seat hold concurrency (100+ simultaneous users)
- Search performance with large datasets
- API response time benchmarks
- Database query optimization

## Phase 8: Deployment (Day 51-55)

### Step 8.1: Supabase Production Setup
- Production Supabase project
- Configure all RLS policies
- Set up Edge Functions
- Configure storage buckets
- Set up pg_cron jobs
- Configure auth settings

### Step 8.2: CI/CD Pipeline
- GitHub Actions for migrations
- Automated testing on PR
- Deploy Edge Functions
- Build and deploy Flutter apps
- Deploy admin web

### Step 8.3: Monitoring
- Supabase Dashboard monitoring
- Error tracking (Sentry)
- Analytics setup
- Uptime monitoring

---

# G. Pre-Build Checklist

Final checklist confirming all APK functionality has been accounted for.

## G.1 Customer App Checklist

| # | Feature | APK Evidence | Plan Coverage | Status |
|---|---------|-------------|---------------|--------|
| 1 | Phone/OTP authentication | C-AUTH-01 to C-AUTH-08 | Phase 2 | COVERED |
| 2 | Google/Email login | C-AUTH-09 | Phase 2 (optional) | COVERED |
| 3 | Biometric auth | C-AUTH-10 | Not planned | NEEDS DECISION |
| 4 | Onboarding tutorial | C-AUTH-11 | Phase 4.1 | COVERED |
| 5 | Home screen with search | C-HOME-01 | Phase 4.2 | COVERED |
| 6 | Promo/offers | C-HOME-02 | Phase 4.2 | COVERED |
| 7 | Recent/upcoming trips | C-HOME-03, C-HOME-04 | Phase 4.2 | COVERED |
| 8 | Preferred routes | C-HOME-05 | Phase 4.2 | COVERED |
| 9 | Resume booking | C-HOME-06 | Not planned | MISSING |
| 10 | Payment reminder | C-HOME-07 | Phase 3.6 | COVERED |
| 11 | Refund status display | C-HOME-08 | Phase 4.9 | COVERED |
| 12 | Refer & earn | C-HOME-09 | Phase 4.13 | COVERED |
| 13 | Language switch | C-HOME-10 | Phase 4.15 | COVERED |
| 14 | Top destinations | C-HOME-11 | Phase 4.2 | COVERED |
| 15 | RTC government buses | C-HOME-12 | Not planned | NEEDS DECISION |
| 16 | Multi-country support | C-HOME-13 | Phase 1 (countries table) | COVERED |
| 17 | City/location picker | C-SRCH-01 | Phase 4.3 | COVERED |
| 18 | Date selector | C-SRCH-02 | Phase 4.3 | COVERED |
| 19 | Search results | C-SRCH-03 | Phase 4.3 | COVERED |
| 20 | Alternate dates/routes | C-SRCH-04 | Phase 4.3 | COVERED |
| 21 | Filters | C-SRCH-05 | Phase 4.3 | COVERED |
| 22 | Sort | C-SRCH-06 | Phase 4.3 | COVERED |
| 23 | Empty/error states | C-SRCH-07 | Phase 4.3 | COVERED |
| 24 | Bus details screen | C-BUS-01 to C-BUS-13 | Phase 4.4 | COVERED |
| 25 | Seat layout/map | C-BUS-05 to C-BUS-10 | Phase 4.4 | COVERED |
| 26 | Seat lock with countdown | C-LOCK-01 to C-LOCK-08 | Phase 3.1, 4.5 | COVERED |
| 27 | Passenger details | C-PASS-01 to C-PASS-09 | Phase 4.5 | COVERED |
| 28 | Payment (UPI, cards, wallet) | C-PAY-01 to C-PAY-15 | Phase 3.3, 4.6 | COVERED |
| 29 | PDF ticket download | C-TICK-07 | Phase 3.7 | COVERED |
| 30 | QR ticket | C-TICK-03 | Phase 4.7 | COVERED |
| 31 | My Trips | C-TRIP-01 to C-TRIP-07 | Phase 4.8 | COVERED |
| 32 | Cancellation & refund | C-CANC-01 to C-CANC-09 | Phase 3.4, 4.9 | COVERED |
| 33 | Live tracking | C-TRCK-01 to C-TRCK-07 | Phase 4.10 | COVERED |
| 34 | Profile management | C-PROF-01 to C-PROF-11 | Phase 4.11 | COVERED |
| 35 | Wallet | C-WALT-01 to C-WALT-05 | Phase 4.11 | COVERED |
| 36 | Gamification/streaks | C-WALT-06 to C-WALT-08 | Not planned | NEEDS DECISION |
| 37 | Push notifications | C-NOTI-01 to C-NOTI-07 | Phase 3.6, 4.12 | COVERED |
| 38 | Ratings & reviews | C-EXTR-12 | Phase 4.14 | COVERED |
| 39 | Deep linking | C-EXTR-13 | Phase 3.5 | COVERED |
| 40 | Multi-language (29 locales) | C-EXTR-18 | Phase 4.15 | COVERED (min) |
| 41 | ONDC Auto (ride-hailing) | C-EXTR-01 | Not planned | OUT OF SCOPE |
| 42 | Hotels | C-EXTR-02 | Not planned | OUT OF SCOPE |
| 43 | City Bus (ONDC) | C-EXTR-03 | Not planned | OUT OF SCOPE |
| 44 | Rail pass | C-EXTR-04 | Not planned | OUT OF SCOPE |
| 45 | Things to Do | C-EXTR-05 | Not planned | OUT OF SCOPE |
| 46 | Gift cards | C-EXTR-06 | Not planned | NEEDS DECISION |
| 47 | RedTV (video) | C-EXTR-07 | Not planned | OUT OF SCOPE |
| 48 | KOL videos | C-EXTR-08 | Not planned | OUT OF SCOPE |
| 49 | Group chat | C-EXTR-09 | Not planned | OUT OF SCOPE |
| 50 | Voice AI (Vani) | C-EXTR-10 | Not planned | OUT OF SCOPE |
| 51 | Panorama view | C-EXTR-11 | Not planned | OUT OF SCOPE |
| 52 | WebView | C-EXTR-14 | Phase 4 (Flutter WebView) | COVERED |
| 53 | Wearable support | C-EXTR-15 | Not planned | OUT OF SCOPE |
| 54 | Screen capture detection | C-EXTR-16 | Not planned | NEEDS DECISION |

## G.2 Operator App Checklist

| # | Feature | APK Evidence | Plan Coverage | Status |
|---|---------|-------------|---------------|--------|
| 1 | Login/signup | O-AUTH-01 to O-AUTH-06 | Phase 2.3 | COVERED |
| 2 | Onboarding | O-AUTH-04 | Phase 5.11 | COVERED |
| 3 | Dashboard | O-HOME-01 to O-HOME-03 | Phase 5.2 | COVERED |
| 4 | Service/search | O-SVC-01 to O-SVC-04 | Phase 5.3, 5.4 | COVERED |
| 5 | Seat selection | O-BKNG-01, O-BKNG-02 | Phase 5.6 | COVERED |
| 6 | Quick booking | O-BKNG-03 | Phase 5.6 | COVERED |
| 7 | Passenger details | O-BKNG-04 | Phase 5.6 | COVERED |
| 8 | Booking history | O-BKNG-05 | Phase 5.5 | COVERED |
| 9 | Boarding/dropping | O-BKNG-06 | Phase 5.4 | COVERED |
| 10 | Ticket view | O-TICK-01 | Phase 5.6 | COVERED |
| 11 | Generate manifest | O-TICK-02 | Phase 5.7 | COVERED |
| 12 | Driver manifest | O-TICK-03 | Phase 5.7 | COVERED |
| 13 | Print ticket | O-TICK-05, O-TICK-06 | Phase 5.9 | COVERED |
| 14 | QR scanner | O-TICK-07 | Phase 5.8 | COVERED |
| 15 | Cancellation | O-TICK-08 | Phase 5.6 | COVERED |
| 16 | Wallet/statements | O-FIN-01, O-FIN-02 | Phase 5.10 | COVERED |
| 17 | Multi-deck view | O-EXTR-01 | Phase 5.5 | COVERED |

## G.3 Infrastructure Checklist

| # | Feature | Coverage | Status |
|---|---------|----------|--------|
| 1 | Supabase auth (OTP, email) | Phase 2 | COVERED |
| 2 | RLS policies | Phase 1 (migration 15) | COVERED |
| 3 | Edge Functions | Phase 3 | COVERED |
| 4 | Storage buckets | Phase 1.2 | COVERED |
| 5 | Real-time subscriptions | Phase 4.8 (live tracking) | COVERED |
| 6 | pg_cron jobs | Phase 1 (migration) | COVERED |
| 7 | Payment gateway integration | Phase 3.3 | COVERED |
| 8 | Push notifications (FCM) | Phase 3.6 | COVERED |
| 9 | PDF generation | Phase 3.7 | COVERED |
| 10 | Analytics/tracking | Not planned | MISSING |
| 11 | Crash reporting | Not planned | MISSING |
| 12 | A/B testing | Not planned | MISSING |
| 13 | Rate limiting | Not planned | NEEDS ADDITION |
| 14 | CORS configuration | Not planned | NEEDS ADDITION |
| 15 | API versioning | Phase 3 (v1) | COVERED |

## G.4 Items Marked as OUT OF SCOPE

These redBus features are present in the APK but should NOT be built for Thirty8 MVP:

1. **ONDC Auto (ride-hailing)** — Different business domain
2. **Hotels** — Different business domain
3. **City Bus (ONDC)** — Different business domain
4. **Rail pass** — Different business domain
5. **Things to Do (activities)** — Different business domain
6. **RedTV (video content)** — Content platform, not core booking
7. **KOL videos** — Content platform
8. **Group chat** — Advanced social feature
9. **Voice AI (Vani)** — Advanced AI feature
10. **Panorama view** — Nice-to-have visual feature
11. **Wearable support** — Niche platform
12. **Simpl (BNPL)** — Payment provider specific, can add later

## G.5 Items Marked as NEEDS DECISION

These require project owner input before development:

1. **Biometric auth** — Do you want app lock with fingerprint/face? (Adds security layer)
2. **Resume booking** — Should incomplete bookings be recoverable? (Medium complexity)
3. **RTC government buses** — Are you targeting government bus operators? (Adds complexity)
4. **Gamification/streaks** — Engagement features? (Can be Phase 2)
5. **Gift cards** — Do you want gift card support? (Adds payment complexity)
6. **Screen capture detection** — Security feature to prevent ticket screenshots? (Low priority)
7. **Analytics provider** — Which analytics platform? (PostHog, Mixpanel, custom?)
8. **Minimum language support** — Which languages for MVP? (Recommend: English + Hindi + 1 other)

## G.6 Items Marked as MISSING (Need to Add)

1. ~~Analytics/event tracking~~ → Added to Phase 7
2. ~~Crash reporting~~ → Added to Phase 7 (Sentry)
3. ~~Rate limiting~~ → Add to Edge Functions (Supabase has built-in)
4. ~~CORS configuration~~ → Add to Supabase config
5. ~~Resume booking~~ → Add to Phase 4.2 (NEEDS DECISION)
6. ~~Biometric auth~~ → Add to Phase 2 (NEEDS DECISION)
7. ~~i18n framework~~ → Added to Phase 4.15
8. ~~Push notification infrastructure~~ → Added to Phase 3.6
9. ~~PDF generation~~ → Added to Phase 3.7
10. ~~Saved payment methods~~ → Added to schema + Phase 4.6

---

# Appendix: Key Differences from Original Plan

| Area | Original Plan | Revised Plan |
|------|--------------|-------------|
| Database | PostgreSQL generic | Supabase PostgreSQL with Edge Functions |
| Auth | Custom JWT/session | Supabase Auth (phone OTP + email) |
| API | Custom REST server | Supabase auto-generated + Edge Functions |
| Real-time | Not specified | Supabase Real-Time subscriptions |
| Storage | Not specified | Supabase Storage buckets |
| Cron jobs | Not specified | pg_cron for hold expiration |
| File hosting | Not specified | Supabase Storage |
| Multi-country | Not addressed | Full multi-market support |
| i18n | Not addressed | 29-locale framework |
| Push notifications | Not addressed | FCM via Edge Functions |
| PDF generation | Not addressed | Server-side PDF generation |
| Admin panel | Generic web | Next.js with Supabase client |
| Monitoring | Not addressed | Sentry + Supabase Dashboard |
| RLS | Not addressed | Comprehensive RLS policies |
| Seed data | Not addressed | Multi-country seed data |

---

**END OF AUDIT**

*This document is implementation-ready. Give it directly to an AI coding agent to begin Phase 1.*
