# Plan: Producer Mode for usp-pa-vendor-rdk

## Baseline Versions

| Repo | Version | Base Commit | Branch |
|------|---------|-------------|--------|
| `rbus` | v2.0.5 | `9c049bf778d2beb411c107d0d05781420c2466fa` | `add_producer_support_for_usp_pa` |
| `obuspa` | v10.0.14 | `7262a0eb579cee12dfda956d036f8ec70a343b0c` | `add_producer_support_for_usp_pa` |
| `usp-pa-vendor-rdk` | — (from `main`) | — | `add_producer_support_for_usp_pa` |

All implementation work happens on these branches. The root `obusp_rbus` repo also has an `add_producer_support_for_usp_pa` branch (from `main`) to track the submodule pointer updates.

---

## Context

The vendor plugin today is **consumer-only**: it reads from RBUS via `rbus_getExt`/`rbus_set` and does not publish any paths back to the bus.

The USP Specification (R-SWM.x) describes a **Software Modularization** model where obuspa acts as a **USP Broker**: it aggregates data models both from RDK components (via RBUS discovery — the existing consumer path) and from USP Services (lightweight apps that connect via UDS-MTP and send Register + GetSupportedDataModel messages).

The user wants **two producer behaviors**:

1. **Static producer**: Register obuspa's own natively-owned DM paths (`Device.LocalAgent.*`, `Device.MQTT.*`, `Device.Time.*`, etc.) into RBUS, so that other RBUS components can GET/SET them without going through USP.

2. **Dynamic producer**: When a USP Service connects via UDS-MTP, registers its DM with the Broker (Register → GSDM flow), the Broker should also publish those paths into RBUS so the rest of the RDK stack can see them.

Both cases share the same **GET/SET dispatch path**: the RBUS handler thread calls `USP_PROCESS_DM_GetParameterValue`/`USP_PROCESS_DM_SetParameterValue` — thread-safe public APIs (available in obuspa since before v10.0.14, declared in `usp_api.h:496-497`) that internally use `USP_PROCESS_DoWorkSync` to post work to the USP main thread and block until done. For UDS-service paths, those calls route internally through `Broker_GroupGet` via the group_id mechanism — no special-casing needed at the handler level.

---

## Architecture

### New module: `rbus_producer.c`

All producer-side logic lives in a new file alongside vendor.c:
- `usp-pa-vendor-rdk/src/vendor/rbus_producer.c`
- `usp-pa-vendor-rdk/src/vendor/rbus_producer.h`

### Minimal obuspa modification

Add a **service registration callback** hook to `usp_broker.c` so the vendor plugin is notified when a USP Service finishes its GSDM exchange and its paths are live in the Broker's DM:

```c
// In obuspa/src/core/usp_broker.h (new public API)
typedef void (*usp_service_registered_cb_t)(const char *endpoint_id,
                                            str_vector_t *paths);
typedef void (*usp_service_deregistered_cb_t)(const char *endpoint_id);

void USP_BROKER_SetServiceCallbacks(usp_service_registered_cb_t on_reg,
                                    usp_service_deregistered_cb_t on_dereg);
```

Call sites (in `usp_broker.c`):
- After `RegisterBrokerVendorHooks(us)` — call `on_reg(us->endpoint_id, &us->registered_paths)`
- In `HandleUspServiceAgentDisconnect(us, flags)` — call `on_dereg(us->endpoint_id)`

---

## Implementation Steps

### Step 1 — Core data structures (`rbus_producer.c`)

```c
#define MAX_PRODUCER_PATHS 4096
#define PRODUCER_OWNER_OBUSPA "OBUSPA_NATIVE"

typedef struct {
    char *schema_path;      // e.g. "Device.LocalAgent.EndpointID"
    char *owner;            // PRODUCER_OWNER_OBUSPA or endpoint_id of UDS service
    rbusDataElement_t elem; // RBUS registration struct (name points into schema_path)
} producer_entry_t;

static producer_entry_t  g_producer[MAX_PRODUCER_PATHS];
static int               g_num_producer = 0;
static pthread_mutex_t   g_producer_mutex = PTHREAD_MUTEX_INITIALIZER;
```

