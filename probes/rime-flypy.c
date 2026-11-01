#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rime_api.h"

static void json_string(const char *text) {
  putchar('"');
  if (text) for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
    if (*p == '"' || *p == '\\') putchar('\\');
    if (*p < 32) printf("\\u%04x", *p); else putchar(*p);
  }
  putchar('"');
}

static void collect_commit(RimeApi *api, RimeSessionId session, char *buffer, size_t size) {
  RIME_STRUCT(RimeCommit, commit);
  if (api->get_commit(session, &commit)) {
    if (commit.text) strncat(buffer, commit.text, size - strlen(buffer) - 1);
    api->free_commit(&commit);
  }
}

int main(int argc, char **argv) {
  if (argc != 5) {
    fprintf(stderr, "usage: rime-flypy LIBRARY SHARED_DATA SCRATCH_USER SCHEMA_FILE\n");
    return 2;
  }
  void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) { fprintf(stderr, "%s\n", dlerror()); return 1; }
  RimeApi *(*get_api)(void) = dlsym(library, "rime_get_api");
  if (!get_api) { fprintf(stderr, "rime_get_api unavailable\n"); return 1; }
  RimeApi *api = get_api();
  char staging[4096], prebuilt[4096];
  snprintf(staging, sizeof(staging), "%s/build", argv[3]);
  snprintf(prebuilt, sizeof(prebuilt), "%s/build", argv[2]);
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = argv[2];
  traits.user_data_dir = argv[3];
  traits.prebuilt_data_dir = prebuilt;
  traits.staging_dir = staging;
  traits.distribution_name = "Gogaku isolated probe";
  traits.distribution_code_name = "gogaku-probe";
  traits.distribution_version = "0";
  traits.app_name = "rime.gogaku-probe";
  traits.min_log_level = 2;
  traits.log_dir = "";
  api->setup(&traits);
  api->initialize(&traits);
  api->deployer_initialize(&traits);
  if (!api->deploy_schema(argv[4])) {
    fprintf(stderr, "Failed to deploy flypy into scratch user directory\n");
    api->finalize();
    return 1;
  }
  printf("{\n  \"librimeVersion\": "); json_string(api->get_version());
  printf(",\n  \"schema\": \"double_pinyin_flypy\",\n  \"cases\": [\n");
  const char *inputs[] = { "nihc", "kdhv", "hvyi", "woxlxtykyu", "wxqcf", "meeting" };
  for (size_t i = 0; i < sizeof(inputs) / sizeof(inputs[0]); i++) {
    RimeSessionId session = api->create_session();
    if (!api->select_schema(session, "double_pinyin_flypy")) {
      fprintf(stderr, "Could not select double_pinyin_flypy\n");
      return 1;
    }
    api->set_option(session, "ascii_mode", False);
    api->set_option(session, "simplification", True);
    char committed[4096] = {0};
    for (const char *p = inputs[i]; *p; p++) {
      api->process_key(session, (unsigned char)*p, 0);
      collect_commit(api, session, committed, sizeof(committed));
    }
    RIME_STRUCT(RimeContext, context);
    Bool has_context = api->get_context(session, &context);
    printf("    {\"input\": "); json_string(inputs[i]);
    printf(", \"preedit\": "); json_string(has_context ? context.composition.preedit : "");
    printf(", \"candidates\": [");
    if (has_context) {
      for (int c = 0; c < context.menu.num_candidates; c++) {
        if (c) printf(", ");
        json_string(context.menu.candidates[c].text);
      }
      api->free_context(&context);
    }
    printf("], \"committedBeforeSpace\": "); json_string(committed);
    committed[0] = '\0';
    if (strcmp(inputs[i], "hvyi") == 0) {
      api->select_candidate_on_current_page(session, 1);
      collect_commit(api, session, committed, sizeof(committed));
    }
    printf(", \"committedOnExplicitSecondCandidate\": "); json_string(committed);
    committed[0] = '\0';
    api->process_key(session, ' ', 0);
    collect_commit(api, session, committed, sizeof(committed));
    printf(", \"committedOnSpace\": "); json_string(committed);
    printf("}%s\n", i + 1 == sizeof(inputs) / sizeof(inputs[0]) ? "" : ",");
    api->destroy_session(session);
  }
  printf("  ],\n  \"scope\": \"Installed engine with scratch user data, no host input-method UI, no translation model\"\n}\n");
  api->finalize();
  dlclose(library);
  return 0;
}
