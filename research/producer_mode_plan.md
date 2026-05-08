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
Device.Services.X_RDK_OBUSPA.Producer.Enable       Boolean  R/W  default: true
Device.Services.X_RDK_OBUSPA.Producer.AllowList     String   R/W  default: "" (empty = all paths)
Device.Services.X_RDK_OBUSPA.Producer.DenyList      String   R/W  default: "Device.Security."
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
| `obuspa/src/core/data_model.c` | Add `DATA_MODEL_GetParamType(path, *type_flags)` |
| `obuspa/src/core/data_model.h` | Declare `DATA_MODEL_GetParamType` |

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

### 3. Table row enumeration — why and how

**Why it is needed:**
When we register a table schema like `Device.LocalAgent.Controller.{i}.` in RBUS, RBUS knows the table *exists* but has no knowledge of which rows (instances) are currently live. A RBUS consumer doing `rbuscli getvalues 'Device.LocalAgent.Controller.*'` would return nothing because RBUS sees an empty table.

**Boot-time population (v1 scope):**
After registering the schema, call `rbusTable_registerRow` for every currently-live instance:

```c
// After rbus_regDataElements for "Device.LocalAgent.Controller.{i}."
int instances[MAX_INSTANCES]; int num;
USP_DM_GetInstances("Device.LocalAgent.Controller.", instances, MAX_INSTANCES, &num);
for (int i = 0; i < num; i++)
    rbusTable_registerRow(bus_handle, "Device.LocalAgent.Controller.", instances[i], NULL);
```

This makes `Device.LocalAgent.Controller.1.*`, `Device.LocalAgent.Controller.2.*`, etc. immediately visible to RBUS consumers.

**Dynamic row lifecycle (known v1 limitation):**
When a new instance is created at runtime (e.g., a new controller connects to obuspa), we would need to call `rbusTable_registerRow` dynamically. Doing this correctly requires a hook for "instance added/removed" in obuspa — not yet available as a public API. For v1, boot-time row registration is sufficient for static/slow-changing tables. Dynamic tracking is a v2 item.

---

### 4. SET latency — two different cases

**Case A — obuspa-native paths** (e.g., `Device.LocalAgent.Controller.1.Enable`):
Call chain: RBUS SET handler → `USP_PROCESS_DM_SetParameterValue` → `DoWorkSync` → USP main thread → `DATA_MODEL_SetParameterValue` → internal DB write.
Latency: **~1–5 ms** (local memory/DB only). Not a concern.

**Case B — UDS service paths** (e.g., `Device.SomeApp.Config.Value`):
Call chain: RBUS SET handler → `USP_PROCESS_DM_SetParameterValue` → `DoWorkSync` → USP main thread → `DATA_MODEL_SetParameterValue` → `Broker_GroupSet` → builds USP Set message → sends over UDS socket → **blocks waiting for a USP Set Response** from the service → service processes the SET and replies → unblocks.
Latency: **100 ms – several seconds**, bounded by `RESPONSE_TIMEOUT`.

**Risk:** RBUS may have an internal timeout for how long a property SET handler can block before the bus considers the provider unresponsive. This timeout must be verified to be longer than the worst-case USP UDS round-trip. If it is not, the SET for UDS-service paths may need to be made asynchronous (returning immediately from RBUS while completing the SET in the background) — but that introduces a semantic gap where RBUS reports success before the service has confirmed it. This tradeoff is a known implementation risk to verify during testing.

---

## Verification

1. **Build**: rebuild Docker image after changes; confirm no compile errors.
2. **Native paths test**:
   ```bash
   docker exec rbus-dev rbuscli get Device.LocalAgent.EndpointID
   # Expect: value returned from obuspa's internal DM
   ```
3. **UDS service test**: connect a test USP service via UDS, confirm its registered paths appear via:
   ```bash
   docker exec rbus-dev rbuscli get <service-path>
   ```
4. **Circular-registration guard**: ensure `Device.IP.*` (RDK-owned) does NOT appear twice as a provider.
5. **Existing tests**: run `bash run_manual_tests.sh` — consumer discovery cycles must still pass (CYCLE 1/2/3 PASS).
6. **Deregister test**: kill a UDS service and confirm its paths are removed from RBUS (unregistered).
