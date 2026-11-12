/* The embedding ABI's own contract, driven from C against libnupp: what
 * host/include/nupp.h promises about configuration, names, values, ownership,
 * reentrancy, reload sessions, attaching and thread affinity. hostembeddingtest
 * links it against the static SDK and runs it; each check that fails prints its
 * line, and the program prints "embedabi: ok" only when every one passed. */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <nupp.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

/* The Lua C API libnupp exports, declared here rather than through LuaJIT's
 * headers, which a host linking only the SDK does not have. */
extern int luaL_loadstring(lua_State *state, const char *source);
extern int lua_pcall(lua_State *state, int arguments, int results, int handler);
extern void lua_settop(lua_State *state, int index);
extern void lua_createtable(lua_State *state, int array, int records);
extern void lua_pushcclosure(lua_State *state, nupp_lua_CFunction function, int upvalues);

static int failures;

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            failures++; \
            printf("embedabi.c:%d: check failed: %s\n", __LINE__, #condition); \
        } \
    } while (0)

/* Runs a Lua chunk in a runtime's state: 1 when it ran. */
static int run(nupp_runtime *runtime, const char *source) {
    lua_State *state = nupp_runtime_lua_state(runtime);
    int ok;
    if (state == NULL) return 0;
    ok = luaL_loadstring(state, source) == 0 && lua_pcall(state, 0, 0, 0) == 0;
    lua_settop(state, 0);
    return ok;
}

static nupp_runtime *new_runtime(void) {
    nupp_runtime *runtime = NULL;
    CHECK(nupp_runtime_new(NULL, &runtime, NULL) == NUPP_STATUS_OK);
    CHECK(runtime != NULL);
    return runtime;
}

static const char COMPONENT[] =
    "-- NUPP-COMPONENT 1\n"
    "return {\n"
    "  format = 1,\n"
    "  hostAbi = 1,\n"
    "  install = function()\n"
    "    return {\n"
    "      exports = {\n"
    "        [\"answer\"] = function(value) return value + 1, \"bytes\", { value = value } end,\n"
    "        [\"read\"] = function(value) return value.value end,\n"
    "        [\"echo\"] = function(...) return ... end,\n"
    "      },\n"
    "      start = function() embed_started = arg[1] end,\n"
    "    }\n"
    "  end,\n"
    "}\n";

static nupp_component *load(nupp_runtime *runtime) {
    nupp_component *component = NULL;
    CHECK(nupp_component_load(runtime, COMPONENT, sizeof COMPONENT - 1, "=embed-test", &component, NULL)
        == NUPP_STATUS_OK);
    return component;
}

static nupp_handle *find(nupp_runtime *runtime, nupp_component *component, const char *name) {
    nupp_handle *handle = NULL;
    CHECK(nupp_export_find(runtime, component, name, &handle, NULL) == NUPP_STATUS_OK);
    return handle;
}

static nupp_value number(double value) {
    nupp_value answer;
    memset(&answer, 0, sizeof answer);
    answer.kind = NUPP_VALUE_NUMBER;
    answer.number = value;
    return answer;
}

static int message_has(nupp_error *error, const char *text) {
    return error != NULL && strstr(nupp_error_message(error), text) != NULL;
}

static void configuration_and_owned_lifecycle_are_checked(void) {
    nupp_config config;
    nupp_runtime *runtime = NULL;
    nupp_error *error = NULL;
    memset(&config, 0, sizeof config);
    nupp_config_init(&config);
    CHECK(config.size == sizeof config);
    CHECK(config.abi_version == NUPP_EMBED_ABI_VERSION);
    CHECK(config.flags == NUPP_CONFIG_OPEN_LIBRARIES);

    CHECK(nupp_runtime_new(&config, NULL, &error) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_error_status(error) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_error_category(error) == NUPP_ERROR_CONFIGURATION);
    CHECK(nupp_error_message_length(error) > 0);
    CHECK(nupp_error_message(error) != NULL);
    nupp_error_free(error);
    CHECK(nupp_error_status(NULL) == NUPP_STATUS_OK);
    CHECK(nupp_error_category(NULL) == 0);
    CHECK(strcmp(nupp_error_message(NULL), "") == 0);
    CHECK(nupp_error_message_length(NULL) == 0);

    config.size = 1;
    CHECK(nupp_runtime_new(&config, &runtime, &error) == NUPP_STATUS_INCOMPATIBLE);
    CHECK(nupp_error_category(error) == NUPP_ERROR_COMPATIBILITY);
    nupp_error_free(error);
    config.size = sizeof config;
    config.abi_version = 999;
    CHECK(nupp_runtime_new(&config, &runtime, &error) == NUPP_STATUS_INCOMPATIBLE);
    nupp_error_free(error);
    config.abi_version = NUPP_EMBED_ABI_VERSION;
    config.flags = 0x80;
    CHECK(nupp_runtime_new(&config, &runtime, &error) == NUPP_STATUS_INVALID_ARGUMENT);
    nupp_error_free(error);
    CHECK(runtime == NULL);

    runtime = new_runtime();
    CHECK(nupp_runtime_lua_state(runtime) != NULL);
    error = NULL;
    CHECK(nupp_runtime_poll(runtime, &error) == NUPP_STATUS_OK);
    CHECK(error == NULL);
    CHECK(nupp_runtime_shutdown(runtime, &error) == NUPP_STATUS_OK);
    CHECK(nupp_runtime_shutdown(runtime, &error) == NUPP_STATUS_OK);
    CHECK(nupp_runtime_lua_state(runtime) == NULL);
    CHECK(nupp_runtime_poll(runtime, &error) == NUPP_STATUS_RUNTIME);
    CHECK(message_has(error, "shut down"));
    nupp_error_free(error);
    nupp_runtime_free(runtime);
    nupp_runtime_free(NULL);

    /* A runtime without libraries is a bare state. */
    config.flags = 0;
    runtime = NULL;
    CHECK(nupp_runtime_new(&config, &runtime, NULL) == NUPP_STATUS_OK);
    CHECK(nupp_runtime_lua_state(runtime) != NULL);
    nupp_runtime_free(runtime);
}

