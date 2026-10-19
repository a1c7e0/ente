# Locker shared storage experiment

`feat/locker-shared-storage` changes Locker to share the Photos account's byte
quota. It remains independent of `main` and the ML experiment branches.

## Behavior

- Photos and Locker uploads consume the same subscription, eligible storage
  bonuses, and active family storage pool. A family member's individual storage
  cap also applies. The existing upload overhead allowance remains unchanged;
  usage displays show nominal quota, not that allowance.
- Locker has no enforced 100/1,000-item quota or independent 1/10 GiB total quota.
  Item counts are still tracked for statistics and older clients. The Web
  client's existing 10 GiB limit on a single uploaded file remains.
- Photos account usage includes Locker bytes; Locker shows the shared byte
  usage and quota instead of an item-count allowance.
- Accounting uses the existing `usage.storage_consumed` ledger, including file
  and thumbnail objects. Metadata-only notes and credentials still contribute
  zero file-storage bytes, consistent with existing accounting. This change
  does not introduce a database-metadata charge.

## Compatibility and rollout

Deploy the server and use Locker clients built from this branch. The server
advertises `lockerQuotaMode: "sharedStorage"` in `/users/details/v2` and
`quotaMode: "sharedStorage"` in `/users/locker-usage`. Updated clients keep the
legacy quota behavior when those fields are absent or unsupported, including
when connected to the official service.

Older Locker clients can connect but retain their own item-count checks and
usage presentation. Updating the server alone cannot remove those client-side
checks. Existing Photos clients can display the server's combined byte usage.

No database migration, re-upload, or usage backfill is needed: Locker object
bytes are already in the shared ledger. Existing Locker data now counts against
the Photos allowance, so accounts near the limit may need more space before
uploading again. This does not delete existing data. Storage is released through
the existing trash and permanent-deletion lifecycle.

## Development and verification

Reuse the existing server and Locker workflows. This branch does not enable
new package publishing, deployment, or automatic APK builds.

- Server: run `./scripts/test-with-postgres.sh docker` from `server/` for the
  normal disposable PostgreSQL test suite. Focused regressions live in
  `pkg/controller/usage_shared_storage_test.go` and
  `pkg/controller/user/locker_usage_integration_test.go`.
- Web: run `npm run test --workspace locker` from `web/`; quota preflight
  regressions live in `apps/locker/tests/locker-limits.test.ts`.
- Mobile: run `flutter test test/models/user_details_test.dart` from
  `mobile/packages/accounts/`. Generate the standard Locker Rust bindings
  before analyzing or building the complete Locker app.
