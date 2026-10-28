int rhizo_selftest_exported_symbol(int x) { return x * 2; }
static int pad[4096] = {1,2,3,4};
int rhizo_selftest_use_pad(void) { return pad[0] + pad[1] + pad[2] + pad[3]; }