static void the_state_sees_the_host_record_and_survives_lua_failures(void) {
    nupp_runtime *runtime = new_runtime();
    CHECK(run(runtime,
        "assert(__nuppHost.hostAbi == 1); assert(type(__nuppHost.hostFeatures) == 'table');"
        "assert(type(__nuppHost.resources) == 'table'); assert(__nuppHost.hostFeatures['native-time'])"));
    CHECK(run(runtime,
        "assert(type(require('jit.vmdef')) == 'table'); assert(type(require('jit.zone')) == 'table');"
        "assert(package.preload['jit.bc'] ~= nil); assert(type(require('jit.bc').line) == 'function')"));
    CHECK(!run(runtime, "error('deliberate')"));
    CHECK(run(runtime, "assert(6 * 7 == 42)"));
    /* A finalizer that fails while the state closes is LuaJIT's to contain. */
    CHECK(run(runtime,
        "heldUntilClose = newproxy(true); getmetatable(heldUntilClose).__gc = function() error('finalizer trap') end"));
    CHECK(nupp_runtime_shutdown(runtime, NULL) == NUPP_STATUS_OK);
    nupp_runtime_free(runtime);
}

static void a_hostile_globals_table_cannot_escape_the_protected_boundary(void) {
    nupp_runtime *runtime = new_runtime();
    nupp_component *component = NULL;
    nupp_error *error = NULL;
    static const char TRAP[] =
        "-- NUPP-COMPONENT 1\n"
        "return setmetatable({}, {__index = function() error('descriptor trap') end})";
    CHECK(nupp_component_load(runtime, TRAP, sizeof TRAP - 1, "=descriptor-trap", &component, &error)
        == NUPP_STATUS_RUNTIME);
    CHECK(message_has(error, "descriptor trap"));
    CHECK(component == NULL);
    nupp_error_free(error);
    CHECK(run(runtime, "assert(6 * 7 == 42)"));
    /* Starting a component sets `arg`, which a globals metatable can refuse. */
    component = load(runtime);
    CHECK(run(runtime,
        "arg = nil; setmetatable(_G, {__newindex = function(target, key, value) setmetatable(target, nil);"
        " error('setup trap') end})"));
    error = NULL;
    CHECK(nupp_component_start(runtime, component, 0, NULL, &error) == NUPP_STATUS_RUNTIME);
    CHECK(message_has(error, "setup trap"));
    nupp_error_free(error);
    CHECK(run(runtime, "assert(6 * 7 == 42)"));
    nupp_component_release(runtime, component, NULL);
    nupp_runtime_free(runtime);
}