### Step 2 — Thread-safe DM access (no custom synchronization needed)

obuspa v10.0.14 exposes two thread-safe public APIs in `usp_api.h` (lines 496–497) that are safe to call directly from RBUS handler threads:

```c
int USP_PROCESS_DM_GetParameterValue(char *path, char *buf, int len,
                                     char *err_msg, int err_msg_len);
int USP_PROCESS_DM_SetParameterValue(char *path, char *new_value,
                                     char *err_msg, int err_msg_len);
```

Both are implemented in `obuspa/src/core/dm_exec.c` and internally call `USP_PROCESS_DoWorkSync()` — which posts work to the USP main thread and blocks the caller until done. No manual mutex/condvar is required.

### Step 3 — Generic RBUS handler callbacks

One handler pair covers both obuspa-native and UDS-service paths:

```c
static rbusError_t producer_get_handler(rbusHandle_t h, rbusProperty_t prop,
                                        rbusGetHandlerOptions_t *opts) {
    char buf[4096];
    char err_msg[256];
    int err = USP_PROCESS_DM_GetParameterValue(
                  (char *)rbusProperty_GetName(prop),
                  buf, sizeof(buf), err_msg, sizeof(err_msg));
    if (err != USP_ERR_OK) return RBUS_ERROR_ELEMENT_DOES_NOT_EXIST;
    rbusValue_t v = rbusValue_InitString(buf);
    rbusProperty_SetValue(prop, v);
    rbusValue_Release(v);
    return RBUS_ERROR_SUCCESS;
}

static rbusError_t producer_set_handler(rbusHandle_t h, rbusProperty_t prop,
                                        rbusSetHandlerOptions_t *opts) {
    char err_msg[256];
    rbusValue_t v = rbusProperty_GetValue(prop);
    char *str = rbusValue_ToString(v, NULL, 0);
    int err = USP_PROCESS_DM_SetParameterValue(
                  (char *)rbusProperty_GetName(prop),
                  str, err_msg, sizeof(err_msg));
    free(str);
    return (err == USP_ERR_OK) ? RBUS_ERROR_SUCCESS : RBUS_ERROR_BUS_ERROR;
}
```

### Step 4 — Path registration helper

```c
// path: schema path (may end in "." for objects/tables, or not for params)
// owner: PRODUCER_OWNER_OBUSPA or endpoint_id string
static int RegisterProducerPath(const char *path, const char *owner) {
    // Reject if already in g_producer[] (dedup)
    // Reject if path is in g_registered_paths[] (i.e. already RBUS-owned)
    // Determine element type: TABLE if ends in ".{i}.", PROPERTY otherwise
    // Fill in rbusDataElement_t with appropriate handlers
    // Call rbus_regDataElements(bus_handle, 1, &entry->elem)
    // Store in g_producer[]
}

static int UnregisterProducerByOwner(const char *owner) {
    // Gather all entries matching owner
    // Call rbus_unregDataElements for them
    // Free and compact g_producer[]
}
```

### Step 5 — Producer filter data model (`Device.Services.X_RDK_OBUSPA.`)

The USP specification has no standardized mechanism for filtering which paths are exposed to an underlying transport bus — it only enforces access control at the request level (RBAC). This filtering is an **RDK-specific extension** scoped under a dedicated obuspa namespace: `Device.Services.X_RDK_OBUSPA.`

`Device.Services.` is the standard TR-181 container for service-specific objects. Using `Device.Services.X_RDK_OBUSPA.` keeps all obuspa configuration cleanly separated from the existing discovery params.

Register these new parameters in `VENDOR_Init()`:

