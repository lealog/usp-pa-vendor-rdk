/**
 * rbusTestProvider.c
 *
 * A minimal RBUS provider for testing. Registers a single path with a given
 * string value and runs until killed.
 *
 * Usage: rbusTestProvider <element_path> <value>
 * Example: rbusTestProvider Device.X_RDK_Test.Func.Param1 ValFunc
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <rbus.h>

static char g_value[512] = "";

static rbusError_t getHandler(rbusHandle_t handle, rbusProperty_t property, rbusGetHandlerOptions_t* opts)
{
    (void)handle;
    (void)opts;
    rbusValue_t v;
    rbusValue_Init(&v);
    rbusValue_SetString(v, g_value);
    rbusProperty_SetValue(property, v);
    rbusValue_Release(v);
    return RBUS_ERROR_SUCCESS;
}

int main(int argc, char** argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);

    if (argc < 3) {
        fprintf(stderr, "Usage: %s <element_path> <value>\n", argv[0]);
        return 1;
    }

    const char* element_path = argv[1];
    strncpy(g_value, argv[2], sizeof(g_value) - 1);
    g_value[sizeof(g_value) - 1] = '\0';

    /* Build a unique component name from the element path and PID */
    char component_name[256];
    snprintf(component_name, sizeof(component_name), "TestProvider_%d", getpid());

    rbusHandle_t handle;
    rbusError_t err;

    int attempts = 0;
    while (attempts < 10) {
        err = rbus_open(&handle, component_name);
        if (err == RBUS_ERROR_SUCCESS) break;
        fprintf(stderr, "rbus_open attempt %d failed: %d. Retrying...\n", attempts + 1, err);
        attempts++;
        sleep(1);
    }

    if (err != RBUS_ERROR_SUCCESS) {
        fprintf(stderr, "rbus_open failed permanently: %d\n", err);
        return 1;
    }

    rbusDataElement_t element;
    memset(&element, 0, sizeof(element));
    element.name = (char*)element_path;
    element.type = RBUS_ELEMENT_TYPE_PROPERTY;
    element.cbTable.getHandler = getHandler;

    err = rbus_regDataElements(handle, 1, &element);
    if (err != RBUS_ERROR_SUCCESS) {
        fprintf(stderr, "rbus_regDataElements failed for %s: %d\n", element_path, err);
        rbus_close(handle);
        return 1;
    }

    printf("READY: %s = %s\n", element_path, g_value);

    /* Run until killed */
    while (1) sleep(1);

    rbus_close(handle);
    return 0;
}