static void attached_shutdown_leaves_the_callers_state_alive(void) {
    nupp_runtime *owner = new_runtime();
    lua_State *state = nupp_runtime_lua_state(owner);
    nupp_runtime *attached = NULL;
    nupp_config config;
    nupp_config_init(&config);
    config.flags = 0;
    CHECK(nupp_runtime_attach(state, &config, &attached, NULL) == NUPP_STATUS_OK);
    CHECK(run(attached, "attached_value = 21"));
    CHECK(nupp_runtime_shutdown(attached, NULL) == NUPP_STATUS_OK);
    nupp_runtime_free(attached);
    CHECK(run(owner, "assert(attached_value * 2 == 42)"));
    CHECK(nupp_runtime_poll(owner, NULL) == NUPP_STATUS_OK);
    CHECK(nupp_runtime_shutdown(owner, NULL) == NUPP_STATUS_OK);
    nupp_runtime_free(owner);

    config.flags = NUPP_CONFIG_OPEN_LIBRARIES;
    CHECK(nupp_runtime_attach(NULL, &config, &attached, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_runtime_attach(NULL, &config, NULL, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
}

static void attaching_keeps_the_states_host_record_and_its_freeze(void) {
    nupp_runtime *owner = new_runtime();
    nupp_runtime *attached = NULL;
    nupp_error *error = NULL;
    nupp_config config;
    nupp_component *component;
    nupp_config_init(&config);
    config.flags = 0;
    CHECK(nupp_runtime_add_feature(owner, "engine.clock", NULL) == NUPP_STATUS_OK);
    CHECK(nupp_runtime_add_resource(owner, "engine/defaults.json", "{}", 2, NULL) == NUPP_STATUS_OK);
    component = load(owner);
    CHECK(nupp_runtime_attach(nupp_runtime_lua_state(owner), &config, &attached, NULL) == NUPP_STATUS_OK);
    CHECK(run(attached,
        "assert(__nuppHost.hostFeatures['engine.clock']); assert(__nuppHost.resources['engine/defaults.json'] == '{}')"));
    /* The state froze when its first component loaded, whichever runtime is
     * asking now. */
    CHECK(nupp_runtime_add_feature(attached, "late", NULL) == NUPP_STATUS_RUNTIME);
    CHECK(nupp_runtime_add_resource(attached, "late", "", 0, NULL) == NUPP_STATUS_RUNTIME);
    /* The first runtime on a state answers its host requests. */
    CHECK(nupp_host_register(attached, "engine.clock", NULL, NULL, NULL, &error) == NUPP_STATUS_INCOMPATIBLE);
    CHECK(nupp_error_category(error) == NUPP_ERROR_COMPATIBILITY);
    nupp_error_free(error);
    nupp_runtime_free(attached);
    nupp_component_release(owner, component, NULL);
    nupp_runtime_free(owner);

    /* A global of that name the runtime did not make is not one to share. */
    owner = new_runtime();
    CHECK(run(owner, "__nuppHost = 42"));
    attached = NULL;
    error = NULL;
    CHECK(nupp_runtime_attach(nupp_runtime_lua_state(owner), &config, &attached, &error)
        == NUPP_STATUS_INCOMPATIBLE);
    CHECK(message_has(error, "__nuppHost"));
    CHECK(attached == NULL);
    nupp_error_free(error);
    nupp_runtime_free(owner);
}

static void attaching_checks_the_states_own_luajit(void) {
    nupp_runtime *owner = new_runtime();
    nupp_runtime *attached = NULL;
    nupp_error *error = NULL;
    nupp_config config;
    int open;
    nupp_config_init(&config);
    CHECK(run(owner, "jit.version = 'LuaJIT 2.1.0-beta3'"));
    for (open = 0; open < 2; open++) {
        config.flags = open ? NUPP_CONFIG_OPEN_LIBRARIES : 0;
        error = NULL;
        CHECK(nupp_runtime_attach(nupp_runtime_lua_state(owner), &config, &attached, &error)
            == NUPP_STATUS_INCOMPATIBLE);
        CHECK(message_has(error, "requires LuaJIT"));
        nupp_error_free(error);
    }
    /* A refused attach did not reopen the host's libraries. */
    CHECK(run(owner, "assert(jit.version == 'LuaJIT 2.1.0-beta3')"));
    nupp_runtime_free(owner);

    /* A bare state has no jit library to ask; opening libraries gives it this
     * one's. */
    config.flags = 0;
    owner = NULL;
    CHECK(nupp_runtime_new(&config, &owner, NULL) == NUPP_STATUS_OK);
    config.flags = NUPP_CONFIG_OPEN_LIBRARIES;
    CHECK(nupp_runtime_attach(nupp_runtime_lua_state(owner), &config, &attached, NULL) == NUPP_STATUS_OK);
    nupp_runtime_free(attached);
    nupp_runtime_free(owner);
}

static int empty_module(lua_State *state) {
    (void)state;
    return 0;
}

static int builder_table(lua_State *state) {
    lua_createtable(state, 0, 0);
    return 1;
}

static void c_preloads_and_aot_registrars_run_beneath_the_protected_boundary(void) {
    static const char EXTENSIONS[] =
        "-- NUPP-COMPONENT 1\n"
        "return {\n"
        "  format = 1,\n"
        "  hostAbi = 1,\n"
        "  install = function()\n"
        "    assert(require(\"fixture.module\") == true)\n"
        "    assert(type(__nuppAotBuilderModules.fixture) == \"table\")\n"
        "    return { exports = {}, start = function() end }\n"
        "  end,\n"
        "}\n";
    nupp_runtime *runtime = new_runtime();
    nupp_component *component = NULL;
    nupp_error *error = NULL;
    CHECK(nupp_runtime_preload(runtime, "fixture.module", empty_module, NULL) == NUPP_STATUS_OK);
    CHECK(nupp_runtime_register_aot_builders(runtime, "fixture", builder_table, NULL) == NUPP_STATUS_OK);
    CHECK(nupp_component_load(runtime, EXTENSIONS, sizeof EXTENSIONS - 1, "=extensions", &component, NULL)
        == NUPP_STATUS_OK);
    CHECK(nupp_runtime_preload(runtime, "late", empty_module, NULL) == NUPP_STATUS_RUNTIME);
    CHECK(nupp_runtime_register_aot_builders(runtime, "late", builder_table, NULL) == NUPP_STATUS_RUNTIME);
    CHECK(nupp_component_release(runtime, component, NULL) == NUPP_STATUS_OK);
    nupp_runtime_free(runtime);

    runtime = new_runtime();
    CHECK(nupp_runtime_preload(runtime, "fixture", NULL, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_runtime_register_aot_builders(runtime, "fixture", NULL, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_runtime_register_aot_builders(runtime, "", builder_table, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_runtime_register_aot_builders(runtime, "malformed", empty_module, &error) == NUPP_STATUS_RUNTIME);
    CHECK(message_has(error, "must return a table"));
    nupp_error_free(error);
    CHECK(nupp_runtime_add_feature(runtime, "after-error", NULL) == NUPP_STATUS_OK);
    CHECK(nupp_runtime_add_feature(runtime, "\xff", NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_runtime_add_feature(runtime, NULL, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    nupp_runtime_free(runtime);
}

static void the_workers_feature_cannot_be_declared_through_the_abi(void) {
    nupp_runtime *runtime = new_runtime();
    nupp_error *error = NULL;
    CHECK(nupp_runtime_add_feature(runtime, "workers", &error) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_error_category(error) == NUPP_ERROR_CONFIGURATION);
    CHECK(message_has(error, "cannot declare the workers feature"));
    nupp_error_free(error);
    /* A neighbouring name is not the reserved one. */
    CHECK(nupp_runtime_add_feature(runtime, "workers-extra", NULL) == NUPP_STATUS_OK);
    nupp_runtime_free(runtime);
}

static void components_values_handles_and_buffer_ownership_cross_the_abi(void) {
    nupp_runtime *runtime = new_runtime();
    nupp_component *component;
    nupp_handle *answer, *read, *echo;
    nupp_value argument = number(41.0), results[3], read_result, echoed[4], arguments[4];
    size_t count = 0, index;
    nupp_error *error = NULL;
    const char *start_argument = "started";
    CHECK(nupp_runtime_add_feature(runtime, "native-test", NULL) == NUPP_STATUS_OK);
    CHECK(nupp_runtime_add_resource(runtime, "fixture", "a\0b", 3, NULL) == NUPP_STATUS_OK);
    component = load(runtime);
    CHECK(nupp_runtime_add_feature(runtime, "late", NULL) == NUPP_STATUS_RUNTIME);
    answer = find(runtime, component, "answer");
    CHECK(nupp_call(runtime, answer, &argument, 1, NULL, 0, &count, NULL) == NUPP_STATUS_BUFFER_TOO_SMALL);
    CHECK(count == 3);
    memset(results, 0, sizeof results);
    CHECK(nupp_call(runtime, answer, &argument, 1, results, 3, &count, NULL) == NUPP_STATUS_OK);
    CHECK(results[0].kind == NUPP_VALUE_NUMBER && results[0].number == 42.0);
    CHECK(results[1].kind == NUPP_VALUE_BYTES && results[1].length == 5 && memcmp(results[1].data, "bytes", 5) == 0);
    CHECK(results[2].kind == NUPP_VALUE_HANDLE && results[2].handle != NULL);

    read = find(runtime, component, "read");
    memset(&read_result, 0, sizeof read_result);
    CHECK(nupp_call(runtime, read, &results[2], 1, &read_result, 1, &count, NULL) == NUPP_STATUS_OK);
    CHECK(read_result.number == 41.0);
    CHECK(nupp_value_release(runtime, &read_result, NULL) == NUPP_STATUS_OK);
    for (index = 0; index < 3; index++) {
        CHECK(nupp_value_release(runtime, &results[index], NULL) == NUPP_STATUS_OK);
        CHECK(results[index].kind == NUPP_VALUE_NIL);
    }
    CHECK(nupp_value_release(runtime, NULL, NULL) == NUPP_STATUS_OK);

    /* Every scalar kind and bytes with a NUL inside come back as they went. */
    echo = find(runtime, component, "echo");
    memset(arguments, 0, sizeof arguments);
    arguments[0].kind = NUPP_VALUE_NIL;
    arguments[1].kind = NUPP_VALUE_BOOLEAN;
    arguments[1].boolean = 1;
    arguments[2].kind = NUPP_VALUE_STRING;
    arguments[2].data = (unsigned char *)"a\0b";
    arguments[2].length = 3;
    arguments[3].kind = NUPP_VALUE_BYTES;
    arguments[3].length = 0;
    memset(echoed, 0, sizeof echoed);
    CHECK(nupp_call(runtime, echo, arguments, 4, echoed, 4, &count, NULL) == NUPP_STATUS_OK);
    CHECK(count == 4);
    CHECK(echoed[0].kind == NUPP_VALUE_NIL);
    CHECK(echoed[1].kind == NUPP_VALUE_BOOLEAN && echoed[1].boolean == 1);
    CHECK(echoed[2].kind == NUPP_VALUE_BYTES && echoed[2].length == 3 && memcmp(echoed[2].data, "a\0b", 3) == 0);
    CHECK(echoed[3].kind == NUPP_VALUE_BYTES && echoed[3].length == 0);
    for (index = 0; index < 4; index++) nupp_value_release(runtime, &echoed[index], NULL);
    arguments[2].data = NULL;
    CHECK(nupp_call(runtime, echo, arguments, 4, echoed, 4, &count, &error) == NUPP_STATUS_INVALID_ARGUMENT);
    nupp_error_free(error);

    CHECK(nupp_handle_release(runtime, answer, NULL) == NUPP_STATUS_OK);
    CHECK(nupp_handle_release(runtime, read, NULL) == NUPP_STATUS_OK);
    CHECK(nupp_handle_release(runtime, echo, NULL) == NUPP_STATUS_OK);

    CHECK(nupp_component_start(runtime, component, 1, &start_argument, NULL) == NUPP_STATUS_OK);
    CHECK(run(runtime,
        "assert(embed_started == 'started'); assert(__nuppHost.hostFeatures['native-test']);"
        "assert(__nuppHost.resources.fixture == 'a\\0b')"));
    CHECK(nupp_component_start(runtime, component, 0, NULL, NULL) == NUPP_STATUS_RUNTIME);
    CHECK(nupp_component_start(runtime, component, 1, NULL, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_component_release(runtime, component, NULL) == NUPP_STATUS_OK);
    CHECK(nupp_runtime_shutdown(runtime, NULL) == NUPP_STATUS_OK);
    nupp_runtime_free(runtime);
}

static void cross_runtime_and_invalid_inputs_are_rejected_without_consuming_owners(void) {
    nupp_runtime *first = new_runtime(), *second = new_runtime();
    nupp_component *component = load(first), *loaded = NULL;
    nupp_handle *handle = find(first, component, "answer"), *callable;
    nupp_value result, unknown;
    nupp_error *error = NULL;
    memset(&result, 0, sizeof result);
    CHECK(nupp_call(second, handle, NULL, 0, &result, 1, NULL, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_handle_release(second, handle, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_component_start(second, component, 0, NULL, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_handle_release(first, handle, NULL) == NUPP_STATUS_OK);

    CHECK(nupp_component_start(first, NULL, 0, NULL, &error) == NUPP_STATUS_INVALID_ARGUMENT);
    nupp_error_free(error);
    CHECK(nupp_runtime_add_resource(first, "x", NULL, 1, &error) == NUPP_STATUS_INVALID_ARGUMENT);
    nupp_error_free(error);
    CHECK(nupp_call(first, NULL, NULL, 0, NULL, 0, NULL, &error) == NUPP_STATUS_INVALID_ARGUMENT);
    nupp_error_free(error);
    memset(&unknown, 0, sizeof unknown);
    unknown.kind = 99;
    callable = find(first, component, "answer");
    CHECK(nupp_call(first, callable, &unknown, 1, &result, 1, NULL, &error) == NUPP_STATUS_INVALID_ARGUMENT);
    nupp_error_free(error);
    CHECK(nupp_handle_release(first, callable, NULL) == NUPP_STATUS_OK);
    CHECK(nupp_component_load(first, "not a component", 15, NULL, &loaded, &error) == NUPP_STATUS_RUNTIME);
    CHECK(message_has(error, "not a Nupp component artifact"));
    nupp_error_free(error);
    CHECK(nupp_component_load(first, NULL, 1, NULL, &loaded, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_component_load(first, COMPONENT, sizeof COMPONENT - 1, NULL, NULL, NULL)
        == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_runtime_poll(NULL, &error) == NUPP_STATUS_INVALID_ARGUMENT);
    nupp_error_free(error);
    /* A component answers to the runtime that loaded it. */
    CHECK(nupp_component_release(second, component, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_component_release(first, component, NULL) == NUPP_STATUS_OK);
    nupp_runtime_free(first);
    nupp_runtime_free(second);
}

static void a_released_handle_is_refused_and_its_name_is_never_reissued(void) {
    nupp_runtime *runtime = new_runtime();
    nupp_component *component = load(runtime);
    nupp_handle *answer = find(runtime, component, "answer"), *read, *doubled, *handle = NULL;
    nupp_value argument = number(41.0), results[3], copy, out;
    size_t count = 0;
    nupp_error *error = NULL;
    CHECK(nupp_handle_release(runtime, answer, NULL) == NUPP_STATUS_OK);
    read = find(runtime, component, "read");
    CHECK(answer != read);
    memset(results, 0, sizeof results);
    CHECK(nupp_call(runtime, answer, &argument, 1, results, 3, &count, &error) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(count == 0);
    CHECK(message_has(error, "released"));
    nupp_error_free(error);
    CHECK(nupp_handle_release(runtime, answer, NULL) == NUPP_STATUS_INVALID_ARGUMENT);

    /* A copied result value released through one copy is stale in the other. */
    doubled = find(runtime, component, "answer");
    CHECK(nupp_call(runtime, doubled, &argument, 1, results, 3, &count, NULL) == NUPP_STATUS_OK);
    memset(&copy, 0, sizeof copy);
    copy.kind = results[2].kind;
    copy.handle = results[2].handle;
    CHECK(nupp_value_release(runtime, &copy, NULL) == NUPP_STATUS_OK);
    memset(&out, 0, sizeof out);
    CHECK(nupp_call(runtime, read, &results[2], 1, &out, 1, &count, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_value_release(runtime, &results[2], NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    nupp_value_release(runtime, &results[0], NULL);
    nupp_value_release(runtime, &results[1], NULL);

    /* A handle is not a component, and a released component is gone. */
    CHECK(nupp_export_find(runtime, (nupp_component *)read, "answer", &handle, NULL)
        == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_component_release(runtime, component, NULL) == NUPP_STATUS_OK);
    CHECK(nupp_export_find(runtime, component, "answer", &handle, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(handle == NULL);
    CHECK(nupp_component_release(runtime, component, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_component_release(runtime, NULL, NULL) == NUPP_STATUS_OK);
    nupp_handle_release(runtime, read, NULL);
    nupp_handle_release(runtime, doubled, NULL);
    CHECK(nupp_runtime_shutdown(runtime, NULL) == NUPP_STATUS_OK);
    nupp_runtime_free(runtime);
}

static void handles_outliving_shutdown_are_closed_and_still_freed(void) {
    nupp_runtime *runtime = new_runtime();
    nupp_component *component = load(runtime);
    nupp_handle *answer = find(runtime, component, "answer");
    nupp_value result;
    nupp_error *error = NULL;
    CHECK(nupp_runtime_shutdown(runtime, NULL) == NUPP_STATUS_OK);
    memset(&result, 0, sizeof result);
    CHECK(nupp_call(runtime, answer, NULL, 0, &result, 1, NULL, &error) == NUPP_STATUS_RUNTIME);
    nupp_error_free(error);
    CHECK(nupp_handle_release(runtime, answer, NULL) == NUPP_STATUS_OK);
    CHECK(nupp_component_release(runtime, component, NULL) == NUPP_STATUS_OK);
    nupp_runtime_free(runtime);
}

enum { REENTER_SHUTDOWN, REENTER_FREE, REENTER_CALL };

static nupp_runtime *reentered_runtime;
static nupp_handle *reentered_answer;
static int reentry_mode;
static int inner_status;
static double inner_number;

static int reenter(lua_State *state) {
    (void)state;
    if (reentry_mode == REENTER_SHUTDOWN) {
        inner_status = nupp_runtime_shutdown(reentered_runtime, NULL);
    } else if (reentry_mode == REENTER_FREE) {
        nupp_runtime_free(reentered_runtime);
    } else {
        nupp_value argument = number(41.0), results[3];
        size_t index;
        memset(results, 0, sizeof results);
        inner_status = nupp_call(reentered_runtime, reentered_answer, &argument, 1, results, 3, NULL, NULL);
        inner_number = results[0].number;
        for (index = 0; index < 3; index++) nupp_value_release(reentered_runtime, &results[index], NULL);
    }
    return 0;
}

static int open_reenter(lua_State *state) {
    lua_pushcclosure(state, reenter, 0);
    return 1;
}

static const char REENTRANT[] =
    "-- NUPP-COMPONENT 1\n"
    "return {\n"
    "  format = 1,\n"
    "  hostAbi = 1,\n"
    "  install = function()\n"
    "    return {\n"
    "      exports = {\n"
    "        answer = function(value) return value + 1, \"bytes\", { value = value } end,\n"
    "        quit = function() require(\"fixture.reenter\")(); return 7 end,\n"
    "      },\n"
    "      start = function() end,\n"
    "    }\n"
    "  end,\n"
    "}\n";

/* Calls `quit`, whose host callback does `mode` to the runtime that is calling
 * it, and answers the outer call's status and first result. */
static nupp_runtime *call_reentering(int mode, int *status, double *answer) {
    nupp_runtime *runtime = new_runtime();
    nupp_component *component = NULL;
    nupp_handle *quit;
    nupp_value result;
    CHECK(nupp_runtime_preload(runtime, "fixture.reenter", open_reenter, NULL) == NUPP_STATUS_OK);
    CHECK(nupp_component_load(runtime, REENTRANT, sizeof REENTRANT - 1, "=reentrant", &component, NULL)
        == NUPP_STATUS_OK);
    quit = find(runtime, component, "quit");
    reentered_runtime = runtime;
    reentered_answer = find(runtime, component, "answer");
    reentry_mode = mode;
    inner_status = -1;
    inner_number = 0;
    memset(&result, 0, sizeof result);
    *status = nupp_call(runtime, quit, NULL, 0, &result, 1, NULL, NULL);
    *answer = result.number;
    return runtime;
}

static void reentering_a_runtime_from_its_own_call(void) {
    int status;
    double answer;
    nupp_runtime *runtime = call_reentering(REENTER_SHUTDOWN, &status, &answer);
    CHECK(inner_status == NUPP_STATUS_RUNTIME);
    CHECK(status == NUPP_STATUS_OK && answer == 7.0);
    CHECK(nupp_runtime_poll(runtime, NULL) == NUPP_STATUS_OK);
    CHECK(nupp_runtime_shutdown(runtime, NULL) == NUPP_STATUS_OK);
    nupp_runtime_free(runtime);

    /* The runtime is gone after this call; the call that was running when it
     * was freed still finished on it. */
    call_reentering(REENTER_FREE, &status, &answer);
    CHECK(status == NUPP_STATUS_OK && answer == 7.0);

    runtime = call_reentering(REENTER_CALL, &status, &answer);
    CHECK(inner_status == NUPP_STATUS_OK && inner_number == 42.0);
    CHECK(status == NUPP_STATUS_OK && answer == 7.0);
    CHECK(nupp_runtime_shutdown(runtime, NULL) == NUPP_STATUS_OK);
    nupp_runtime_free(runtime);
}

static const char STUB_SESSION[] =
    "package.preload['nupp.tools.hostreload'] = function()\n"
    "  local steps = 0\n"
    "  local session = {\n"
    "    member = function(name) if name == 'update' then return function() return 1 end end end,\n"
    "    prepare = function()\n"
    "      steps = steps + 1\n"
    "      if steps == 1 then return 'prepared', 1, 'staged' end\n"
    "      error('the compiler crashed')\n"
    "    end,\n"
    "    apply = function() return 'committed', 2 end,\n"
    "    poll = function() return 'sideways', 1 end,\n"
    "    close = function(ok) closed = ok end,\n"
    "  }\n"
    "  return {open = function(entry) opened = entry; return session end, attach = function() return session end}\n"
    "end\n";

static void reload_sessions_keep_their_contract(void) {
    nupp_runtime *runtime = new_runtime();
    nupp_reload_config config;
    nupp_reload *reload = NULL;
    nupp_handle *update = NULL, *missing = NULL;
    nupp_error *error = NULL;
    uint32_t verdict = 99;
    uint64_t generation = 99;

    /* A configuration the session cannot read. */
    CHECK(nupp_reload_open(runtime, NULL, &reload, &error) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_error_category(error) == NUPP_ERROR_CONFIGURATION);
    nupp_error_free(error);
    memset(&config, 0, sizeof config);
    CHECK(nupp_reload_open(runtime, &config, &reload, &error) == NUPP_STATUS_INCOMPATIBLE);
    nupp_error_free(error);
    nupp_reload_config_init(&config);
    CHECK(config.size == sizeof config && config.flags == 0 && config.entry == NULL);
    config.flags = 1 << 8;
    CHECK(nupp_reload_open(runtime, &config, &reload, &error) == NUPP_STATUS_INVALID_ARGUMENT);
    nupp_error_free(error);
    nupp_reload_config_init(&config);
    CHECK(nupp_reload_open(runtime, &config, &reload, &error) == NUPP_STATUS_INVALID_ARGUMENT);
    nupp_error_free(error);
    CHECK(reload == NULL);
    CHECK(nupp_reload_find(runtime, NULL, "update", &update, &error) == NUPP_STATUS_INVALID_ARGUMENT);
    nupp_error_free(error);
    CHECK(nupp_reload_message(NULL) == NULL);
    nupp_reload_free(NULL);

    CHECK(run(runtime, STUB_SESSION));
    config.entry = "app.main";
    CHECK(nupp_reload_open(runtime, &config, &reload, NULL) == NUPP_STATUS_OK);
    CHECK(run(runtime, "assert(opened == 'app.main')"));
    CHECK(nupp_reload_find(runtime, reload, "update", &update, NULL) == NUPP_STATUS_OK);
    CHECK(update != NULL);
    CHECK(nupp_reload_find(runtime, reload, "nothing", &missing, &error) == NUPP_STATUS_RUNTIME);
    CHECK(message_has(error, "no callable nothing"));
    nupp_error_free(error);
    CHECK(nupp_reload_prepare(runtime, reload, &verdict, &generation, NULL) == NUPP_STATUS_OK);
    CHECK(verdict == NUPP_RELOAD_PREPARED && generation == 1);
    CHECK(nupp_reload_message(reload) != NULL && strcmp(nupp_reload_message(reload), "staged") == 0);
    /* A host acting on the verdict after a failed step must not find the
     * previous step's PREPARED still there. */
    CHECK(nupp_reload_prepare(runtime, reload, &verdict, &generation, NULL) == NUPP_STATUS_RUNTIME);
    CHECK(verdict == NUPP_RELOAD_NO_CHANGE && generation == 0);
    CHECK(nupp_reload_message(reload) == NULL);
    CHECK(nupp_reload_apply(runtime, reload, &verdict, &generation, NULL) == NUPP_STATUS_OK);
    CHECK(verdict == NUPP_RELOAD_COMMITTED && generation == 2);
    CHECK(nupp_reload_poll(runtime, reload, &verdict, &generation, &error) == NUPP_STATUS_RUNTIME);
    CHECK(message_has(error, "unknown verdict sideways"));
    nupp_error_free(error);
    CHECK(nupp_reload_close(runtime, reload, 1, NULL) == NUPP_STATUS_OK);
    CHECK(run(runtime, "assert(closed == true)"));
    CHECK(nupp_reload_prepare(runtime, reload, &verdict, &generation, &error) == NUPP_STATUS_RUNTIME);
    CHECK(message_has(error, "closed"));
    nupp_error_free(error);
    nupp_reload_free(reload);
    CHECK(nupp_reload_close(runtime, reload, 0, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    nupp_handle_release(runtime, update, NULL);

    /* A session the host never closes is closed, as a failed one, at shutdown. */
    CHECK(nupp_reload_open(runtime, &config, &reload, NULL) == NUPP_STATUS_OK);
    CHECK(run(runtime, "closed = nil"));
    CHECK(nupp_runtime_shutdown(runtime, NULL) == NUPP_STATUS_OK);
    nupp_reload_free(reload);
    nupp_runtime_free(runtime);
}

static void a_reload_session_refuses_a_state_that_runs_native_workers(void) {
    nupp_runtime *owner = new_runtime(), *attached = NULL;
    nupp_reload_config config;
    nupp_config attach;
    nupp_reload *reload = NULL;
    nupp_error *error = NULL;
    nupp_reload_config_init(&config);
    config.entry = "app.main";
    CHECK(run(owner, STUB_SESSION));
    CHECK(run(owner, "__nuppWorkerHost = true"));
    CHECK(nupp_reload_open(owner, &config, &reload, &error) == NUPP_STATUS_RUNTIME);
    CHECK(message_has(error, "commits into one state"));
    nupp_error_free(error);
    /* The reachable case: a stamped binary's state, attached to through the
     * embedding ABI, whose own marker is all that can answer for it. */
    nupp_config_init(&attach);
    attach.flags = 0;
    CHECK(nupp_runtime_attach(nupp_runtime_lua_state(owner), &attach, &attached, NULL) == NUPP_STATUS_OK);
    error = NULL;
    CHECK(nupp_reload_attach(attached, &config, &reload, &error) == NUPP_STATUS_RUNTIME);
    CHECK(message_has(error, "commits into one state"));
    nupp_error_free(error);
    nupp_runtime_free(attached);
    nupp_runtime_free(owner);
}

static void an_export_failure_reports_its_whole_message(void) {
    static const char FAILING[] =
        "-- NUPP-COMPONENT 1\n"
        "return { format = 1, hostAbi = 1, install = function() return {\n"
        "  exports = { fail = function() error((\"before\\0after-NUL\"):rep(400), 0) end },\n"
        "  start = function() end } end }\n";
    nupp_runtime *runtime = new_runtime();
    nupp_component *component = NULL;
    nupp_handle *fail;
    nupp_error *error = NULL;
    size_t length;
    CHECK(nupp_component_load(runtime, FAILING, sizeof FAILING - 1, "=failing", &component, NULL)
        == NUPP_STATUS_OK);
    fail = find(runtime, component, "fail");
    CHECK(nupp_call(runtime, fail, NULL, 0, NULL, 0, NULL, &error) == NUPP_STATUS_RUNTIME);
    /* One C string: a NUL the Lua message carried reads as `?`. */
    length = nupp_error_message_length(error);
    CHECK(length == 16 * 400);
    CHECK(strlen(nupp_error_message(error)) == length);
    CHECK(strncmp(nupp_error_message(error), "before?after-NULbefore?", 23) == 0);
    nupp_error_free(error);
    nupp_handle_release(runtime, fail, NULL);
    nupp_component_release(runtime, component, NULL);
    nupp_runtime_free(runtime);
}

static void host_kinds_and_answers_are_checked(void) {
    nupp_runtime *runtime = new_runtime();
    nupp_error *error = NULL;
    nupp_value value;
    CHECK(nupp_host_register(runtime, NULL, NULL, NULL, NULL, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_host_register(runtime, "single", NULL, NULL, NULL, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_host_register(runtime, "a..b", NULL, NULL, NULL, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_host_register(runtime, "a.b.", NULL, NULL, NULL, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_host_register(runtime, "a b.c", NULL, NULL, NULL, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_host_register(runtime, "nupp.clock", NULL, NULL, NULL, &error) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(message_has(error, "reserved"));
    nupp_error_free(error);
    CHECK(nupp_host_register(runtime, "game.clock-2_x", NULL, NULL, NULL, NULL) == NUPP_STATUS_OK);
    CHECK(nupp_host_answer(runtime, 7, NULL, 0, &error) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(message_has(error, "no host request 7 is waiting"));
    nupp_error_free(error);
    CHECK(nupp_host_fail(runtime, 7, NULL, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_host_answer(runtime, 7, NULL, 256, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(nupp_host_answer(runtime, 7, NULL, 1, NULL) == NUPP_STATUS_INVALID_ARGUMENT);
    memset(&value, 0, sizeof value);
    value.kind = NUPP_VALUE_HANDLE;
    CHECK(nupp_host_answer(runtime, 7, &value, 1, &error) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(message_has(error, "host answer value 1 is a handle"));
    nupp_error_free(error);
    value.kind = NUPP_VALUE_STRING;
    value.data = (unsigned char *)"\xc3\x28";
    value.length = 2;
    CHECK(nupp_host_answer(runtime, 7, &value, 1, &error) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(message_has(error, "not UTF-8"));
    nupp_error_free(error);
    value.kind = NUPP_VALUE_BYTES;
    CHECK(nupp_host_push(runtime, "game.input", &value, 1, &error) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(message_has(error, "pushed value 1 is bytes"));
    nupp_error_free(error);
    value.kind = NUPP_VALUE_NUMBER;
    value.number = 1.0 / 0.0 - 1.0 / 0.0;
    CHECK(nupp_host_push(runtime, "game.input", &value, 1, &error) == NUPP_STATUS_INVALID_ARGUMENT);
    CHECK(message_has(error, "not a finite number"));
    nupp_error_free(error);
    value.number = 3;
    CHECK(nupp_host_push(runtime, "game.input", &value, 1, NULL) == NUPP_STATUS_OK);
    nupp_runtime_free(runtime);
}

static int foreign_status;

#ifdef _WIN32
static DWORD WINAPI poll_elsewhere(LPVOID runtime) {
    foreign_status = nupp_runtime_poll((nupp_runtime *)runtime, NULL);
    return 0;
}
#else
static void *poll_elsewhere(void *runtime) {
    foreign_status = nupp_runtime_poll((nupp_runtime *)runtime, NULL);
    return NULL;
}
#endif

static void runtime_calls_are_thread_affine(void) {
    nupp_runtime *runtime = new_runtime();
#ifdef _WIN32
    HANDLE thread = CreateThread(NULL, 0, poll_elsewhere, runtime, 0, NULL);
    CHECK(thread != NULL);
    WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread);
#else
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, poll_elsewhere, runtime) == 0);
    pthread_join(thread, NULL);
#endif
    CHECK(foreign_status == NUPP_STATUS_RUNTIME);
    CHECK(nupp_runtime_shutdown(runtime, NULL) == NUPP_STATUS_OK);
    nupp_runtime_free(runtime);
}

int main(void) {
    configuration_and_owned_lifecycle_are_checked();
    the_state_sees_the_host_record_and_survives_lua_failures();
    a_hostile_globals_table_cannot_escape_the_protected_boundary();
    attached_shutdown_leaves_the_callers_state_alive();
    attaching_keeps_the_states_host_record_and_its_freeze();
    attaching_checks_the_states_own_luajit();
    c_preloads_and_aot_registrars_run_beneath_the_protected_boundary();
    the_workers_feature_cannot_be_declared_through_the_abi();
    components_values_handles_and_buffer_ownership_cross_the_abi();
    cross_runtime_and_invalid_inputs_are_rejected_without_consuming_owners();
    a_released_handle_is_refused_and_its_name_is_never_reissued();
    handles_outliving_shutdown_are_closed_and_still_freed();
    reentering_a_runtime_from_its_own_call();
    reload_sessions_keep_their_contract();
    a_reload_session_refuses_a_state_that_runs_native_workers();
    an_export_failure_reports_its_whole_message();
    host_kinds_and_answers_are_checked();
    runtime_calls_are_thread_affine();
    if (failures != 0) {
        printf("embedabi: %d checks failed\n", failures);
        return 1;
    }
    printf("embedabi: ok\n");
    return 0;
}