```
Device.Services.X_RDK_OBUSPA.Producer.Enable           Boolean  R/W  default: true
Device.Services.X_RDK_OBUSPA.Producer.AllowList         String   R/W  default: "" (empty = all paths)
Device.Services.X_RDK_OBUSPA.Producer.DenyList          String   R/W  default: "Device.Security."
Device.Services.X_RDK_OBUSPA.Producer.SetTimeoutSecs    Uint     R/W  default: 30
```

**Semantics:**
- `Enable = false`: producer mode disabled; no paths registered into RBUS.
- `AllowList`: comma-separated path prefixes. If non-empty, only paths matching a prefix here are published.
- `DenyList`: comma-separated path prefixes. Paths matching any prefix here are always excluded, even if in `AllowList`.
- Evaluation order: `Enable` → `AllowList` → `DenyList`.
- Default: allow all obuspa-owned paths **except** `Device.Security.` (known RDK component conflict).

**Filter check function** (called inside `RegisterProducerPath`):

```c
static bool IsProducerPathAllowed(const char *path) {
    if (!g_producer_enable) return false;

    // AllowList: if non-empty, path must match at least one prefix
    if (strlen(g_producer_allowlist) > 0 && !MatchesAnyPrefix(path, g_producer_allowlist))
        return false;

    // DenyList: path must not match any prefix
    if (MatchesAnyPrefix(path, g_producer_denylist))
        return false;

    return true;
}
```

### Step 6 — Static obuspa-native paths (`RbusProducer_Start`)

Call from `VENDOR_Start()` after the DM is fully initialized.

1. For each known top-level obuspa-owned subtree, call `USP_DM_GetInstances` to discover table instances.
2. Walk schema paths using `USP_DM_IsRegistered` probing, or expose a new internal helper `DATA_MODEL_GetSchemaPathsUnder(root, out_vector)` in `data_model.c`.
3. For each path, call `IsProducerPathAllowed(path)` before `RegisterProducerPath(path, PRODUCER_OWNER_OBUSPA)`.

Starting subtrees (obuspa-native, not RBUS-owned):
```
Device.LocalAgent.
Device.MQTT.
Device.Time.
Device.ManagementServer.
Device.BulkData.
Device.USPServices.
Device.Services.X_RDK_OBUSPA.   ← expose the producer config itself on RBUS
```
`Device.Security.` excluded by default via `DenyList`.

### Step 7 — Dynamic UDS service paths

In `rbus_producer.c`:

```c
// Called from usp_broker.c after GSDM exchange completes
void RbusProducer_OnServiceRegistered(const char *endpoint_id,
                                      str_vector_t *paths) {
    for (int i = 0; i < paths->num_entries; i++) {
        RegisterProducerPath(paths->vector[i], endpoint_id);
    }
    USP_LOG_Info("Producer: published %d paths for USP service %s to RBUS",
                 paths->num_entries, endpoint_id);
}

// Called from usp_broker.c on disconnect
void RbusProducer_OnServiceDeregistered(const char *endpoint_id) {
    UnregisterProducerByOwner(endpoint_id);
    USP_LOG_Info("Producer: withdrew paths for USP service %s from RBUS", endpoint_id);
}
```

Vendor plugin wires these callbacks during `VENDOR_Init`:

```c
// In vendor.c VENDOR_Init()
USP_BROKER_SetServiceCallbacks(RbusProducer_OnServiceRegistered,
                               RbusProducer_OnServiceDeregistered);
```

### Step 8 — Anti-circular-registration guard

Before calling `rbus_regDataElements` for any path, check that it is NOT already in `g_registered_paths[]` (the consumer-side cache). If it is, skip it — it's an RDK-owned path, not an obuspa-owned path. This prevents RBUS from seeing duplicate registrations for paths like `Device.IP.*` that flow in via the consumer discovery path.

```c
// In RegisterProducerPath():
if (IsPathAlreadyRegistered(path, NULL, 0)) {
    return USP_ERR_OK;  // Skip: this path is managed by an RDK component on RBUS
}
```

---

## Critical Files to Modify

