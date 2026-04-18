# BUCK-only minimal-risk patch terv (végrehajtható első patch)

> Megjegyzés: a `native/zcash-sync` submodule tartalma ebben a környezetben nem volt lehúzható (GitHub 403), ezért a terv a megadott fájlok és felelősségi körök alapján készült, diff-szintű, kézzel átírható javaslatokkal.

## Cél és guardrail

- **Csak BUCK-ra** vonatkozik a viselkedésváltozás.
- Nincs DB schema törés.
- Nincs FlatBuffer/FFI ABI törés.
- Nincs Orchard kódtörlés (csak BUCK path bypass / tiltás).

---

## 1) Fájlankénti patch-terv

## A. `native/zcash-sync/src/api/account.rs`

### Módosítandó függvény(ek)
- `new_account(...)` / `create_account(...)` (ahol az új account default receive címe létrejön)
- `get_default_address(...)` / `get_account_address(...)` (ha itt dől el a default cím típusa)
- opcionálisan: `get_address(account, kind)` vagy hasonló API elágazás

### Jelenlegi (UA/Orchard) viselkedés
- Új accountnál tipikusan UA (`u...`) készül defaultnak (Orchard+Sapling+T kombinációval).

### BUCK-on új viselkedés
- Új account default címe **Sapling `zs...`**.
- Explicit kérésre továbbra is lehessen `t...` címet kérni.
- `u...` default és `u...` cím-generálás **tiltva BUCK-on**.

### Más coinokra mi marad
- Jelenlegi UA/default logika változatlan más network/coin esetén.

### Diff-szintű pszeudopatch
```diff
--- a/native/zcash-sync/src/api/account.rs
+++ b/native/zcash-sync/src/api/account.rs
@@
+#[derive(Clone, Copy, Debug, PartialEq, Eq)]
+enum AddressKind {
+    Unified,
+    Sapling,
+    Transparent,
+}
+
+fn is_buck(coin: &CoinConfig) -> bool {
+    coin.ticker.eq_ignore_ascii_case("BUCK")
+}
@@ fn create_account(...)
- let default_addr = wallet.get_address(account_id, AddressKind::Unified)?;
+ let default_kind = if is_buck(&coin) {
+     AddressKind::Sapling
+ } else {
+     AddressKind::Unified
+ };
+ let default_addr = wallet.get_address(account_id, default_kind)?;
@@ fn get_account_address(account_id: u32, requested_kind: Option<AddressKind>, ...)
- let kind = requested_kind.unwrap_or(AddressKind::Unified);
+ let kind = match requested_kind {
+   Some(AddressKind::Unified) if is_buck(&coin) => {
+      anyhow::bail!("Unified Address not supported on BUCK")
+   }
+   Some(k) => k,
+   None => {
+      if is_buck(&coin) { AddressKind::Sapling } else { AddressKind::Unified }
+   }
+ };
```

---

## B. `native/zcash-sync/src/api/payment_v2.rs`

### Módosítandó függvény(ek)
- `prepare_payment_v2(...)`
- `select_change_address(...)` / `build_change_output(...)`
- `resolve_payment_address(...)` (ha van ilyen helper)

### Jelenlegi (UA/Orchard) viselkedés
- Payment és/vagy change route használhat Unified Address-t.

### BUCK-on új viselkedés
- Payment route: nem választhat/építhet UA célcímet vagy UA change-et.
- Change route BUCK-on:
  1. ha van shielded input, akkor **Sapling first** (`zs...`)
  2. különben **transparent fallback** (`t...`)

### Más coinokra mi marad
- Eredeti payment/change kiválasztási logika marad.

