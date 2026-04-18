# BUCK-only backend migrációs riport (transparent + sapling, UA/Orchard nélkül)

## 0) Fontos előfeltétel és állapot

A kért backend-fájlok (`native/zcash-sync/...`) ebben a checkoutban **submodule-ként vannak deklarálva**, de jelenleg nem érhetők el lokálisan.

- Submodule deklaráció: `native/zcash-sync` a `.gitmodules` fájlban.
- A backend felé FFI-hívások és adatmodellek itt láthatók: `packages/warp_api_ffi/lib/warp_api.dart`, `packages/warp_api_ffi/lib/warp_api_generated.dart`, `idl/data.fbs`.
- A submodule letöltése sikertelen volt (`CONNECT tunnel failed, response 403`), emiatt a fájl/függvény/sorszintű backend-bontás csak részben (FFI + IDL oldalon) bizonyítható ebben a körben.

## 1) UA/Orchard függőségi lánc – mi látszik biztosan ebből a checkoutból

### 1.1 Adatmodell (IDL / FlatBuffers)

A jelenlegi séma explicit Orchard/UA-örökséget hordoz:

- `Balance.orchard`, `PoolBalance.orchard`, `ShieldedNote.orchard`, `TxReport.orchard`, `TxReport.net_orchard`, `AccountAddress.orchard` mezők jelen vannak.
- `AccountAddress.address` mező tipikusan az összevont (UA) címet hordozza.
- `Recipient.pools` bitmask és `TxOutput.pool` még multi-pool szemantikát tükröz.

### 1.2 FFI API felület (Dart wrapper + generated binding)

UA/Orchard-ra utaló kulcspontok:

- `getAddress(..., uaType)`
- `getDiversifiedAddress(..., uaType, ...)`
- `prepareTx(..., pools, senderUAType, ...)`
- `receiversOfAddress(...)` (UA receiver bontás)
- `prepare_multi_payment(... sender_ua ...)` native export

Ezek backend oldalon nagyon nagy valószínűséggel közvetlenül `native/zcash-sync/src/api/account.rs`, `api/recipient.rs`, `api/payment_v2.rs` és címmodellező modulok (`unified.rs`, `orchard.rs`) felé kötnek.

## 2) Fájl+függvény szintű döntési mátrix (BUCK-only cél)

> Megjegyzés: az alábbi lista a hiányzó submodule-fájloknál célzott műveletlista (patch-terv), nem lokálisan visszaellenőrzött konkrét line number.

### 2.1 Egyszerűen kikapcsolható (Phase A)

- `api/account.rs`
  - `get_unified_address*` hívások helyett Sapling alapértelmezés + külön `t...` accessor.
- `api/recipient.rs`
  - UA receiver feloldás letiltása; csak `t...`/`zs...` elfogadás.
- `api/payment_v2.rs`
  - `sender_ua`/UA-alapú change kiválasztás helyett pool-specifikus change: Sapling first, transparent fallback.
- `scan.rs`, `transaction.rs`
  - Orchard scanner/selector ágak no-op (feature gate vagy coin gate).

### 2.2 Feltételes letiltást igényel

- `db/read.rs`, `db.rs`
  - Orchard oszlopok olvasása 0/NULL-safe fallbackkel.
- `db/migration.rs`
  - Régi schema kompatibilitás miatt Orchard mezők egyelőre maradhatnak, de írásuk disabled.
- `note_selection/*`
  - Orchard note selection ágak compile-time vagy runtime gate mögé.

### 2.3 Biztonságosan törölhető (Phase B-C)

- `unified.rs` és `orchard.rs` modulok (ha nincs több coin igény).
- `main/rpc.rs` Orchard/UA specifikus route-ok.
- `binding.h` és FFI exportok:
  - `receivers_of_address`
  - `get_diversified_address(... ua_type ... )`
  - `prepare_multi_payment(... sender_ua ... )` régi paraméterezés

### 2.4 Maradhat inaktív kódként első körben

- DB Orchard oszlopok (csak olvasás kompatibilitás).
- FlatBuffer `orchard` mezők (0-ra állítva), amíg mobil/UI frissítés nem kész.

## 3) 3-fázisú BUCK-only migrációs terv

## A) Minimal-risk phase

Cél: minimális kódmódosítás, működő build, BUCK-only runtime viselkedés.

1. Coin policy kapcsoló bevezetése backendben (BUCK => `supports_unified=false`, `supports_orchard=false`).
2. Account létrehozás:
   - ne generáljon orchard kulcs/cím adatot,
   - ne generáljon UA-t default címként,
   - default `address` mező `zs...` legyen.
3. Címgenerálás:
   - `get_address` / `get_diversified_address` BUCK esetén csak `t...` vagy `zs...`.
4. Change address:
   - explicit Sapling change (ha shielded input), különben transparent change.
   - semmilyen automatikus UA összeállítás ne fusson.
5. Recipient parsing:
   - csak `t...`/`zs...` engedélyezés,
   - `u...` input explicit hibaüzenet: “Unified Address not supported on BUCK”.

## B) Cleanup phase