| File | Change |
|------|--------|
| `usp-pa-vendor-rdk/src/vendor/rbus_producer.c` | **New file** — all producer logic |
| `usp-pa-vendor-rdk/src/vendor/rbus_producer.h` | **New file** — public API |
| `usp-pa-vendor-rdk/src/vendor/vendor.c` | Call `RbusProducer_Init()` in `VENDOR_Init`, `RbusProducer_Start()` in `VENDOR_Start` |
| `obuspa/src/core/usp_broker.c` | Add static callback pointers; call them at register/deregister |
| `obuspa/src/core/usp_broker.h` | Expose `USP_BROKER_SetServiceCallbacks` |
| `obuspa/src/core/data_model.c` | Add `DATA_MODEL_GetParamType`, add `DATA_MODEL_SetInstanceCallbacks` and call sites in `NotifyInstanceAdded`/`NotifyInstanceDeleted` |
| `obuspa/src/core/data_model.h` | Declare `DATA_MODEL_GetParamType`, `DATA_MODEL_SetInstanceCallbacks`, `dm_instance_added_cb_t`, `dm_instance_removed_cb_t` |

RBUS consumer cache already lives in `vendor.c:435-555` — the `IsPathAlreadyRegistered` function is reused directly.

The existing `bus_handle` (opened in `VENDOR_Init`, line ~1331) is shared with the producer — no second `rbus_open` call is needed.

---

## Design Decisions (Resolved)

### 1. Subtree enumeration
No hardcoded list. Controlled via `Device.Services.X_RDK_OBUSPA.Producer.AllowList` / `DenyList` (Step 5). Default: allow all obuspa-owned paths except `Device.Security.`.

---

### 2. Type mapping for RBUS — use real types, not RBUS_STRING

The producer must return typed RBUS values (RBUS_BOOLEAN, RBUS_INT32, etc.), not always RBUS_STRING. Here is why and how it works:

**How the consumer path works today (reference):**
- RBUS providers register elements with `RBUS_ELEMENT_TYPE_PROPERTY` (the element KIND, not the value type).
- The GET handler sets a typed `rbusValue_t` on the property (e.g., `rbusValue_SetBoolean`).
- When vendor.c reads these (`rbus_getExt`), it calls `rbusValue_ToString()` to convert to a string for obuspa's internal USP processing.
- For SETs, `UspTypeToRdkType(param_types[i])` maps the USP DM type → RBUS type, then `rbusValue_SetFromString(val, rbusType, str)` creates the typed RBUS value to push back.

**For the producer GET path:**
`USP_PROCESS_DM_GetParameterValue` always returns a string (USP works with strings internally). We must then convert that string to the correct RBUS type before returning it to the RBUS consumer. This is symmetric with what the consumer's SET path does today:

```c
static rbusError_t producer_get_handler(...) {
    char buf[4096]; char err_msg[256];
    USP_PROCESS_DM_GetParameterValue((char*)rbusProperty_GetName(prop),
                                     buf, sizeof(buf), err_msg, sizeof(err_msg));

    // Look up stored RBUS type for this path (set at registration time)
    int rbus_type = LookupProducerRbusType(rbusProperty_GetName(prop));

    rbusValue_t v;
    rbusValue_Init(&v);
    rbusValue_SetFromString(v, rbus_type, buf);  // reuses existing function
    rbusProperty_SetValue(prop, v);
    rbusValue_Release(v);
    return RBUS_ERROR_SUCCESS;
}
```

**Getting the type at registration time:**
The USP DM type (`type_flags`: DM_BOOL, DM_INT, DM_UINT, DM_STRING, etc.) is stored on `dm_node_t→registered.param_info.type_flags` inside obuspa's DM tree. A small new internal function is needed in `obuspa/src/core/data_model.c`:

```c
int DATA_MODEL_GetParamType(char *path, unsigned *type_flags);
```

Called (on USP main thread, via DoWorkSync) during `RegisterProducerPath`. Result is stored in `producer_entry_t.rbus_type` (mapped via the existing `UspTypeToRdkType()`). The GET handler does a fast lookup by path into the producer table.