### Diff-szintű pszeudopatch
```diff
--- a/native/zcash-sync/src/api/payment_v2.rs
+++ b/native/zcash-sync/src/api/payment_v2.rs
@@ fn prepare_payment_v2(req: PaymentRequest, ...)
- let to_addr = parse_recipient(&req.to, &network)?;
+ let to_addr = parse_recipient(&req.to, &network)?;
+ if is_buck(&coin) && matches!(to_addr, RecipientAddress::Unified(_)) {
+     anyhow::bail!("Unified Address not supported on BUCK");
+ }
@@
- let change_addr = select_change_address(&ctx, AddressPolicy::Auto)?;
+ let change_addr = if is_buck(&coin) {
+     select_change_address_buck(&ctx)?
+ } else {
+     select_change_address(&ctx, AddressPolicy::Auto)?
+ };
@@
+fn select_change_address_buck(ctx: &TxContext) -> anyhow::Result<String> {
+    if ctx.has_shielded_inputs() {
+        if let Some(zs) = ctx.account.sapling_address.clone() {
+            return Ok(zs);
+        }
+    }
+    if let Some(taddr) = ctx.account.transparent_address.clone() {
+        return Ok(taddr);
+    }
+    anyhow::bail!("No valid BUCK change address (need Sapling or Transparent)")
+}
```

---

## C. `native/zcash-sync/src/api/recipient.rs`

### Módosítandó függvény(ek)
- `parse_recipient(...)`
- `decode_address(...)` / `recipient_from_str(...)`

### Jelenlegi (UA/Orchard) viselkedés
- `u...` recipient elfogadott és Unified típusra parse-olódik.

### BUCK-on új viselkedés
- `u...` recipient explicit hiba:
  - **`Unified Address not supported on BUCK`**
- `zs...` és `t...` marad elfogadott.

### Más coinokra mi marad
- UA parse továbbra is engedett.

### Diff-szintű pszeudopatch
```diff
--- a/native/zcash-sync/src/api/recipient.rs
+++ b/native/zcash-sync/src/api/recipient.rs
@@ fn parse_recipient(addr: &str, network: &Network, coin: &CoinConfig) -> anyhow::Result<RecipientAddress>
- if let Ok(ua) = decode_unified_address(addr, network) {
-    return Ok(RecipientAddress::Unified(ua));
- }
+ if let Ok(ua) = decode_unified_address(addr, network) {
+    if is_buck(coin) {
+       anyhow::bail!("Unified Address not supported on BUCK");
+    }
+    return Ok(RecipientAddress::Unified(ua));
+ }
```

---

## D. `native/zcash-sync/src/transaction.rs`

### Módosítandó függvény(ek)
- `build_transaction(...)`
- `classify_outputs(...)` / `add_recipient_output(...)`
- `derive_change(...)` / `finalize_change_output(...)`

### Jelenlegi (UA/Orchard) viselkedés
- Builder szinten is bekerülhet UA output/change (főleg ha upstream API átadja).

### BUCK-on új viselkedés
- Védőkorlát a builderben is:
  - recipient/change output nem lehet UA BUCK-on.
- Így API szintű bypass esetén is fail-fast.

### Más coinokra mi marad
- Eredeti output- és change-kezelés.

### Diff-szintű pszeudopatch
```diff
--- a/native/zcash-sync/src/transaction.rs
+++ b/native/zcash-sync/src/transaction.rs
@@ fn add_recipient_output(builder: &mut TxBuilder, addr: &RecipientAddress, ...)
+ if is_buck(&ctx.coin) && matches!(addr, RecipientAddress::Unified(_)) {
+    anyhow::bail!("Unified Address not supported on BUCK");
+ }
@@ fn finalize_change_output(...)
- let change = choose_change_address(...)?;
+ let change = if is_buck(&ctx.coin) {
+    choose_change_address_buck(...)?
+ } else {
+    choose_change_address(...)?
+ };
+
+ if is_buck(&ctx.coin) && change.starts_with('u') {
+    anyhow::bail!("Unified Address not supported on BUCK");
+ }
```

---

## E. `native/zcash-sync/src/scan.rs`

### Módosítandó függvény(ek)
- `derive_receivers(...)`
- `scan_outputs_for_account(...)`
- `account_receivers(...)`

### Jelenlegi (UA/Orchard) viselkedés
- Scan útvonal Orchard/UA receivert is próbálhat accounthoz rendelni.

### BUCK-on új viselkedés
- Scan során BUCK-on csak Sapling + Transparent receiver-ek kezelése.
- Orchard/UA receiver figyelmen kívül hagyható BUCK-only módban.

### Más coinokra mi marad
- Jelenlegi teljes receiver-készlet (UA/Orchard is) marad.