1. Deprecate jelölések:
   - FFI: `ua_type`, `sender_ua`, `receivers_of_address`.
   - API route-ok Orchard/UA vonalon.
2. IDL/flatbuffer átmeneti kompat:
   - Orchard mezők maradhatnak, de mindig 0 / false.
3. DB:
   - új migráció: Orchard-specifikus indexek/táblák deprecated.
   - olvasási backward-compat megmarad egy kiadásig.

## C) Final BUCK-only backend phase

1. Kódtörlés:
   - `unified.rs`, `orchard.rs`, Orchard selector/scanner ágak.
2. API egyszerűsítés:
   - `get_address(coin, account, kind)` ahol kind ∈ {transparent, sapling}.
   - `prepare_payment` sender oldalon nincs UA fogalom.
3. Modell egyszerűsítés:
   - `AccountAddress`: csak `transparent`, `sapling`, `default`.
   - `PoolBalance`: `transparent`, `sapling`.
4. FFI/IDL major bump.

## 4) Kritikus UA-képző pontok (cserék)

Keresendő és cserélendő minták a `native/zcash-sync` submodule-ban:

1. `get_unified_address(...)`
   - csere: `get_sapling_address(...)` + opcionális `get_transparent_address(...)`.
2. `UnifiedAddress::from_receivers(...)`
   - csere: cím-választó policy, amely **nem** aggregál UA-ba.
3. Automatikus change = UA
   - csere: `select_change_pool()` -> Sapling/transparent fix szabályok.
4. Account/address read útvonal, ahol orchard receiver bekerül
   - csere: Orchard receiver branch hard-disable BUCK policy alatt.

## 5) Felhasználói szempontból kritikus javítások

1. Új számla létrehozásakor ne `u...` legyen a főcím, hanem `zs...`.
2. Wallet listában ne jelenjen UA/Orchard logika (vagy mindig 0/hidden).
3. Csak `t...` és `zs...` címek legyenek visszaadva API-n.

## 6) Fee logika (a jelen checkout alapján)

- A látható rétegekben (`idl/data.fbs`, FFI `prepare_*`, `transfer_pools`) a fee paraméter **általános tranzakciós fee**-ként kezelt.
- Nem látható dedikált `fee_recipient/dev_fee/treasury` mező vagy route ezen a checkouton.
- Mivel a BUCK core / `native/zcash-sync` backend forrás nem tölthető le itt, chain-level fee-recipient mechanizmus jelenléte **nem bizonyítható teljes bizonyossággal** ebben a körben.

**Javasolt verifikáció a backend+core forrásban**:
- `transaction builder` output oldali extra kötelező output keresése,
- consensus / policy fee szabályok ellenőrzése BUCK node-ban,
- ha nincs ilyen kötelező output: a 0.0001 BUCK fee normál miner fee.

## 7) “Max / Full send” backend támogatás – technikai javaslat

1. Új számoló függvény backendben:
   - `get_max_sendable(account, recipient_pool, fee_policy, confirmations)`
2. Számítás:
   - spendable notes összeg (pool szerint)
   - kiválasztott fee policy alapján becsült fee
   - `max = spendable - fee - dust_guard`
3. API kivezetés:
   - `prepare_payment` tudjon `amount = MAX` jelzőt,
   - `transaction_report` adjon vissza `max_sendable` és végső `effective_fee` értéket.
4. UI/FFI:
   - `prepareTx` előtt opcionális `estimateMaxSend` endpoint.

## 8) Ajánlott első patch (konkrét, minimális)

1. Backend BUCK policy gate bevezetése (UA/Orchard false).
2. `get_address` BUCK esetben:
   - uaType ignorálása,
   - default: sapling (`zs...`), explicit kérésre transparent (`t...`).
3. `prepare_multi_payment` BUCK esetben:
   - `sender_ua` paraméter ignorálása,
   - change pool fixen Sapling/transparent szabállyal.
4. Recipient parser:
   - `u...` címet elutasít.
5. Account create path:
   - Orchard kulcs/cím init kihagyása.

## 9) Minimal patch set lista

1. `native/zcash-sync/src/api/account.rs`
2. `native/zcash-sync/src/api/payment_v2.rs`
3. `native/zcash-sync/src/api/recipient.rs`
4. `native/zcash-sync/src/transaction.rs`
5. `native/zcash-sync/src/scan.rs`
6. (átmeneti) `db/read.rs` Orchard fallback

## 10) “Ne nyúlj hozzá első körben” lista

1. DB fizikai oszloptörlések (`db/migration.rs`) – csak Phase B után.
2. FlatBuffer schema tördelés (`idl/data.fbs`) – major kompatibilitási lépés, később.
3. Teljes FFI ABI tisztítás (`binding.h`, generated bindingok) – csak amikor kliens oldali rollout kész.

## 11) Gyors ellenőrzőlista (DoD)

- [ ] új account default címe `zs...`
- [ ] `getAddress` nem ad vissza `u...` BUCK-on
- [ ] `prepareTx`/change útvonalon nincs UA előállítás
- [ ] `u...` recipient hibát ad
- [ ] orchard balance/note/report mezők 0/disabled
