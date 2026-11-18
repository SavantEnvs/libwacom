/* Fuzzes the .stylus parser (libwacom_parse_stylus_keyfile) and everything built from the result.
 * The input is written verbatim as the only .stylus file; a real upstream .tablet file sits next to
 * it so the database is loadable and its Styli= groups resolve against the fuzzed styli. */
#include "harness_common.h"

static const unsigned char intuos4_tablet[] = {
#include "embed_intuos4_tablet.h"
	0
};
static const unsigned char cintiq_tablet[] = {
#include "embed_cintiq_tablet.h"
	0
};

int
LLVMFuzzerInitialize(int *argc,
		     char ***argv)
{
	const char *names[] = { "intuos4-6x9-wl.tablet", "cintiq-pro-13.tablet" };
	const unsigned char *data[] = { intuos4_tablet, cintiq_tablet };
	const size_t len[] = { sizeof(intuos4_tablet) - 1, sizeof(cintiq_tablet) - 1 };

	harness_init("fuzz.stylus", names, data, len, 2);
	return 0;
}

int
LLVMFuzzerTestOneInput(const uint8_t *data,
		       size_t size)
{
	write_file(scratch_dir, "fuzz.stylus", data, size);
	load_and_walk();
	return 0;
}