**For the producer SET path:**
`rbusValue_ToString()` converts the incoming typed RBUS value to a string (identical to what the consumer GET path does), then `USP_PROCESS_DM_SetParameterValue` takes the string.

---

### 3. Table row enumeration — full dynamic tracking in V1

**Why it is needed:**
When we register a table schema like `Device.LocalAgent.Controller.{i}.` in RBUS, RBUS knows the table *exists* but has no knowledge of which rows (instances) are currently live. A RBUS consumer doing `rbuscli getvalues 'Device.LocalAgent.Controller.*'` would return nothing because RBUS sees an empty table.

**Boot-time population:**
After registering the schema, call `rbusTable_registerRow` for every currently-live instance:

```c
// After rbus_regDataElements for "Device.LocalAgent.Controller.{i}."
int instances[MAX_INSTANCES]; int num;
USP_DM_GetInstances("Device.LocalAgent.Controller.", instances, MAX_INSTANCES, &num);
for (int i = 0; i < num; i++)
    rbusTable_registerRow(bus_handle, "Device.LocalAgent.Controller.", instances[i], NULL);
```

**Dynamic row lifecycle (V1 — runtime instance add/remove):**
`DATA_MODEL_NotifyInstanceAdded(char *path)` and `DATA_MODEL_NotifyInstanceDeleted(char *path)` already exist in `obuspa/src/core/data_model.c` (lines 1362 and 1448). These are called whenever an instance is created or destroyed in the DM.

Add a pair of callbacks to `data_model.c` (same pattern as the `usp_broker.c` service hooks):

```c
// New in obuspa/src/core/data_model.h
typedef void (*dm_instance_added_cb_t)(const char *path);
typedef void (*dm_instance_removed_cb_t)(const char *path);
void DATA_MODEL_SetInstanceCallbacks(dm_instance_added_cb_t on_add,
                                     dm_instance_removed_cb_t on_del);
```

Call sites in `data_model.c`:
- End of `DATA_MODEL_NotifyInstanceAdded` → call `g_on_instance_added(path)`
- End of `DATA_MODEL_NotifyInstanceDeleted` → call `g_on_instance_removed(path)`

Vendor plugin registers them in `VENDOR_Init()` and reacts:
```c
// on_add: extract table name and instance number from path, call rbusTable_registerRow
// on_del: call rbusTable_unregisterRow
void RbusProducer_OnInstanceAdded(const char *path);
void RbusProducer_OnInstanceRemoved(const char *path);
```

---

### 4. SET latency and timeout — we must define our own

**`rbusSetOptions_t` has no timeout field** (confirmed: only `commit` and `sessionId`). RBUS defines no SET handler timeout at the API level. We must define and enforce our own.

**Case A — obuspa-native paths** (e.g., `Device.LocalAgent.Controller.1.Enable`):
Call chain: RBUS SET handler → `USP_PROCESS_DM_SetParameterValue` → `DoWorkSync` → USP main thread → internal DB write.
Latency: **~1–5 ms**. No timeout risk.

**Case B — UDS service paths** (e.g., `Device.SomeApp.Config.Value`):
Call chain: RBUS SET handler → `USP_PROCESS_DM_SetParameterValue` → `DoWorkSync` → USP main thread → `Broker_GroupSet` → USP Set message over UDS socket → **blocks for service round-trip** → reply → unblocks.
Latency: **100 ms – several seconds**. If the RBUS dispatcher has any watchdog or the consumer has its own timeout, an unbounded block is dangerous.

**Solution — configurable producer SET timeout:**

Add to the `Device.Services.X_RDK_OBUSPA.` DM:
```
Device.Services.X_RDK_OBUSPA.Producer.SetTimeoutSecs   Uint  R/W  default: 30
```

In the SET handler, enforce the timeout using a `pthread_cond_timedwait` wrapper around the work-queue dispatch (instead of the unconditional `USP_PROCESS_DoWorkSync`):

