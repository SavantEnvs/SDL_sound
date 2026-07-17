/*
 * mayhem/lsan_off.c - the sanctioned build-time LeakSanitizer off-switch (SPEC §6.2 item 15).
 *
 * Turns off only the leak check; ASan and UBSan stay fully active. Linked into every
 * sanitized binary mayhem/build.sh produces: /mayhem/fuzz_samplefrommem (which mayhem/test.sh
 * also runs) and /mayhem/fuzz_samplefrommem-standalone.
 */
int __lsan_is_turned_off(void) { return 1; }
