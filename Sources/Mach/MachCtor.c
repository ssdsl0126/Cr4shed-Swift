void cr4shed_mach_init(void);

__attribute__((constructor))
static void cr4_mach_ctor(void) {
    cr4shed_mach_init();
}