```c
static rbusError_t producer_set_handler(...) {
    // Post work to USP main thread with deadline
    struct timespec deadline = now() + g_producer_set_timeout_secs;
    int err = DoWorkWithDeadline(producer_set_worker, &req, &deadline);
    if (err == ETIMEDOUT) return RBUS_ERROR_TIMEOUT;
    return (req.usp_err == USP_ERR_OK) ? RBUS_ERROR_SUCCESS : RBUS_ERROR_BUS_ERROR;
}
```

`DoWorkWithDeadline` is a small helper in `rbus_producer.c` that uses `USP_PROCESS_DoWork` (async) + a condvar with `pthread_cond_timedwait` for bounded blocking. This is the one place where we do need a custom condvar — specifically for the timeout-bounded SET path. The GET handler remains simple (no timeout needed for reads).

---

## Testing & Acceptance Criteria

> **Scope note:** UDS-MTP service path testing is explicitly excluded from this phase. A suitable USP Service container still needs to be identified. All tests here validate the static producer (obuspa-native paths) only.

### Tools available inside the container

| Tool | Purpose |
|------|---------|
| `rbuscli get <path>` | RBUS consumer single-path GET |
| `rbuscli getvalues '<path>*'` | RBUS consumer wildcard GET |
| `rbuscli set <path> <type> <value>` | RBUS consumer SET |
| `rbuscli discoverRegisteredComponents` | Verify component registration |
| `obuspa -s /tmp/usp_cli -c get <path>` | USP GET (ground truth) |
| `obuspa -s /tmp/usp_cli -c set <path> <value>` | USP SET (ground truth) |
| `bash run_manual_tests.sh` | Consumer discovery regression suite |
| `docker exec rbus-dev bash /work/unified_test_suite.sh all` | Full consumer test suite |

---

### TC-BUILD-01: Compile without errors
**Steps:** Build Docker image after all changes.  
**Pass:** Image builds with zero errors and zero new warnings. `obuspa` and `UspPA` binaries present at `/usr/local/bin/`.

---

### TC-REG-01: Consumer discovery regression
**Steps:** Run `bash run_manual_tests.sh`.  
**Pass:** `CYCLE 1 PASS`, `CYCLE 2 PASS`, `CYCLE 3 PASS`. Exit code 0. The producer additions must not break the existing consumer path.

---

### TC-REG-02: Full unified test suite regression
**Steps:** `docker exec rbus-dev bash /work/unified_test_suite.sh all`  
**Pass:** All 22 test cases pass. No new failures introduced.

---

### TC-GET-01: GET obuspa string parameter
**Steps:**
```bash
USP_VAL=$(docker exec rbus-dev obuspa -s /tmp/usp_cli -c get Device.LocalAgent.EndpointID)
RBUS_VAL=$(docker exec rbus-dev rbuscli get Device.LocalAgent.EndpointID)
```
**Pass:** `RBUS_VAL` matches `USP_VAL`. RBUS value is non-empty.

---

### TC-GET-02: GET parameter type fidelity — Boolean
**Steps:** GET `Device.LocalAgent.Enable` (boolean) via a custom test consumer that inspects `rbusValue_GetType()`.  
**Pass:** `rbusValue_GetType(val) == RBUS_BOOLEAN`. Must NOT be `RBUS_STRING`.

---

### TC-GET-03: GET parameter type fidelity — Unsigned integer
**Steps:** GET `Device.LocalAgent.ControllerNumberOfEntries` (uint) via test consumer.  
**Pass:** `rbusValue_GetType(val) == RBUS_UINT32`. Value matches USP ground truth.

---

### TC-GET-04: GET parameter type fidelity — DateTime
**Steps:** GET `Device.LocalAgent.UpTime` or similar datetime param via test consumer.  
**Pass:** `rbusValue_GetType(val) == RBUS_DATETIME`. Value matches USP ground truth.

