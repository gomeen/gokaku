// 隔离 librime JSONL worker；不连接系统输入源。构建/部署见 prepare-rime-input.py。
#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <dlfcn.h>
#include <dirent.h>
#include <errno.h>
#include <inttypes.h>
#include <json-c/json.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "rime_api.h"

#ifndef GOGAKU_RIME_HEADER_VERSION
#define GOGAKU_RIME_HEADER_VERSION "1.16.0"
#endif
static FILE *wire;
static RimeApi *api;
static RimeSessionId session;
static uint64_t now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec;
}
static void emit(struct json_object *o) {
  fprintf(wire, "%s\n", json_object_to_json_string_ext(o, JSON_C_TO_STRING_PLAIN));
  fflush(wire);
  json_object_put(o);
}
static void str(struct json_object *o, const char *k, const char *v) {
  json_object_object_add(o, k, v ? json_object_new_string(v) : NULL);
}
static void boolean(struct json_object *o, const char *k, bool v) {
  json_object_object_add(o, k, json_object_new_boolean(v));
}
static void ns(struct json_object *o, const char *k, uint64_t v) {
  json_object_object_add(o, k, json_object_new_int64((int64_t)v));
}
static void discard_commit(void) {
  RIME_STRUCT(RimeCommit, c);
  if (api->get_commit(session, &c)) api->free_commit(&c);
}
// json-c 在此只用作动态字符串/数组容器；字符串复制与候选惰性求值均在 collect 内。
static struct json_object *collect(bool ok, bool handled, const char *error,
                                   uint64_t start, uint64_t processed) {
  struct json_object *o = json_object_new_object();
  boolean(o, "ok", ok);
  boolean(o, "handled", handled);
  if (error) str(o, "error", error);
  struct json_object *candidates = json_object_new_array();
  RIME_STRUCT(RimeContext, ctx);
  bool has = api->get_context(session, &ctx);
  // All benchmark schemas use page_size=10 and start on page zero. The C API
  // already materializes that page in get_context; do not enumerate it twice.
  if (has) {
    for (int n = 0; n < ctx.menu.num_candidates && n < 10; ++n)
      json_object_array_add(candidates, json_object_new_string(ctx.menu.candidates[n].text ? ctx.menu.candidates[n].text : ""));
  }
  json_object_object_add(o, "candidates", candidates);
  str(o, "preedit", has && ctx.composition.preedit ? ctx.composition.preedit : "");
  const char *raw = api->get_input(session);
  str(o, "raw_input", raw ? raw : "");
  boolean(o, "composing", (raw && *raw) || (has && ctx.composition.length > 0));
  if (has) api->free_context(&ctx);
  RIME_STRUCT(RimeCommit, commit);
  if (api->get_commit(session, &commit)) {
    str(o, "commit", commit.text ? commit.text : "");
    api->free_commit(&commit);
  } else str(o, "commit", "");
  uint64_t end = now_ns();
  ns(o, "process_ns", processed - start);
  ns(o, "collect_ns", end - processed);
  ns(o, "total_ns", end - start);
  return o;
}
static bool integer(struct json_object *o, const char *name, int *value, int min, int max) {
  struct json_object *v = NULL;
  if (!json_object_object_get_ex(o, name, &v) || !json_object_is_type(v, json_type_int)) return false;
  int64_t i = json_object_get_int64(v);
  if (i < min || i > max) return false;
  *value = (int)i;
  return true;
}
static void fail(const char *s) { fprintf(stderr, "%s\n", s); exit(1); }
static void seed_resource(const char *user, const char *shared, const char *name) {
  char source[PATH_MAX], destination[PATH_MAX];
  if (snprintf(source, sizeof(source), "%s/%s", shared, name) >= (int)sizeof(source) ||
      snprintf(destination, sizeof(destination), "%s/%s", user, name) >= (int)sizeof(destination)) fail("resource path too long");
  struct stat info;
  if (stat(source, &info)) { if (errno == ENOENT) return; fail("cannot inspect static resource"); }
  if (symlink(source, destination)) fail("cannot link isolated static resource");
}
static void seed_user(const char *user, const char *shared, const char *build) {
  // Upstream Lua may resolve public assets relative to user_data_dir. Supply
  // those assets in this fresh scratch directory, and give writable databases
  // a private build directory. No personal configuration is used.
  const char *names[] = {"lua", "opencc", "dicts", "cn_dicts", "en_dicts", "custom_phrase.txt", "rime.lua", NULL};
  for (int n = 0; names[n]; ++n) seed_resource(user, shared, names[n]);
  char destination[PATH_MAX];
  if (snprintf(destination, sizeof(destination), "%s/build", user) >= (int)sizeof(destination) || mkdir(destination, 0700))
    fail("cannot create private user build directory");
  DIR *directory = opendir(build);
  if (!directory) fail("cannot inspect prebuilt resources");
  struct dirent *entry;
  while ((entry = readdir(directory))) {
    if (entry->d_name[0] == '.') continue;
    char relative[PATH_MAX], source[PATH_MAX], link[PATH_MAX];
    struct stat info;
    if (snprintf(relative, sizeof(relative), "build/%s", entry->d_name) >= (int)sizeof(relative) ||
        snprintf(source, sizeof(source), "%s/%s", build, entry->d_name) >= (int)sizeof(source) ||
        snprintf(link, sizeof(link), "%s/%s", user, relative) >= (int)sizeof(link)) fail("prebuilt path too long");
    if (stat(source, &info) == 0 && S_ISREG(info.st_mode) && symlink(source, link)) fail("cannot link prebuilt resource");
  }
  closedir(directory);
}
static void apply_options(struct json_object *options) {
  if (!options) return;
  json_object_object_foreach(options, key, value) {
    api->set_option(session, key, json_object_get_boolean(value));
  }
}
int main(int argc, char **argv) {
  // 第三方 Lua print 或引擎日志也不能污染协议 stdout。
  wire = fdopen(dup(STDOUT_FILENO), "w");
  if (!wire || dup2(STDERR_FILENO, STDOUT_FILENO) < 0) return 1;
  uint64_t load_start = now_ns();
  const char *library = NULL, *shared = NULL, *build = NULL, *users = NULL;
  const char *schema = NULL, *id = NULL, *config_file = NULL;
  const char *plugins[16] = {0}; int plugin_count = 0;
  const char *deploy_schemas[32] = {0}; int deploy_count = 0;
  bool inspect = false;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--inspect")) { inspect = true; continue; }
    if (i + 1 >= argc) fail("missing argument");
    const char *k = argv[i++], *v = argv[i];
    if (!strcmp(k, "--library")) library = v;
    else if (!strcmp(k, "--shared")) shared = v;
    else if (!strcmp(k, "--build")) build = v;
    else if (!strcmp(k, "--users")) users = v;
    else if (!strcmp(k, "--schema")) schema = v;
    else if (!strcmp(k, "--id")) id = v;
    else if (!strcmp(k, "--config")) config_file = v;
    else if (!strcmp(k, "--plugin") && plugin_count < 15) plugins[plugin_count++] = v;
    else if (!strcmp(k, "--deploy") && deploy_count < 31) deploy_schemas[deploy_count++] = v;
    else fail("unknown argument");
  }
  if (!library) fail("--library is required");
  void *lib = dlopen(library, RTLD_NOW | RTLD_GLOBAL);
  if (!lib) fail(dlerror());
  RimeApi *(*get_api)(void) = (RimeApi *(*)(void))dlsym(lib, "rime_get_api");
  if (!get_api) fail("rime_get_api missing");
  api = get_api();
  if (!RIME_API_AVAILABLE(api, get_version)) fail("version API unavailable");
  if (strcmp(api->get_version(), GOGAKU_RIME_HEADER_VERSION)) fail("runtime/header version mismatch");
  if (!RIME_API_AVAILABLE(api, candidate_list_begin) || !RIME_API_AVAILABLE(api, get_input) ||
      !RIME_API_AVAILABLE(api, select_candidate)) fail("required API unavailable");
  // 插件在 initialize 前加载，其构造器向同一个 librime 注册模块。
  for (int i = 0; i < plugin_count; ++i)
    if (!dlopen(plugins[i], RTLD_NOW | RTLD_GLOBAL)) fail(dlerror());
  if (inspect) {
    struct json_object *o = json_object_new_object();
    str(o, "version", api->get_version());
    str(o, "header_version", GOGAKU_RIME_HEADER_VERSION);
    boolean(o, "lua", api->find_module("lua") != NULL);
    boolean(o, "octagram", api->find_module("octagram") != NULL);
    emit(o); return 0;
  }
  if (!shared || !build || !users || !schema || !id || !config_file)
    fail("required: --shared --build --users --schema --id --config");
  char user[PATH_MAX];
  if (snprintf(user, sizeof(user), "%s/user-XXXXXX", users) >= (int)sizeof(user) || !mkdtemp(user))
    fail("cannot create isolated user directory");
  seed_user(user, shared, build);
  struct json_object *config = json_object_from_file(config_file);
  if (!config) fail("cannot read worker config");
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = shared; traits.user_data_dir = user;
  traits.staging_dir = build; traits.prebuilt_data_dir = build;
  traits.distribution_name = "Gogaku isolated input benchmark";
  traits.distribution_code_name = "gogaku-benchmark";
  traits.distribution_version = "1"; traits.app_name = "rime.gogaku-benchmark";
  const char *modules[] = {"default", "lua", "octagram", NULL};
  const char *deploy_modules[] = {"default", "deployer", "lua", "octagram", NULL};
  if (plugin_count) traits.modules = deploy_count ? deploy_modules : modules;
  traits.min_log_level = 2; traits.log_dir = users;
  api->setup(&traits); api->initialize(&traits);
  if (deploy_count) {
    api->deployer_initialize(&traits);
    if (!api->deploy_config_file("default.yaml", "config_version")) fail("default config deployment failed");
    for (int i = 0; i < deploy_count; ++i) {
      char path[PATH_MAX];
      if (snprintf(path, sizeof(path), "%s/%s.schema.yaml", shared, deploy_schemas[i]) >= (int)sizeof(path) ||
          !api->deploy_schema(path)) fail("schema deployment failed");
    }
    api->finalize(); json_object_put(config); return 0;
  }
  session = api->create_session();
  if (!session || !api->select_schema(session, schema)) fail("select_schema failed");
  struct json_object *options = NULL;
  if (json_object_object_get_ex(config, "runtime_options", &options)) json_object_get(options);
  apply_options(options);
  struct json_object *ready = json_object_new_object();
  boolean(ready, "ready", true); str(ready, "engine", "rime"); str(ready, "version", api->get_version());
  json_object_object_add(ready, "load_ms", json_object_new_double((now_ns() - load_start) / 1e6));
  str(config, "id", id); str(config, "session_user_dir", user);
  str(config, "load_boundary", "main entry before dlopen through initialized session/schema/options; excludes deployment");
  json_object_object_add(ready, "config", config); emit(ready);
  char *line = NULL; size_t cap = 0; ssize_t size;
  while ((size = getline(&line, &cap, stdin)) >= 0) {
    struct json_tokener *tok = json_tokener_new();
    struct json_object *req = json_tokener_parse_ex(tok, line, (int)size);
    enum json_tokener_error parse_error = json_tokener_get_error(tok);
    size_t used = json_tokener_get_parse_end(tok);
    while (used < (size_t)size && (line[used] == ' ' || line[used] == '\t' || line[used] == '\r' || line[used] == '\n')) ++used;
    json_tokener_free(tok);
    bool valid = parse_error == json_tokener_success && used == (size_t)size && json_object_is_type(req, json_type_object);
    struct json_object *op_value = NULL;
    const char *op = valid && json_object_object_get_ex(req, "op", &op_value) &&
      json_object_is_type(op_value, json_type_string) ? json_object_get_string(op_value) : "";
    int value = 0;
    bool is_key = !strcmp(op, "key"), is_select = !strcmp(op, "select");
    const char *error = NULL;
    if (!valid) error = "invalid JSON object";
    else if (is_key && !integer(req, "key", &value, 0, 127)) error = "key must be an ASCII integer";
    else if (is_select && !integer(req, "index", &value, 0, 9)) error = "index must be an integer from 0 to 9";
    else if (strcmp(op, "reset") && strcmp(op, "peek") && strcmp(op, "quit") && !is_key && !is_select)
      error = "unknown operation";
    if (!error && !strcmp(op, "quit")) {
      struct json_object *o = json_object_new_object(); boolean(o, "ok", true); boolean(o, "quit", true);
      emit(o); json_object_put(req); break;
    }
    uint64_t start = now_ns(); bool handled = false, ok = !error;
    if (!error) {
      if (!strcmp(op, "reset")) {
        api->clear_composition(session); discard_commit(); handled = true;
        struct json_object *fresh = NULL;
        if (json_object_object_get_ex(req, "fresh", &fresh) && json_object_get_boolean(fresh)) {
          api->destroy_session(session);
          session = api->create_session();
          if (!session || !api->select_schema(session, schema)) fail("fresh session failed");
          apply_options(options);
        }
      } else if (is_key) {
        // 协议中的 ASCII 控制码转换为 librime/X11 keysym。
        int key = value == 8 ? 0xff08 : value == 27 ? 0xff1b : value == 13 ? 0xff0d : value == 9 ? 0xff09 : value;
        handled = api->process_key(session, key, 0);
      } else if (is_select) {
        handled = api->select_candidate(session, (size_t)value);
        if (!handled) { ok = false; error = "candidate unavailable"; }
      } else handled = true;
    }
    uint64_t processed = now_ns();
    emit(collect(ok, handled, error, start, processed));
    if (req) json_object_put(req);
  }
  free(line); api->clear_composition(session); discard_commit();
  api->destroy_session(session); api->finalize();
  if (options) json_object_put(options);
  fclose(wire);
  // librime/plugin 生命周期由操作系统结束，不提前 dlclose 插件依赖。
  return 0;
}
