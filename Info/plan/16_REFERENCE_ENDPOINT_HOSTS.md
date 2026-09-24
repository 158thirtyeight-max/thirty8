# 16 — Reference Network Host Evidence (Customer APK)

The customer client contains numerous embedded URL strings. They are evidence of client dependencies, not authorization to call or reproduce the reference company's private services.

## Major observed redBus hosts

- `capi.redbus.com`
- `capipp.redbus.com`
- `bhapi.redbus.in`
- `csapi.redbus.in`
- `btiapipub.redbus.com`
- `redpay`-related host paths
- `ai2.redbus.com`
- `loco.redbus.com`
- `radium.redbus.com`
- `ridespp.redbus.in`
- `tracking.yourbus.in`
- `reports.yourbus.in`
- `rbnow.yourbus.in`
- `st.redbus.in`
- `s3.rdbuz.com`

## Example client paths observed

- `/api/Bus/v1/GetFullURL/`
- `/api/OfferAPI/v2/GetAllActiveOffersWithTiles`
- `/api/Payment/v1/InitiateKredivoPlan`
- `/api/ScratchCard/v1/fetchScratchCard`
- `/api/refundStatus/details`
- `/rbMaps/api/directions`
- `/rbMaps/api/distancematrix`
- `/rbMaps/api/geocode/address`
- `/rbMaps/api/place/autocomplete`
- `/rbMaps/api/reversegeocode`
- `/rbtracker/client/api/auth/fb_refresh_token`
- `/rbtracker/client/api/trip/get_subscr_node`
- `/rbtracker/client/api/trip/get_trip_device_node`
- `/redpay/api/`
- `/xp/v1/`
- `/openticket/api/`
- `/rides/`

## Security note

For Thirty8, do **not** point production code at these services. Use an independent Thirty8 API namespace and provider integrations.
