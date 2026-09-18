void cr4shed_jetsam_init(void);
__attribute__((constructor))
static void cr4_jetsam_ctor(void) { cr4shed_jetsam_init(); }
