/*
 * mayhem/lsan_off.c - the sanctioned build-time LeakSanitizer off-switch (SPEC §6.2 item 15).
 *
 * Turns off only the leak check; ASan and UBSan stay fully active. Linked into every
 * sanitized binary mayhem/build.sh produces: /mayhem/fuzz_samplefrommem and
 * /mayhem/fuzz_samplefrommem-standalone. (/mayhem/sdlsound_selftest is built without
 * sanitizers and does not need it.)
 */
int __lsan_is_turned_off(void) { return 1; }