### Diff-szintű pszeudopatch
```diff
--- a/native/zcash-sync/src/scan.rs
+++ b/native/zcash-sync/src/scan.rs
@@ fn account_receivers(account: &Account, coin: &CoinConfig) -> ReceiverSet
- ReceiverSet {
-   orchard: account.orchard_receiver.clone(),
-   sapling: account.sapling_receiver.clone(),
-   transparent: account.transparent_receiver.clone(),
- }
+ if is_buck(coin) {
+   ReceiverSet {
+     orchard: None,
+     sapling: account.sapling_receiver.clone(),
+     transparent: account.transparent_receiver.clone(),
+   }
+ } else {
+   ReceiverSet {
+     orchard: account.orchard_receiver.clone(),
+     sapling: account.sapling_receiver.clone(),
+     transparent: account.transparent_receiver.clone(),
+   }
+ }
```

---

## F. `native/zcash-sync/src/db/read.rs` (opcionális fallback)

### Módosítandó függvény(ek)
- `get_default_address(account_id, ...)`
- `read_account_addresses(...)`

### Jelenlegi (UA/Orchard) viselkedés
- Ha UA van eltárolva preferáltként, azt adhatja vissza defaultnak.

### BUCK-on új viselkedés
- Fallback sorrend BUCK-ra olvasásnál:
  1. Sapling (`zs...`)
  2. Transparent (`t...`)
  3. hiba, ha egyik sincs
- UA mező létezhet DB-ben, de BUCK-on ne legyen preferált read-result.

### Más coinokra mi marad
- Eredeti preferenciarend.

### Diff-szintű pszeudopatch
```diff
--- a/native/zcash-sync/src/db/read.rs
+++ b/native/zcash-sync/src/db/read.rs
@@ fn get_default_address(account_id: u32, coin: &CoinConfig) -> anyhow::Result<String>
+ if is_buck(coin) {
+    if let Some(zs) = read_sapling_address(account_id)? { return Ok(zs); }
+    if let Some(t)  = read_transparent_address(account_id)? { return Ok(t); }
+    anyhow::bail!("No Sapling or Transparent address for BUCK account");
+ }
  // existing non-BUCK logic unchanged
```

---

## 2) Külön kiemelések

## Default address = `zs...`

- Account-létrehozáskor (`account.rs`) BUCK branchben a default address kind legyen Sapling.
- Address API default (`kind == None`) BUCK-on szintén Saplingre essen.

## Explicit `t...` kérés

- `get_account_address(..., requested_kind)` jellegű API-ban `requested_kind = Transparent` engedett BUCK-on.
- `requested_kind = Unified` BUCK-on explicit hiba.

## Change address kiválasztás

- BUCK-only helper:
  - `has_shielded_inputs == true` → Sapling change (`zs...`) **ha elérhető**
  - különben Transparent change (`t...`)
  - ha egyik sincs: hiba

## Recipient parsing hibaüzenet

- `recipient.rs` BUCK branch:
  - `u...` decode esetén: `bail!("Unified Address not supported on BUCK")`

---

## 3) Patch order (végrehajtási sorrend)

1. `api/recipient.rs` – `u...` explicit tiltás BUCK-on.
2. `api/account.rs` – default cím BUCK-on Sapling; explicit kind guard.
3. `api/payment_v2.rs` – BUCK change policy és UA tiltás payment pathban.
4. `transaction.rs` – builder-level guardrail UA ellen BUCK-on.
5. `scan.rs` – BUCK receiver setből Orchard kizárása.
6. `db/read.rs` fallback – BUCK read-preferencia (Sapling > Transparent).

---

## 4) Expected behavior after patch

1. Új BUCK account default címe `zs...`.
2. BUCK address API csak `zs...` és `t...` címet ad vissza.
3. BUCK-on `u...` cím generálás nem történik.
4. BUCK payment route-ban `u...` recipient immediate hiba: `Unified Address not supported on BUCK`.
5. BUCK change route nem használ Unified Address-t.
6. BUCK change kiválasztás:
   - shielded input esetén Sapling first,
   - különben transparent fallback.
7. Nem-BUCK coinok viselkedése változatlan.
8. DB/FFI/flatbuffer kompatibilitás megmarad.