---

### TC-GET-05: GET non-existent path
**Steps:** `rbuscli get Device.LocalAgent.DoesNotExist`  
**Pass:** Returns `RBUS_ERROR_ELEMENT_DOES_NOT_EXIST`. No crash.

---

### TC-GET-06: GET read-only path — value unchanged after failed SET
**Steps:**
```bash
rbuscli set Device.LocalAgent.EndpointID string "tampered"
rbuscli get Device.LocalAgent.EndpointID
```
**Pass:** SET returns an error. GET returns the original (unchanged) value.

---

### TC-SET-01: SET writable obuspa parameter
**Steps:**
```bash
rbuscli set Device.LocalAgent.Controller.1.Enable boolean false
obuspa -s /tmp/usp_cli -c get Device.LocalAgent.Controller.1.Enable
```
**Pass:** USP GET returns `false`. SET via RBUS propagated correctly to obuspa's DM.

---

### TC-SET-02: SET read-only parameter rejected
**Steps:** `rbuscli set Device.LocalAgent.EndpointID string "tampered"`  
**Pass:** Returns non-success error code. `rbuscli get` still returns original value.

---

### TC-TABLE-01: Boot-time table row visibility
**Steps:** After container start, before any runtime DM changes:
```bash
rbuscli getvalues 'Device.LocalAgent.Controller.*'
```
**Pass:** At least one instance row (`Device.LocalAgent.Controller.1.*`) is visible. All parameters within the instance are readable.

---

### TC-TABLE-02: Dynamic row addition
**Steps:**
1. Record current `rbuscli getvalues 'Device.LocalAgent.Subscription.*'` (baseline count).
2. Add a subscription via USP: `obuspa -s /tmp/usp_cli -c add Device.LocalAgent.Subscription.`
3. `rbuscli getvalues 'Device.LocalAgent.Subscription.*'`

**Pass:** New instance row appears in RBUS within 1 second of USP add. No restart required.

---

### TC-TABLE-03: Dynamic row removal
**Steps:**
1. Note current subscription instance number `N`.
2. Delete it via USP: `obuspa -s /tmp/usp_cli -c del Device.LocalAgent.Subscription.N.`
3. `rbuscli getvalues 'Device.LocalAgent.Subscription.*'`

**Pass:** Instance `N` row is gone from RBUS. Remaining rows still visible.

---

### TC-FILTER-01: DenyList excludes paths at startup
**Steps:** `rbuscli get Device.Security.Certificate.1.SerialNumber`  
**Pass:** Returns `RBUS_ERROR_ELEMENT_DOES_NOT_EXIST`. `Device.Security.` is in the default DenyList and must NOT be registered by the producer.

---

### TC-FILTER-02: DenyList runtime update
**Steps:**
1. Verify `Device.LocalAgent.EndpointID` is visible via RBUS.
2. `obuspa -s /tmp/usp_cli -c set Device.Services.X_RDK_OBUSPA.Producer.DenyList "Device.Security.,Device.LocalAgent."`
3. `rbuscli get Device.LocalAgent.EndpointID`

**Pass:** Path is no longer accessible via RBUS after DenyList update. (Requires producer to re-evaluate registrations on DenyList change.)

---

### TC-FILTER-03: Enable=false disables all producer paths
**Steps:**
1. `obuspa -s /tmp/usp_cli -c set Device.Services.X_RDK_OBUSPA.Producer.Enable false`
2. `rbuscli get Device.LocalAgent.EndpointID`

**Pass:** Returns error — no producer paths accessible. Existing consumer-discovered paths (e.g., `Device.IP.*`) unaffected.

---

### TC-FILTER-04: Enable=true re-enables producer
**Steps:** After TC-FILTER-03, set `Enable=true`.  
**Pass:** `Device.LocalAgent.EndpointID` accessible again via RBUS.

---

