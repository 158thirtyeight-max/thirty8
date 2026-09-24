# 11 — What Can and Cannot Be Recovered from an APK

## Recoverable / observable

- package identity
- version metadata
- permissions
- activities/components when not hidden by obfuscation
- layout resources
- images/icons stored in app package
- strings
- many class/package names
- client-side data models
- local DB/Room/DataStore usage
- embedded domain hostnames and endpoint strings
- feature flags/configuration references
- navigation/deep-link classes
- analytics/library integrations
- client-side state-management patterns

## Often partially recoverable

- API paths
- request/response field names
- model relationships
- error-state handling
- business rules encoded in client logic
- feature toggles

## Usually NOT recoverable from APK alone

- complete production database schema
- server source code
- backend controllers/services
- database triggers and stored procedures
- server-only authorization rules
- private signing keys
- payment gateway secrets
- admin credentials
- production user data
- server-side fraud/risk rules
- internal operator settlement logic if only server-side

## Correct Thirty8 approach

Where redBus backend behavior is unknown:

1. record the observable client requirement
2. infer the minimum business contract necessary
3. design an independent Thirty8 API
4. implement robust server-side rules
5. mark the decision `PROPOSED`
6. cover it with tests

Never invent an "observed redBus database table" merely because a client object exists.