### TC-FILTER-05: AllowList restricts to subset
**Steps:**
1. `obuspa -s /tmp/usp_cli -c set Device.Services.X_RDK_OBUSPA.Producer.AllowList "Device.LocalAgent."`
2. `rbuscli get Device.MQTT.Client.1.Enable` (outside AllowList)
3. `rbuscli get Device.LocalAgent.EndpointID` (inside AllowList)

**Pass:** Step 2 returns error; Step 3 returns value.

---

### TC-CIRCULAR-01: RBUS-owned paths not double-registered
**Steps:**
1. Start `rbusTestProvider` registering `Device.Foo.Bar`.
2. Wait for consumer discovery (existing path shows in `Device.X_RDK_DMDiscovery.*`).
3. `rbuscli discoverRegisteredComponents` — check that `Device.Foo.Bar` is owned by `rbusTestProvider`, NOT by the obuspa producer component.

**Pass:** No `RBUS_ERROR_ELEMENT_NAME_DUPLICATE` in logs. `Device.Foo.Bar` provider is `rbusTestProvider`.

---

### TC-TIMEOUT-01: SetTimeoutSecs is configurable and readable
**Steps:**
```bash
obuspa -s /tmp/usp_cli -c get Device.Services.X_RDK_OBUSPA.Producer.SetTimeoutSecs
obuspa -s /tmp/usp_cli -c set Device.Services.X_RDK_OBUSPA.Producer.SetTimeoutSecs 10
rbuscli get Device.Services.X_RDK_OBUSPA.Producer.SetTimeoutSecs
```
**Pass:** Value readable via both USP and RBUS. SET via USP propagates. Value changes to `10`.

---

### TC-TIMEOUT-02: SET timeout enforced (simulated slow handler)
**Steps:**
1. Set `SetTimeoutSecs` to `2`.
2. Inject an artificial delay in the USP main thread (test hook or debug build) to simulate a slow SET.
3. Issue `rbuscli set <path> <val>`.

**Pass:** Returns `RBUS_ERROR_TIMEOUT` after ~2 seconds. No deadlock, no hung thread.

---

### TC-CONCURRENCY-01: Concurrent GET calls
**Steps:** Fire 20 parallel `rbuscli get Device.LocalAgent.EndpointID` from background shells simultaneously.  
**Pass:** All 20 return the same correct value. No crash, no hang, no garbled output.

---

### TC-SELFVIS-01: Producer filter DM visible via RBUS
**Steps:**
```bash
rbuscli getvalues 'Device.Services.X_RDK_OBUSPA.Producer.*'
```
**Pass:** `Enable`, `AllowList`, `DenyList`, `SetTimeoutSecs` all returned with correct default values.

---

### TC-RESTART-01: Producer re-registers after obuspa restart
**Steps:**
1. Verify `Device.LocalAgent.EndpointID` visible via RBUS.
2. Restart obuspa inside container.
3. Wait for obuspa ready (log: `USP Agent running`).
4. `rbuscli get Device.LocalAgent.EndpointID`

**Pass:** Path accessible again after restart. No manual intervention required.

---

### Acceptance gate

All of the following must pass before the feature is considered complete for this phase:

| Mandatory | TCs |
|-----------|-----|
| Build | TC-BUILD-01 |
| Regression — no breakage | TC-REG-01, TC-REG-02 |
| GET correctness | TC-GET-01 through TC-GET-06 |
| SET correctness | TC-SET-01, TC-SET-02 |
| Table lifecycle | TC-TABLE-01, TC-TABLE-02, TC-TABLE-03 |
| Filter DM | TC-FILTER-01 through TC-FILTER-05 |
| Circular guard | TC-CIRCULAR-01 |
| Timeout | TC-TIMEOUT-01, TC-TIMEOUT-02 |
| Concurrency | TC-CONCURRENCY-01 |
| Self-visibility | TC-SELFVIS-01 |
| Restart recovery | TC-RESTART-01 |

> UDS-MTP producer tests (dynamic service registration/deregistration paths via RBUS) are deferred until the appropriate USP Service container is identified.
